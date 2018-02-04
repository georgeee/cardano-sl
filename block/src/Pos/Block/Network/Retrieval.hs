{-# LANGUAGE RankNTypes #-}

-- | Server which deals with blocks processing.

module Pos.Block.Network.Retrieval
       ( retrievalWorker
       ) where

import           Universum

import           Conduit ((.|))
import qualified Conduit as C
import           Control.Concurrent.STM (putTMVar, swapTMVar, tryReadTBQueue, tryReadTMVar,
                                         tryTakeTMVar)
import           Control.Lens (to, _Wrapped)
import           Control.Monad.Except (ExceptT, runExceptT, throwError)
import           Control.Monad.STM (retry)
import qualified Data.Conduit.Async as Conduit.Async
import           Data.List.NonEmpty ((<|))
import qualified Data.List.NonEmpty as NE
import qualified Data.Set as S
import           Ether.Internal (HasLens (..))
import           Fmt (format, (+|), (|+))
import           Formatting (build, builder, int, sformat, stext, (%))
import           Mockable (delay, handleAll)
import qualified Network.HTTP.Simple as Http
import           Serokell.Data.Memory.Units (unitBuilder)
import           Serokell.Util (listJson, sec)
import           System.Wlog (logDebug, logError, logInfo, logWarning)

import           Pos.Binary.Class (biSize)
import           Pos.Block.BlockWorkMode (BlockWorkMode)
import           Pos.Block.Dump (decodeBlockDumpC)
import           Pos.Block.Logic (ClassifyHeaderRes (..), classifyNewHeader, verifyAndApplyBlocksC)
import           Pos.Block.Network.Announce (announceBlockOuts)
import           Pos.Block.Network.Logic (BlockNetLogicException (DialogUnexpected),
                                          MkHeadersRequestResult (..), handleBlocks,
                                          mkBlocksRequest, mkHeadersRequest, requestHeaders,
                                          triggerRecovery)
import           Pos.Block.Network.Types (MsgBlock (..), MsgGetBlocks (..))
import           Pos.Block.RetrievalQueue (BlockRetrievalQueueTag, BlockRetrievalTask (..))
import           Pos.Block.Types (ProgressHeaderTag, RecoveryHeaderTag)
import           Pos.Communication.Limits.Types (recvLimited)
import           Pos.Communication.Protocol (Conversation (..), ConversationActions (..),
                                             EnqueueMsg, MsgType (..), NodeId, OutSpecs,
                                             SendActions (..), WorkerSpec, convH, toOutSpecs,
                                             waitForConversations, worker)
import           Pos.Core (HasHeaderHash (..), HeaderHash, difficultyL, epochIndexL, epochSlots,
                           getEpochOrSlot, isMoreDifficult, prevBlockL, siSlotL, unEpochOrSlot)
import           Pos.Core.Block (Block, BlockHeader, blockHeader)
import           Pos.Crypto (shortHashF)
import qualified Pos.DB.BlockIndex as DB
import           Pos.Reporting (reportOrLogE, reportOrLogW)
import           Pos.Slotting.Class (getCurrentSlot)
import           Pos.StateLock (Priority (HighPriority), modifyStateLock)
import           Pos.Util ((<//>), _neHead, _neLast)
import           Pos.Util.Chrono (NE, NewestFirst (..), OldestFirst (..), _NewestFirst,
                                  _OldestFirst)
import           Pos.Util.Timer (Timer, startTimer)

retrievalWorker
    :: forall ctx m.
       (BlockWorkMode ctx m)
    => Timer -> Maybe Text -> (WorkerSpec m, OutSpecs)
retrievalWorker keepAliveTimer blockStorageMirror =
    worker outs (retrievalWorkerImpl keepAliveTimer blockStorageMirror)
  where
    outs = announceBlockOuts <>
           toOutSpecs [convH (Proxy :: Proxy MsgGetBlocks)
                             (Proxy :: Proxy MsgBlock)
                      ]

-- I really don't like join
{-# ANN retrievalWorkerImpl ("HLint: ignore Use join" :: Text) #-}

-- | Worker that queries blocks. It has two jobs:
--
-- * If there are headers in 'BlockRetrievalQueue', this worker retrieves
--   blocks according to that queue.
--
-- * If recovery is in progress, this worker keeps recovery going by asking
--   headers (and then switching to block retrieval on next loop iteration).
--
-- If both happen at the same time, 'BlockRetrievalQueue' takes precedence.
--
-- Note: if we haven't caught up with the blockchain yet, the worker will
-- try to download and apply blockchain dumps, and only if it fails it'll
-- switch to requesting headers/blocks.
--
retrievalWorkerImpl
    :: forall ctx m.
       (BlockWorkMode ctx m)
    => Timer -> Maybe Text -> SendActions m -> m ()
retrievalWorkerImpl keepAliveTimer blockStorageMirror SendActions {..} = do
    handleAll tryDownloadE $ do
        epoch <- view epochIndexL <$> DB.getTipHeader
        whenJust blockStorageMirror $ \dumpUrl ->
            tryDownload epoch (toString dumpUrl)
    handleAll recoveryLoopE $ do
        logInfo "Starting recovery loop"
        recoveryLoop
  where
    -- | Try to download and apply a blockchain dump, starting from the
    -- given epoch.
    tryDownload epoch dumpUrl = whenNothingM_ getCurrentSlot $ do
        let epochUrl = dumpUrl <//> format "epoch{}.cbor.lzma"
                                           (toInteger epoch)
        logInfo ("Downloading blockchain dump for epoch "+|epoch|+
                 " from "+|epochUrl|+"")
        isSuccess <- modifyStateLock HighPriority "tryDownload" $ \tip -> do
            slot <- getEpochOrSlot <$> DB.getTipHeader
            -- When we're already in the epoch we're going to be downloading
            -- blocks from, it's possible that we're in slot 10000 or
            -- something and we'll have to skip 10000 blocks before we can
            -- show any progress. In this case let's warn about it.
            whenRight (unEpochOrSlot slot) $ \slotId ->
                when (slotId ^. epochIndexL == epoch) $
                    logDebug ("Going to download blocks and skip until slot "
                              +|view siSlotL slotId|+", this may take " <>
                              "some time")
            let applyDump
                    = decodeBlockDumpC
                   .| (C.dropWhileC ((/= tip) . view prevBlockL)
                   >> C.transPipe lift (verifyAndApplyBlocksC True))
            -- We use Data.Conduit.Async to keep a buffer of downloaded
            -- blocks and apply them in parallel with downloading them. The
            -- buffer has size 'epochSlots' because that's the maximum
            -- amount of blocks we can have in an epoch
            request <- Http.parseRequest epochUrl
            res <- C.runResourceT $
                Conduit.Async.buffer (fromIntegral epochSlots)
                    (Http.httpSource request Http.getResponseBody)
                    applyDump
            -- TODO: abort if downloading is too slow and we haven't gotten
            -- any blocks in e.g. last minute
            case res of
                Left err -> do
                    logError ("Failed to apply the dump: "+|err|+"")
                    pure (tip, False)
                Right newTip ->
                    pure (newTip, True)
        when isSuccess $ tryDownload (succ epoch) dumpUrl
    tryDownloadE e =
        reportOrLogE "retrievalWorker tryDownloadE: error caught " e

    recoveryLoop = do
        queue        <- view (lensOf @BlockRetrievalQueueTag)
        recHeaderVar <- view (lensOf @RecoveryHeaderTag)
        logDebug "Waiting on the block queue or recovery header var"
        -- Reading the queue is a priority, because it sets recovery
        -- variable in case header is alternative. So if the queue
        -- contains lots of headers after a long delay, we'll first
        -- iterate over them and set recovery variable to a latest
        -- one, and only then we'll do recovery.
        thingToDoNext <- atomically $ do
            mbQueuedHeadersChunk <- tryReadTBQueue queue
            mbRecHeader <- tryReadTMVar recHeaderVar
            case (mbQueuedHeadersChunk, mbRecHeader) of
                (Nothing, Nothing) -> retry
                -- Dispatch task.
                (Just (nodeId, task), _) ->
                    pure (handleBlockRetrieval nodeId task)
                -- No tasks & recovery header is there ⇒ do recovery.
                (_, Just (nodeId, rHeader))  ->
                    pure (handleRecoveryWithHandler nodeId rHeader)
        startTimer keepAliveTimer
        thingToDoNext
        recoveryLoop
    recoveryLoopE e = do
        -- REPORT:ERROR 'reportOrLogE' in block retrieval worker.
        reportOrLogE "retrievalWorker recoveryLoopE: error caught " e
        delay $ sec 1
        recoveryLoop

    -----------------

    -- That's the first queue branch (task dispatching).
    handleBlockRetrieval nodeId BlockRetrievalTask{..} = do
        logDebug $ sformat
            ("Block retrieval queue task received, nodeId="%build%
             ", header="%build%", continues="%build)
            nodeId
            (headerHash brtHeader)
            brtContinues
        (if brtContinues then handleContinues else handleAlternative)
            nodeId
            brtHeader

    -- When we have continuation, we just try to get and apply it.
    handleContinues nodeId header = do
        let hHash = headerHash header
        logDebug $ "handleContinues: " <> pretty hHash
        classifyNewHeader header >>= \case
            CHContinues ->
                void $ getProcessBlocks enqueueMsg nodeId header hHash
            res -> logDebug $
                "processContHeader: expected header to " <>
                "be continuation, but it's " <> show res

    -- When we have alternative header, we should check whether it's
    -- really recovery mode (server side should send us headers as a
    -- proof) and then enter recovery mode.
    handleAlternative nodeId header = do
        logDebug $ "handleAlternative: " <> pretty (headerHash header)
        classifyNewHeader header >>= \case
            CHInvalid _ ->
                logError "handleAlternative: invalid header got into retrievalWorker queue"
            CHUseless _ ->
                logDebug $
                sformat ("handleAlternative: header "%build%" became useless, ignoring it")
                        header
            _ -> do
                logDebug "handleAlternative: considering header for recovery mode"
                -- CSL-1514
                updateRecoveryHeader nodeId header

    -----------------

    handleRecoveryWithHandler nodeId header =
        handleAll (handleRecoveryE nodeId header) $
        handleRecovery nodeId header

    -- We immediately drop recovery mode/header and request tips
    -- again.
    handleRecoveryE nodeId header e = do
        -- REPORT:ERROR 'reportOrLogW' in block retrieval worker/recovery.
        reportOrLogW (sformat
            ("handleRecoveryE: error handling nodeId="%build%", header="%build%": ")
            nodeId (headerHash header)) e
        dropUpdateHeader
        dropRecoveryHeaderAndRepeat enqueueMsg nodeId

    -- Recovery handling. We assume that header in recovery var makes
    -- sense and just query headers/blocks.
    handleRecovery nodeId header = do
        logDebug "Block retrieval queue is empty and we're in recovery mode,\
                 \ so we will request more headers and blocks"
        mkHeadersRequest (headerHash header) >>= \case
            MhrrBlockAdopted ->
                -- How did we even get into recovery then?
                throwM $ DialogUnexpected "handleRecovery: got MhrrBlockAdopted"
            MhrrWithCheckpoints mgh -> do
                logDebug "handleRecovery: asking for headers"
                let cont (headers :: NewestFirst NE BlockHeader) =
                        let oldestHeader = headers ^. _NewestFirst . _neLast
                            newestHeader = headers ^. _NewestFirst . _neHead
                        in getProcessBlocks enqueueMsg nodeId
                                            oldestHeader (headerHash newestHeader)
                -- If it returns w/o exception then we're:
                --  * Either still in recovery mode
                --  * Or just exited it and recoverVar was taken.
                enqueueMsgSingle
                    enqueueMsg
                    (MsgRequestBlockHeaders $ Just $ S.singleton nodeId)
                    (Conversation $ requestHeaders cont mgh nodeId)


----------------------------------------------------------------------------
-- Entering and exiting recovery mode
----------------------------------------------------------------------------

-- | Result of attempt to update recovery header.
data UpdateRecoveryResult ssc
    = RecoveryStarted NodeId BlockHeader
      -- ^ Recovery header was absent, so we've set it.
    | RecoveryShifted NodeId BlockHeader NodeId BlockHeader
      -- ^ Header was present, but we've replaced it with another
      -- (more difficult) one.
    | RecoveryContinued NodeId BlockHeader
      -- ^ Header is good, but is irrelevant, so recovery variable is
      -- unchanged.

-- | Be careful to run this in the same thread that ends recovery mode
-- (or synchronise those threads with an MVar), otherwise a race
-- condition can occur where we are caught in the recovery mode
-- indefinitely.
updateRecoveryHeader
    :: BlockWorkMode ctx m
    => NodeId
    -> BlockHeader
    -> m ()
updateRecoveryHeader nodeId hdr = do
    recHeaderVar <- view (lensOf @RecoveryHeaderTag)
    logDebug "Updating recovery header..."
    updated <- atomically $ do
        mbRecHeader <- tryReadTMVar recHeaderVar
        case mbRecHeader of
            Nothing -> do
                putTMVar recHeaderVar (nodeId, hdr)
                return $ RecoveryStarted nodeId hdr
            Just (oldNodeId, oldHdr) -> do
                let needUpdate = hdr `isMoreDifficult` oldHdr
                if needUpdate
                    then swapTMVar recHeaderVar (nodeId, hdr) $>
                         RecoveryShifted oldNodeId oldHdr nodeId hdr
                    else return $ RecoveryContinued oldNodeId oldHdr
    logDebug $ case updated of
        RecoveryStarted rNodeId rHeader -> sformat
            ("Recovery started with nodeId="%build%" and tip="%build)
            rNodeId
            (headerHash rHeader)
        RecoveryShifted rNodeId' rHeader' rNodeId rHeader -> sformat
            ("Recovery shifted from nodeId="%build%" and tip="%build%
             " to nodeId="%build%" and tip="%build)
            rNodeId' (headerHash rHeader')
            rNodeId  (headerHash rHeader)
        RecoveryContinued rNodeId rHeader -> sformat
            ("Recovery continued with nodeId="%build%" and tip="%build)
            rNodeId
            (headerHash rHeader)

dropUpdateHeader :: BlockWorkMode ctx m => m ()
dropUpdateHeader = do
    progressHeaderVar <- view (lensOf @ProgressHeaderTag)
    void $ atomically $ tryTakeTMVar progressHeaderVar

-- | The returned 'Bool' signifies whether given peer was kicked and recovery
-- was stopped.
--
-- NB. The reason @nodeId@ is passed is that we want to avoid a race
-- condition. If you work with peer P and header H, after failure you want to
-- drop communication with P; however, if at the same time a new block
-- arrives and another thread replaces peer and header to (P2, H2), you want
-- to continue working with P2 and ignore the exception that happened with P.
-- So, @nodeId@ is used to check that the peer wasn't replaced mid-execution.
dropRecoveryHeader
    :: BlockWorkMode ctx m
    => NodeId
    -> m Bool
dropRecoveryHeader nodeId = do
    recHeaderVar <- view (lensOf @RecoveryHeaderTag)
    (kicked,realPeer) <- atomically $ do
        let processKick (peer,_) = do
                let p = peer == nodeId
                when p $ void $ tryTakeTMVar recHeaderVar
                pure (p, Just peer)
        maybe (pure (True,Nothing)) processKick =<< tryReadTMVar recHeaderVar
    when kicked $ logWarning $
        sformat ("Recovery mode communication dropped with peer "%build) nodeId
    unless kicked $
        logDebug $ "Recovery mode wasn't disabled: " <>
                   maybe "noth" show realPeer <> " vs " <> show nodeId
    pure kicked

-- | Drops recovery header and, if it was successful, queries tips.
dropRecoveryHeaderAndRepeat
    :: (BlockWorkMode ctx m)
    => EnqueueMsg m -> NodeId -> m ()
dropRecoveryHeaderAndRepeat enqueue nodeId = do
    kicked <- dropRecoveryHeader nodeId
    when kicked $ attemptRestartRecovery
  where
    attemptRestartRecovery = do
        logDebug "Attempting to restart recovery"
        delay $ sec 2
        handleAll handleRecoveryTriggerE $ triggerRecovery enqueue
        logDebug "Attempting to restart recovery over"
    handleRecoveryTriggerE =
        -- REPORT:ERROR 'reportOrLogE' somewhere in block retrieval.
        reportOrLogE $ "Exception happened while trying to trigger " <>
                       "recovery inside dropRecoveryHeaderAndRepeat: "

----------------------------------------------------------------------------
-- Block request/processing logic
----------------------------------------------------------------------------

-- Returns only if blocks were successfully downloaded and
-- processed. Throws exception if something goes wrong.
getProcessBlocks
    :: forall ctx m.
       (BlockWorkMode ctx m)
    => EnqueueMsg m
    -> NodeId
    -> BlockHeader
    -> HeaderHash
    -> m ()
getProcessBlocks enqueue nodeId lcaChild newestHash = do
    -- The conversation will attempt to retrieve the necessary blocks and apply
    -- them. Each one gives a 'Bool' where 'True' means that a recovery was
    -- completed (depends upon the state of the recovery-mode TMVar).
    enqueueMsgSingle enqueue (MsgRequestBlocks (S.singleton nodeId)) $ Conversation $
      \(conv :: ConversationActions MsgGetBlocks MsgBlock m) -> do
        let lcaChildHash = headerHash lcaChild
        logDebug $ sformat ("Requesting blocks from "%shortHashF%" to "%shortHashF)
                           lcaChildHash
                           newestHash
        send conv $ mkBlocksRequest lcaChildHash newestHash
        logDebug "Requested blocks, waiting for the response"
        chainE <- runExceptT (retrieveBlocks conv lcaChild newestHash)
        recHeaderVar <- view (lensOf @RecoveryHeaderTag)
        case chainE of
            Left e -> do
                let msg = sformat ("Error retrieving blocks from "%shortHashF%
                                   " to "%shortHashF%" from peer "%
                                   build%": "%stext)
                                  lcaChildHash newestHash nodeId e
                logWarning msg
                throwM $ DialogUnexpected msg
            Right blocks -> do
                logDebug $ sformat
                    ("Retrieved "%int%" blocks of total size "%builder%": "%listJson)
                    (blocks ^. _OldestFirst . to NE.length)
                    (unitBuilder $ biSize blocks)
                    (map (headerHash . view blockHeader) blocks)
                handleBlocks nodeId blocks enqueue
                dropUpdateHeader
                -- If we've downloaded any block with bigger
                -- difficulty than ncrecoveryheader, we're
                -- gracefully exiting recovery mode.
                let isMoreDifficultThan b x = b ^. difficultyL >= x ^. difficultyL
                exitedRecovery <- atomically $ tryReadTMVar recHeaderVar >>= \case
                    -- We're not in recovery mode? That must be ok.
                    Nothing -> pure False
                    -- If we're in recovery mode we should exit it if
                    -- any block is more difficult than one in
                    -- recHeader.
                    Just (_, rHeader) ->
                        if any (`isMoreDifficultThan` rHeader) blocks
                        then isJust <$> tryTakeTMVar recHeaderVar
                        else pure False
                when exitedRecovery $
                    logInfo "Recovery mode exited gracefully on receiving block we needed"


----------------------------------------------------------------------------
-- Block retrieving functions
----------------------------------------------------------------------------

retrieveBlocks
    :: (BlockWorkMode ctx m)
    => ConversationActions MsgGetBlocks MsgBlock m
    -> BlockHeader
    -> HeaderHash
    -> ExceptT Text m (OldestFirst NE Block)
retrieveBlocks conv lcaChild endH = do
    blocks <- retrieveBlocksDo 0 conv (lcaChild ^. prevBlockL) endH
    let b0 = blocks ^. _OldestFirst . _neHead
    if headerHash b0 == headerHash lcaChild
       then pure blocks
       else throwError $ sformat
                ("First block of chain is "%build%
                 " instead of expected "%build)
                (b0 ^. blockHeader) lcaChild

retrieveBlocksDo
    :: (BlockWorkMode ctx m)
    => Int        -- ^ Index of block we're requesting
    -> ConversationActions MsgGetBlocks MsgBlock m
    -> HeaderHash -- ^ We're expecting a child of this block
    -> HeaderHash -- ^ Block at which to stop
    -> ExceptT Text m (OldestFirst NE Block)
retrieveBlocksDo i conv prevH endH = lift (recvLimited conv) >>= \case
    Nothing ->
        throwError $ sformat ("Failed to receive block #"%int) i
    Just (MsgNoBlock t) ->
        throwError $ sformat ("Server failed to return block #"%int%": "%stext) i t
    Just (MsgBlock block) -> do
        let prevH' = block ^. prevBlockL
            curH = headerHash block
        when (prevH' /= prevH) $ do
            throwError $ sformat
                ("Received block #"%int%" with prev hash "%shortHashF%
                 " while "%shortHashF%" was expected: "%build)
                i prevH' prevH (block ^. blockHeader)
        progressHeaderVar <- view (lensOf @ProgressHeaderTag)
        atomically $ do void $ tryTakeTMVar progressHeaderVar
                        putTMVar progressHeaderVar $ block ^. blockHeader
        if curH == endH
        then pure $ one block
        else over _Wrapped (block <|) <$> retrieveBlocksDo (i+1) conv curH endH

----------------------------------------------------------------------------
-- Networking
----------------------------------------------------------------------------

-- | Expects sending message to exactly one node. Receives result or
-- fails if no result was obtained (no nodes available, timeout, etc).
enqueueMsgSingle ::
       (MonadThrow m)
    => (t2 -> (t1 -> t -> NonEmpty x) -> m (Map NodeId (m b)))
    -> t2
    -> x
    -> m b
enqueueMsgSingle enqueue msg conv = do
    results <- enqueue msg (\_ _ -> one conv) >>=
               waitForConversations
    case toList results of
        [] ->      throwM $ DialogUnexpected $
            "enqueueMsgSingle: contacted no peers"
        (_:_:_) -> throwM $ DialogUnexpected $
            "enqueueMsgSingle: contacted more than one peers, probably internal error"
        [x] -> pure x
