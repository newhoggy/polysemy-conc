{-# options_haddock prune #-}

-- |Description: Process Interpreters, Internal
module Polysemy.Process.Interpreter.Process where

import Control.Concurrent.STM.TBMQueue (TBMQueue)
import qualified Polysemy.Conc as Conc
import Polysemy.Conc.Async (withAsync_)
import qualified Polysemy.Conc.Data.QueueResult as QueueResult
import qualified Polysemy.Conc.Effect.Queue as Queue
import Polysemy.Conc.Effect.Queue (Queue)
import Polysemy.Conc.Effect.Race (Race)
import Polysemy.Conc.Effect.Scoped (Scoped)
import Polysemy.Conc.Interpreter.Queue.TBM (interpretQueueTBMWith, withTBMQueue)
import Polysemy.Conc.Interpreter.Scoped (interpretScopedResumableWith_)
import Polysemy.Resume (Stop, resumeOr, resume_, stop, type (!!))
import Prelude hiding (fromException)

import Polysemy.Process.Data.ProcessError (ProcessError (Terminated))
import Polysemy.Process.Data.ProcessKill (ProcessKill (KillAfter, KillImmediately, KillNever))
import Polysemy.Process.Data.ProcessOptions (ProcessOptions (ProcessOptions))
import qualified Polysemy.Process.Effect.Process as Process
import Polysemy.Process.Effect.Process (Process)
import qualified Polysemy.Process.Effect.ProcessOutput as ProcessOutput
import Polysemy.Process.Effect.ProcessOutput (ProcessOutput)
import qualified Polysemy.Process.Effect.SystemProcess as SystemProcess
import Polysemy.Process.Effect.SystemProcess (SystemProcess, withSystemProcess)
import Polysemy.Process.Interpreter.ProcessOutput (
  interpretProcessOutputId,
  interpretProcessOutputLines,
  interpretProcessOutputText,
  interpretProcessOutputTextLines,
  )

newtype In a =
  In { unIn :: a }
  deriving stock (Eq, Show)

newtype Out a =
  Out { unOut :: a }
  deriving stock (Eq, Show)

newtype Err a =
  Err { unErr :: a }
  deriving stock (Eq, Show)

data ProcessQueues o e =
  ProcessQueues {
    pqIn :: TBMQueue (In ByteString),
    pqOut :: TBMQueue (Out o),
    pqErr :: TBMQueue (Err e)
  }

interpretQueues ::
  Members [Resource, Race, Embed IO] r =>
  ProcessQueues o e ->
  InterpretersFor [Queue (In ByteString), Queue (Out o), Queue (Err e)] r
interpretQueues (ProcessQueues inQ outQ errQ) =
  interpretQueueTBMWith errQ .
  interpretQueueTBMWith outQ .
  interpretQueueTBMWith inQ

handleProcessWithQueues ::
  ∀ o e m r a .
  Members [Queue (In ByteString), Queue (Out o), Queue (Err e), Stop ProcessError] r =>
  Process ByteString o e m a ->
  Sem r a
handleProcessWithQueues = \case
  Process.Recv ->
    Queue.read >>= \case
      QueueResult.Closed ->
        stop (Terminated "closed")
      QueueResult.NotAvailable ->
        stop (Terminated "impossible: empty")
      QueueResult.Success (Out msg) ->
        pure msg
  Process.RecvError ->
    Queue.read >>= \case
      QueueResult.Closed ->
        stop (Terminated "closed")
      QueueResult.NotAvailable ->
        stop (Terminated "impossible: empty")
      QueueResult.Success (Err msg) ->
        pure msg
  Process.Send msg -> do
    whenM (Queue.closed @(In ByteString)) (stop (Terminated "closed"))
    Queue.write (In msg)

withSTMResources ::
  ∀ o e r a .
  Members [Resource, Embed IO] r =>
  Int ->
  (ProcessQueues o e -> Sem r a) ->
  Sem r a
withSTMResources qSize action = do
  withTBMQueue qSize \ inQ ->
    withTBMQueue qSize \ outQ ->
      withTBMQueue qSize \ errQ ->
        action (ProcessQueues inQ outQ errQ)

withQueues ::
  Members [Race, Resource, Embed IO] r =>
  Int ->
  InterpretersFor [Queue (In ByteString), Queue (Out o), Queue (Err e)] r
withQueues qSize action =
  withSTMResources qSize \ qs -> interpretQueues qs action

outputQueue ::
  ∀ pipe chunk err r .
  Coercible (pipe chunk) chunk =>
  Members [SystemProcess !! err, ProcessOutput chunk, Queue (pipe chunk), Embed IO] r =>
  Bool ->
  Sem (SystemProcess : r) ByteString ->
  Sem r ()
outputQueue discardWhenFull readChunk = do
  spin ""
  where
    spin buffer =
      resumeOr @err readChunk (write buffer) (const (Queue.close @(pipe chunk)))
    write buffer msg = do
      (chunks, newBuffer) <- ProcessOutput.chunk buffer msg
      for_ chunks \ (coerce @chunk @(pipe chunk) -> c) ->
        if discardWhenFull then void (Queue.tryWrite c) else Queue.write c
      spin newBuffer

inputQueue ::
  ∀ err r .
  Members [SystemProcess !! err, Queue (In ByteString), Embed IO] r =>
  (ByteString -> Sem (SystemProcess : r) ()) ->
  Sem r ()
inputQueue writeChunk =
  spin
  where
    spin =
      Queue.read >>= \case
        QueueResult.Success (In msg) ->
          resumeOr @err (writeChunk msg) (const spin) (const (Queue.close @(In ByteString)))
        _ ->
          unit

handleKill ::
  Members [SystemProcess, Race] r =>
  ProcessKill ->
  Sem r ()
handleKill = \case
  KillAfter interval ->
    Conc.timeout_ SystemProcess.term interval (void SystemProcess.wait)
  KillImmediately ->
    SystemProcess.term
  KillNever ->
    void SystemProcess.wait

withKill ::
  ∀ err r a .
  Members [SystemProcess !! err, Resource, Race] r =>
  ProcessKill ->
  Sem r a ->
  Sem r a
withKill kill ma =
  finally ma $ resume_ @err @SystemProcess do
    void SystemProcess.pid
    handleKill kill

type ScopeEffects o e err =
  [Queue (In ByteString), Queue (Out o), Queue (Err e), SystemProcess !! err]

scope ::
  ∀ o e resource err r .
  Member (Scoped resource (SystemProcess !! err)) r =>
  Members [ProcessOutput e, ProcessOutput o, Resource, Race, Async, Embed IO] r =>
  ProcessOptions ->
  InterpretersFor (ScopeEffects o e err) r
scope (ProcessOptions discard qSize kill) =
  withSystemProcess @resource .
  withQueues qSize .
  withAsync_ (outputQueue @Err @e @err discard SystemProcess.readStderr) .
  withAsync_ (outputQueue @Out @o @err discard SystemProcess.readStdout) .
  withAsync_ (inputQueue @err SystemProcess.writeStdin) .
  withKill @err kill

-- |Interpret 'Process' with a system process resource whose file descriptors are connected to three 'TBMQueue's,
-- deferring decoding of stdout and stderr to the interpreters of two 'ProcessOutput' effects.
interpretProcess ::
  ∀ resource err o e r .
  Member (Scoped resource (SystemProcess !! err)) r =>
  Members [ProcessOutput o, ProcessOutput e, Resource, Race, Async, Embed IO] r =>
  ProcessOptions ->
  InterpreterFor (Scoped () (Process ByteString o e) !! ProcessError) r
interpretProcess options =
  interpretScopedResumableWith_ @(ScopeEffects o e err) (scope @o @e @resource options) handleProcessWithQueues

-- |Interpret 'Process' with a system process resource whose file descriptors are connected to three 'TBMQueue's,
-- producing 'ByteString's.
interpretProcessByteString ::
  ∀ resource err r .
  Members [Scoped resource (SystemProcess !! err), Resource, Race, Async, Embed IO] r =>
  ProcessOptions ->
  InterpreterFor (Scoped () (Process ByteString ByteString ByteString) !! ProcessError) r
interpretProcessByteString options =
  interpretProcessOutputId .
  interpretProcess @resource @err options .
  raiseUnder

-- |Interpret 'Process' with a system process resource whose file descriptors are connected to three 'TBMQueue's,
-- producing chunks of lines of 'ByteString's.
interpretProcessByteStringLines ::
  ∀ resource err r .
  Members [Scoped resource (SystemProcess !! err), Resource, Race, Async, Embed IO] r =>
  ProcessOptions ->
  InterpreterFor (Scoped () (Process ByteString ByteString ByteString) !! ProcessError) r
interpretProcessByteStringLines options =
  interpretProcessOutputLines .
  interpretProcess @resource @err options .
  raiseUnder

-- |Interpret 'Process' with a system process resource whose file descriptors are connected to three 'TBMQueue's,
-- producing 'Text's.
interpretProcessText ::
  ∀ resource err r .
  Members [Scoped resource (SystemProcess !! err), Resource, Race, Async, Embed IO] r =>
  ProcessOptions ->
  InterpreterFor (Scoped () (Process ByteString Text Text) !! ProcessError) r
interpretProcessText options =
  interpretProcessOutputText .
  interpretProcess @resource @err options .
  raiseUnder

-- |Interpret 'Process' with a system process resource whose file descriptors are connected to three 'TBMQueue's,
-- producing chunks of lines of 'Text's.
interpretProcessTextLines ::
  ∀ resource err r .
  Members [Scoped resource (SystemProcess !! err), Resource, Race, Async, Embed IO] r =>
  ProcessOptions ->
  InterpreterFor (Scoped () (Process ByteString Text Text) !! ProcessError) r
interpretProcessTextLines options =
  interpretProcessOutputTextLines .
  interpretProcess @resource @err options .
  raiseUnder
