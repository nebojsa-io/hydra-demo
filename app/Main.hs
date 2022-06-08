module Main (main) where

import Cardano.Api (
  AddressInEra,
  AlonzoEra,
  AsType (AsAddressInEra, AsAlonzoEra, AsPaymentKey, AsSigningKey),
  BuildTxWith (BuildTxWith),
  CollateralSupportedInEra (CollateralInAlonzoEra),
  ExecutionUnits (ExecutionUnits, executionMemory, executionSteps),
  Hash,
  Key (getVerificationKey, verificationKeyHash),
  Lovelace (..),
  NetworkId (Testnet),
  NetworkMagic (NetworkMagic),
  PaymentCredential (PaymentCredentialByKey),
  PaymentKey,
  ScriptData,
  SerialiseAddress (deserialiseAddress, serialiseAddress),
  SigningKey,
  StakeAddressReference (NoStakeAddress),
  TxBody,
  TxBodyContent (txIns, txInsCollateral, txOuts, txProtocolParams),
  TxIn,
  TxInsCollateral (TxInsCollateral),
  TxOut (TxOut),
  TxOutDatum (TxOutDatumHash),
  UTxO (UTxO, unUTxO),
  hashScriptData,
  makeShelleyAddressInEra,
  makeTransactionBody,
  readFileTextEnvelope,
  txOutValueToValue,
  valueToLovelace,
 )
