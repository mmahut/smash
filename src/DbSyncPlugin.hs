{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE LambdaCase #-}

module DbSyncPlugin
  ( poolMetadataDbSyncNodePlugin
  ) where

import           Cardano.Prelude

import           Cardano.BM.Trace (Trace, logInfo, logError)

import           Control.Monad.Logger (LoggingT)
import           Control.Monad.Trans.Reader (ReaderT)
import           Control.Monad.Trans.Except.Extra (firstExceptT, newExceptT, runExceptT, handleExceptT, left)

import           DB (DataLayer (..), DBFail (..), postgresqlDataLayer)
import           Types (PoolHash (..), PoolOfflineMetadata)

import           Data.Aeson (eitherDecode')
import qualified Data.ByteString.Lazy as BL

import qualified Cardano.Crypto.Hash.Class as Crypto
import qualified Cardano.Crypto.Hash.Blake2b as Crypto

import qualified Data.ByteString.Base16 as B16

import           Network.HTTP.Client hiding (Proxy)
import           Network.HTTP.Client.TLS (tlsManagerSettings)
import           Network.HTTP.Types.Status (statusCode)

import           Database.Persist.Sql (SqlBackend)

import qualified Cardano.Db.Schema as DB
import           Cardano.Db.Insert (insertPoolMetaData)

import           Cardano.DbSync.Error
import           Cardano.DbSync.Types

import           Cardano.DbSync (DbSyncNodePlugin (..), defDbSyncNodePlugin)

import qualified Cardano.DbSync.Era.Shelley.Util as Shelley

import           Shelley.Spec.Ledger.BaseTypes (strictMaybeToMaybe)
import qualified Shelley.Spec.Ledger.BaseTypes as Shelley
import qualified Shelley.Spec.Ledger.Tx as Shelley
import qualified Shelley.Spec.Ledger.TxData as Shelley


poolMetadataDbSyncNodePlugin :: DbSyncNodePlugin
poolMetadataDbSyncNodePlugin =
  defDbSyncNodePlugin
    { plugOnStartup = []
        --plugOnStartup defDbSyncNodePlugin ++ [epochPluginOnStartup] ++ []

    , plugInsertBlock = [insertCardanoBlock]
        --plugInsertBlock defDbSyncNodePlugin ++ [epochPluginInsertBlock] ++ [insertCardanoBlock]

    , plugRollbackBlock = []
        --plugRollbackBlock defDbSyncNodePlugin ++ [epochPluginRollbackBlock] ++ []
    }

insertCardanoBlock
    :: Trace IO Text -> DbSyncEnv -> CardanoBlockTip
    -> ReaderT SqlBackend (LoggingT IO) (Either DbSyncNodeError ())
insertCardanoBlock tracer _env blkTip = do
  case blkTip of
    ByronBlockTip _blk _tip -> pure $ Right ()  --insertByronBlock tracer blk tip
    ShelleyBlockTip blk tip -> insertShelleyBlock tracer blk tip

-- We don't care about Byron, no pools there
--insertByronBlock
--    :: Trace IO Text -> ByronBlock -> Tip ByronBlock
--    -> ReaderT SqlBackend (LoggingT IO) (Either DbSyncNodeError ())
--insertByronBlock tracer blk tip = do
--  runExceptT $
--    liftIO $ do
--      let epoch = Byron.slotNumber blk `div` 5000
--      logInfo tracer $ mconcat
--        [ "insertByronBlock: epoch ", show epoch
--        , ", slot ", show (Byron.slotNumber blk)
--        , ", block ", show (Byron.blockNumber blk)
--        ]

insertShelleyBlock
    :: Trace IO Text -> ShelleyBlock -> Tip ShelleyBlock
    -> ReaderT SqlBackend (LoggingT IO) (Either DbSyncNodeError ())
insertShelleyBlock tracer blk _tip = do
  runExceptT $ do
    zipWithM_ (insertTx tracer) [0 .. ] (Shelley.blockTxs blk)

    liftIO $ do
      let epoch = Shelley.slotNumber blk `div` 5000
      logInfo tracer $ mconcat
        [ "insertShelleyBlock pool info: epoch ", show epoch
        , ", slot ", show (Shelley.slotNumber blk)
        , ", block ", show (Shelley.blockNumber blk)
        ]

insertTx
    :: (MonadIO m)
    => Trace IO Text -> Word64 -> ShelleyTx
    -> ExceptT DbSyncNodeError (ReaderT SqlBackend m) ()
insertTx tracer _blockIndex tx =
    mapM_ (insertPoolCert tracer) (Shelley.txPoolCertificates $ Shelley._body tx)

insertPoolCert
    :: (MonadIO m)
    => Trace IO Text -> ShelleyPoolCert
    -> ExceptT DbSyncNodeError (ReaderT SqlBackend m) ()
insertPoolCert tracer pCert =
  case pCert of
    Shelley.RegPool pParams -> void $ insertPoolRegister tracer pParams
    Shelley.RetirePool _keyHash _epochNum -> pure ()
        -- Currently we just maintain the data for the pool, we might not want to
        -- know whether it's registered

insertPoolRegister
    :: forall m. (MonadIO m)
    => Trace IO Text -> ShelleyPoolParams
    -> ExceptT DbSyncNodeError (ReaderT SqlBackend m) (Maybe DB.PoolMetaDataId)
insertPoolRegister tracer params = do
  liftIO . logInfo tracer $ "Inserting pool register."
  poolMetadataId <- case strictMaybeToMaybe $ Shelley._poolMD params of
    Just md -> do

        let eitherPoolMetadata :: IO (Either DbSyncNodeError (Response BL.ByteString))
            eitherPoolMetadata = runExceptT (fetchInsertPoolMetadata tracer md)

        liftIO $ eitherPoolMetadata >>= \case
                Left err -> logError tracer $ renderDbSyncNodeError err
                Right response -> logInfo tracer (decodeUtf8 . BL.toStrict $ responseBody response)

        liftIO . logInfo tracer $ "Inserting metadata."
        pmId <- Just <$> insertMetaData tracer md
        liftIO . logInfo tracer $ "Metadata inserted."

        return pmId

    Nothing -> pure Nothing

  liftIO . logInfo tracer $ "Inserted pool register."
  return poolMetadataId

fetchInsertPoolMetadata
    :: Trace IO Text
    -> Shelley.PoolMetaData
    -> ExceptT DbSyncNodeError IO (Response BL.ByteString)
fetchInsertPoolMetadata tracer md = do
    -- Fetch the JSON info!
    liftIO . logInfo tracer $ "Fetching JSON metadata."

    let poolUrl = Shelley.urlToText (Shelley._poolMDUrl md)

    -- This is a bit bad to do each time, but good enough for now.
    manager <- liftIO $ newManager tlsManagerSettings

    liftIO . logInfo tracer $ "Request created with URL '" <> poolUrl <> "'."

    let exceptRequest :: ExceptT DbSyncNodeError IO Request
        exceptRequest = handleExceptT (\(e :: HttpException) -> NEError $ show e) (parseRequest $ toS poolUrl)

    request <- exceptRequest

    liftIO . logInfo tracer $ "HTTP Client GET request."

    let httpRequest :: MonadIO n => n (Response BL.ByteString)
        httpRequest = liftIO $ httpLbs request manager

    response <- handleExceptT (\(e :: HttpException) -> NEError $ show e) httpRequest

    liftIO . logInfo tracer $ "HTTP GET request complete."
    liftIO . logInfo tracer $ "The status code was: " <> (show $ statusCode $ responseStatus response)

    let poolMetadataJson = decodeUtf8 . BL.toStrict $ responseBody response

    let mdHash :: ByteString
        mdHash = Shelley._poolMDHash md

    let poolHash :: Text
        poolHash = decodeUtf8 . B16.encode $ mdHash

    liftIO . logInfo tracer $ "Inserting pool with hash: " <> poolHash

    let dataLayer :: DataLayer
        dataLayer = postgresqlDataLayer

    -- Let us try to decode the contents to JSON.
    let decodedPoolMetadataJSON :: Either DBFail PoolOfflineMetadata
        decodedPoolMetadataJSON = case (eitherDecode' (responseBody response)) of
            Left err -> Left $ UnableToEncodePoolMetadataToJSON $ toS err
            Right result -> return result

    _exceptDecodedMetadata <- firstExceptT (\e -> NEError $ show e) (newExceptT $ pure decodedPoolMetadataJSON)

    -- Let's check the hash
    let poolHashBytestring = encodeUtf8 poolHash
    let hashFromMetadata = B16.encode $ Crypto.digest (Proxy :: Proxy Crypto.Blake2b_256) (encodeUtf8 poolMetadataJson)

    when (hashFromMetadata /= poolHashBytestring) $
        left $ NEError ("The pool hash does not match. '" <> poolHash <> "'")


    liftIO . logInfo tracer $ "Inserting JSON offline metadata."
    _ <- liftIO $ (dlAddPoolMetadata dataLayer) (PoolHash poolHash) poolMetadataJson

    pure response

insertMetaData
    :: (MonadIO m)
    => Trace IO Text -> Shelley.PoolMetaData
    -> ExceptT DbSyncNodeError (ReaderT SqlBackend m) DB.PoolMetaDataId
insertMetaData _tracer md =
  lift . insertPoolMetaData $
    DB.PoolMetaData
      { DB.poolMetaDataUrl = Shelley.urlToText (Shelley._poolMDUrl md)
      , DB.poolMetaDataHash = Shelley._poolMDHash md
      }

--insertPoolRetire
--    :: (MonadIO m)
--    => EpochNo -> ShelleyStakePoolKeyHash
--    -> ExceptT DbSyncNodeError (ReaderT SqlBackend m) ()
--insertPoolRetire epochNum keyHash = do
--  poolId <- firstExceptT (NELookup "insertPoolRetire") . newExceptT $ queryStakePoolKeyHash keyHash
--  void . lift . DB.insertPoolRetire $
--    DB.PoolRetire
--      { DB.poolRetirePoolId = poolId
--      , DB.poolRetireRetiringEpoch = unEpochNo epochNum
--      }