import Cardano.Api.Shelley (ProtocolParameters (protocolParamMaxTxExUnits))
import Control.Concurrent (newChan, readChan, writeChan)
import Control.Concurrent.Async (AsyncCancelled (AsyncCancelled), withAsync)
import Control.Exception (SomeException, displayException, fromException, try)
import Control.Monad (when)
import Control.Monad.IO.Class (MonadIO, liftIO)
import Control.Monad.Reader.Class (MonadReader, ask)
import Control.Monad.Trans.Reader (ReaderT, runReaderT)
import Data.Aeson (FromJSON, Result (Success), ToJSON, Value (String), decode, eitherDecode, eitherDecodeFileStrict', encode, fromJSON, (.:))
import Data.Aeson.Types (parseEither)
import Data.Bifunctor (first)
import Data.ByteString.Lazy (ByteString)
import Data.Kind (Type)
import Data.List (sortOn)
import Data.Map (Map)
import Data.Map qualified as Map (filter, lookupMin, mapMaybe, singleton, toList)
import Data.Maybe (fromMaybe, listToMaybe)
import Data.String (fromString)
import Data.Text.Lazy (Text, fromStrict)
import Data.Text.Lazy.Encoding (decodeUtf8, encodeUtf8)
import Data.Text.Lazy.IO qualified as Text (putStrLn)
import Ledger qualified (PubKeyHash, toCardanoAPIData)
import Ledger.Tx.CardanoAPI (fromCardanoPaymentKeyHash, toCardanoAddress)
import Network.WebSockets (ConnectionException, receiveData, runClient, sendTextData)
import PlutusTx (ToData (toBuiltinData))
import PlutusTx.Prelude (BuiltinByteString)
import System.Environment (getArgs)
import System.IO.Error (isEOFError)

import HydraRPS.Node.Command qualified as NodeCommand
import HydraRPS.OnChain (
  GameDatum (..),
  GameRedeemer (GameRedeemer),
  Gesture,
  beats,
  encryptGesture,
  rpsValidator,
  rpsValidatorAddress,
 )
import HydraRPS.Tx (
  TxDatum (TxDatum),
  TxRedeemer (TxRedeemer),
  baseBodyContent,
  parseTxIn,
  signTx,
  txInForSpending,
  txInForValidator,
  txOutToAddress,
  txOutToScript,
 )
import HydraRPS.UserInput qualified as UserInput

import Prelude

main :: IO ()
main = do
  nodeHost : nodePort : keyFile : protocolParamsFile : _ <- getArgs
  skey <- either (fail . show) pure =<< readFileTextEnvelope (AsSigningKey AsPaymentKey) keyFile
  pparamsResult <- either fail pure =<< eitherDecodeFileStrict' protocolParamsFile
  let networkId :: NetworkId
      networkId = Testnet (NetworkMagic 42)

      userCreds :: UserCredentials
      userCreds = mkUserCredentials networkId skey

      headState :: HeadState
      headState = HeadState userCreds networkId pparamsResult
  putStrLn $ "user pubKeyHash " <> show userCreds.userPubKeyHash
  Text.putStrLn $ "user address " <> fromStrict (serialiseAddress userCreds.userAddress) <> "\n"
  runClient nodeHost (read nodePort) "/" $ \ws -> do
    let nextServerEvent :: IO ByteString
        nextServerEvent = receiveData ws

        submitCommand :: (MonadIO m, ToJSON a) => a -> m ()
        submitCommand input = do
          let json = encode input
          liftIO $ Text.putStrLn $ "client input:\n" <> decodeUtf8 json <> "\n"
          liftIO $ sendTextData ws json

    events <- newChan
    let enqueueApiEvent :: Maybe ServerOutput -> IO ()
        enqueueApiEvent = writeChan events . ApiEvent

        enqueueUserCommand :: UserCommand -> IO ()
        enqueueUserCommand = writeChan events . UserCommand

        nextEvent :: IO AppEvent
        nextEvent = readChan events

    withAsync (apiReader nextServerEvent enqueueApiEvent) $ \_ ->
      withAsync (commandReader enqueueUserCommand) $ \_ ->
        runInHead headState (eventProcessor submitCommand nextEvent)

data HeadState = HeadState
  { hsUserCredentials :: UserCredentials
  , hsNetworkId :: NetworkId
  , hsProtocolParams :: ProtocolParameters
  }

newtype HeadM a = HeadM {unHeadM :: ReaderT HeadState IO a} deriving newtype (Functor, Applicative, Monad, MonadIO, MonadReader HeadState)

runInHead :: HeadState -> HeadM a -> IO a
runInHead c ba = runReaderT (unHeadM ba) c

data AppEvent
  = ApiEvent (Maybe ServerOutput)
  | UserCommand UserCommand

data ServerOutput
  = Other Text
  | HeadIsOpen (UTxO AlonzoEra)
  | SnapshotConfirmed (UTxO AlonzoEra)

data UserCommand
  = InitHead Int
  | CommitToHead (UTxO AlonzoEra)
  | Exit
  | AbortHead
  | CloseHead
  | IssueFanout
  | Bet UserInput.PlayParams
  | Claim GameRedeemer

data UserCredentials = UserCredentials
  { userSkey :: SigningKey PaymentKey
  , userPubKeyHash :: Ledger.PubKeyHash
  , userAddress :: AddressInEra AlonzoEra
  }

mkUserCredentials :: NetworkId -> SigningKey PaymentKey -> UserCredentials
mkUserCredentials networkId skey = UserCredentials skey pkh addr
  where
    vkeyHash = verificationKeyHash (getVerificationKey skey)
    pkh = fromCardanoPaymentKeyHash vkeyHash
    addr = makeShelleyAddressInEra networkId (PaymentCredentialByKey vkeyHash) NoStakeAddress

apiReader :: IO ByteString -> (Maybe ServerOutput -> IO ()) -> IO ()
apiReader nextServerEvent enqueue = go
  where
    go = do
      result <- try @ConnectionException nextServerEvent
      case result of
        Left e -> do
          putStrLn $ "node connection error: " <> show e
          enqueue Nothing
        Right o -> do
          Text.putStrLn $ "node output:\n" <> decodeUtf8 o
          case decodeServerOutput o of
            Left err -> putStrLn $ "node output decoding error: " <> err
            Right decoded -> enqueue $ Just decoded
          putStrLn ""
          go

decodeServerOutput :: ByteString -> Either String ServerOutput
decodeServerOutput bytes = do
  value <- eitherDecode bytes
  flip parseEither value $ \o -> do
    tag <- o .: "tag"
    case tag of
      "HeadIsOpen" -> HeadIsOpen <$> o .: "utxo"
      "SnapshotConfirmed" -> do
        snapshot <- o .: "snapshot"
        SnapshotConfirmed <$> snapshot .: "utxo"
      _ -> pure (Other tag)

unexpectedInputException :: SomeException -> Bool
unexpectedInputException ex
  | Just io <- fromException ex, isEOFError io = False
  | Just AsyncCancelled <- fromException ex = False
  | otherwise = True

commandReader :: (UserCommand -> IO ()) -> IO ()
commandReader enqueue = go
  where
    go = do
      result <- try @SomeException getLine
      case result of
        Left ex -> do
          when (unexpectedInputException ex) $
            putStrLn $ "input error: " <> displayException ex
          enqueue Exit
        Right command -> case words command of
          [] -> go -- skip empty input for convenience
          ["exit"] -> enqueue Exit
          ["abort"] -> enqueue AbortHead >> go
          ["close"] -> enqueue CloseHead >> go
          ["fanout"] -> enqueue IssueFanout >> go
          ["init", str] | [(period, "")] <- reads str -> do
            enqueue $ InitHead period
            go
          ["commit", txInStr, addrStr, lovelaceStr]
            | Right txIn <- parseTxIn (fromString txInStr)
              , Just addr <- deserialiseAddress (AsAddressInEra AsAlonzoEra) (fromString addrStr)
              , Just lovelace <- parseLovelace lovelaceStr -> do
              enqueue $ CommitToHead $ UTxO $ Map.singleton txIn (txOutToAddress addr lovelace)
              go
          ["bet", gestureStr, saltStr]
            | Success gesture <- readFromJsonString gestureStr
            , Success salt <- readFromJsonString saltStr -> do
              enqueue $ Bet $ UserInput.PlayParams gesture salt
              go
          "claim" : redeemerStr
            | Just redeemer <- parseJsonArgs redeemerStr -> enqueue (Claim redeemer) >> go
          cmd -> do
            putStrLn $ "input: unknown command " <> show cmd
            go

    parseJsonArgs :: FromJSON a => [String] -> Maybe a
    parseJsonArgs = decode . encodeUtf8 . fromString . unwords

    readFromJsonString :: FromJSON a => String -> Result a
    readFromJsonString = fromJSON . String . fromString

    parseLovelace :: String -> Maybe Lovelace
    parseLovelace str
      | [(lovelace, "")] <- reads str = Just (Lovelace lovelace)
      | otherwise = Nothing

eventProcessor :: forall (m :: Type -> Type). (MonadIO m, MonadReader HeadState m) => (NodeCommand.Command -> m ()) -> IO AppEvent -> m ()
eventProcessor submit nextEvent = openTheHead
  where
    openTheHead :: m ()
    openTheHead = do
      event <- liftIO nextEvent
      case event of
        ApiEvent apiEvent ->
          case apiEvent of
            Just serverOutput -> do
              case serverOutput of
                HeadIsOpen utxo -> do
                  liftIO $ putStrLn $ "head is opened\n" <> show utxo <> "\n"
                  playTheGame utxo
                SnapshotConfirmed utxo -> do
                  liftIO $ putStrLn $ "unexpected snapshot confirmation (head is not opened yet)\n" <> show utxo <> "\n"
                  openTheHead
                Other tag -> do
                  liftIO $ Text.putStrLn $ "decoded node output: " <> tag <> "\n"
                  openTheHead
            Nothing -> return ()
        UserCommand command ->
          case command of
            Exit -> return ()
            InitHead period -> submit (NodeCommand.Init period) >> openTheHead
            AbortHead -> submit NodeCommand.Abort >> openTheHead
            CommitToHead utxoToCommit -> submit (NodeCommand.Commit utxoToCommit) >> openTheHead
            _ -> do
              liftIO $ putStrLn "head is not opened yet"
              openTheHead

    playTheGame :: UTxO AlonzoEra -> m ()
    playTheGame utxo = do
      event <- liftIO nextEvent
      case event of
        ApiEvent apiEvent ->
          case apiEvent of
            Just serverOutput -> do
              case serverOutput of
                Other tag -> do
                  liftIO $ Text.putStrLn $ "decoded node output: " <> tag <> "\n"
                  playTheGame utxo
                HeadIsOpen unexpectedUtxo -> do
                  liftIO $ putStrLn $ "unexpected head opening (head is already opened)\n" <> show unexpectedUtxo <> "\n"
                  playTheGame utxo
                SnapshotConfirmed updatedUtxo -> do
                  liftIO $ putStrLn $ "snapshot confirmed\n" <> show updatedUtxo <> "\n"
                  playTheGame updatedUtxo
            Nothing -> return ()
        UserCommand command ->
          case command of
            Exit -> return ()
            CloseHead -> submit NodeCommand.Close >> playTheGame utxo
            IssueFanout -> do
              -- TODO proper close/fan-out sequence
              submit NodeCommand.Fanout
              openTheHead
            Bet pp -> do
              state <- ask
              let inputAllocation =
                    allocateUtxos betConstant
                      $ sortOn snd
                        $ Map.toList
                          $ extractLovelace
                            $ utxosAt state.hsUserCredentials.userAddress utxo
              case inputAllocation of
                Nothing -> do
                  liftIO $ putStrLn "not enough funds"
                  playTheGame utxo
                Just (refs, total) -> do
                  let unsignedTx = either error id $ buildBetTx refs total state pp
                      signedTx = signTx state.hsUserCredentials.userSkey unsignedTx
                  submit (NodeCommand.newTx signedTx)
                  playTheGame utxo
            Claim redeemer -> do
              state <- ask
              let txResult = do
                    collateralTxIn <-
                      maybe (Left "could not find collateral") (Right . fst)
                        $ Map.lookupMin
                          $ unUTxO
                            $ utxosAt state.hsUserCredentials.userAddress utxo
                    scriptAddress <- first (("toCardanoAddress: " <>) . show) $ toCardanoAddress state.hsNetworkId rpsValidatorAddress
                    let betUtxos = utxosAt scriptAddress utxo
                    unsignedTx <- buildClaimTx collateralTxIn state (filterUtxos redeemer betUtxos) redeemer
                    pure $ signTx state.hsUserCredentials.userSkey unsignedTx
              case txResult of
                Left err -> liftIO $ putStrLn $ "claim tx building failed: " <> err
                Right signedTx -> submit (NodeCommand.newTx signedTx)
              playTheGame utxo
            _ -> do
              liftIO $ putStrLn "head is already opened"
              playTheGame utxo

utxosAt :: AddressInEra AlonzoEra -> UTxO AlonzoEra -> UTxO AlonzoEra
utxosAt addr (UTxO utxo) = UTxO (Map.filter matchAddress utxo)
  where matchAddress (TxOut txAddr _ _) = txAddr == addr

extractLovelace :: UTxO AlonzoEra -> Map TxIn Lovelace
extractLovelace (UTxO utxo) = Map.mapMaybe toLovelace utxo
  where toLovelace (TxOut _ txValue _) = valueToLovelace (txOutValueToValue txValue)

allocateUtxos :: Lovelace -> [(TxIn, Lovelace)] -> Maybe ([TxIn], Lovelace)
allocateUtxos _ [] = Nothing
allocateUtxos target ((txIn, lovelace) : rest)
  | target <= lovelace = Just ([txIn], lovelace)
  | Just (refs, available) <- allocateUtxos (target - lovelace) rest = Just (txIn : refs, lovelace + available)
  | otherwise = Nothing

betConstant :: Lovelace
betConstant = 10000000

buildDatum :: UserInput.PlayParams -> Ledger.PubKeyHash -> GameDatum
buildDatum playParams pkh =
  GameDatum
    { gdGesture = encryptGesture playParams.ppGesture playParams.ppSalt
    , gdPkh = pkh
    }

-- precondition: inputTotal >= betConstant
buildBetTx :: [TxIn] -> Lovelace -> HeadState -> UserInput.PlayParams -> Either String (TxBody AlonzoEra)
buildBetTx inputRefs inputTotal state playParams = do
  let changeAddress = state.hsUserCredentials.userAddress
      datum = buildDatum playParams state.hsUserCredentials.userPubKeyHash
  scriptOut <-
    first (("bad address specifier: " <>) . show) $
      txOutToScript state.hsNetworkId rpsValidatorAddress betConstant (TxDatum datum)
  let changeOut
        | inputTotal > betConstant = [txOutToAddress changeAddress (inputTotal - betConstant)]
        | otherwise = []
      bodyContent =
        baseBodyContent
          { txIns = txInForSpending <$> inputRefs
          , txOuts = scriptOut : changeOut
          }
  first (("bad tx-body: " <>) . show) $ makeTransactionBody bodyContent

buildClaimTx :: TxIn -> HeadState -> [(TxIn, Gesture, GameDatum)] -> GameRedeemer -> Either String (TxBody AlonzoEra)
buildClaimTx collateralTxIn state [(myTxIn, myGesture, myDatum), (theirTxIn, theirGesture, theirDatum)] redeemer
  | beats myGesture theirGesture = do
    let maxTxExUnits =
          fromMaybe ExecutionUnits {executionSteps = 0, executionMemory = 0} $
            protocolParamMaxTxExUnits state.hsProtocolParams
        exUnits =
          ExecutionUnits
            { executionSteps = executionSteps maxTxExUnits `div` 2
            , executionMemory = executionMemory maxTxExUnits `div` 2
            }
        outAddress = state.hsUserCredentials.userAddress

    myValidatorTxIn <-
      first (("bad script: " <>) . show) $
        txInForValidator myTxIn rpsValidator (TxDatum myDatum) (TxRedeemer redeemer) exUnits
    theirValidatorIxIn <-
      first (("bad script: " <>) . show) $
        txInForValidator theirTxIn rpsValidator (TxDatum theirDatum) (TxRedeemer redeemer) exUnits

    let bodyContent =
          baseBodyContent
            { txIns = [myValidatorTxIn, theirValidatorIxIn]
            , txInsCollateral = TxInsCollateral CollateralInAlonzoEra [collateralTxIn]
            , txOuts = [txOutToAddress outAddress (2 * betConstant)]
            , txProtocolParams = BuildTxWith (Just state.hsProtocolParams)
            }
    first (("bad tx-body: " <>) . show) $ makeTransactionBody bodyContent
  | otherwise = Left "you are not a winner"

buildClaimTx _ _ _ _ = Left "bad input parameters"

filterUtxos :: GameRedeemer -> UTxO AlonzoEra -> [(TxIn, Gesture, GameDatum)]
filterUtxos (GameRedeemer (myPk, mySalt) (theirPk, theirSalt)) (UTxO utxos) =
  foldl step [] (Map.toList utxos)
  where
    step acc (tOutRef, TxOut _ _ (TxOutDatumHash _ dh))
      | Just (gesture, datum) <- extractGesture myPk mySalt dh = (tOutRef, gesture, datum) : acc
      | Just (gesture, datum) <- extractGesture theirPk theirSalt dh = acc ++ [((tOutRef, gesture, datum))]
      | otherwise = acc
    step acc _ = acc

    extractGesture :: Ledger.PubKeyHash -> BuiltinByteString -> Hash ScriptData -> Maybe (Gesture, GameDatum)
    extractGesture key salt dh = listToMaybe
      [ (gesture, datum)
      | gesture <- [minBound .. maxBound]
      , let datum = buildDatum (UserInput.PlayParams gesture salt) key
      , hashScriptData (Ledger.toCardanoAPIData (toBuiltinData datum)) == dh
      ]
