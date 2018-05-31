{-# LANGUAGE FunctionalDependencies     #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE TemplateHaskell            #-}

module InputSelection.Policy (
    -- * Infrastructure
    LiftQuickCheck(..)
  , RunPolicy(..)
  , PrivacyMode(..)
  , InputSelectionPolicy
  , InputSelectionFailure (..)
  , HasTreasuryAddress (..)
    -- * Transaction statistics
  , TxStats(..)
    -- * Specific policies
  , largestFirst
  , random
  ) where

import           Universum

import           Control.Lens ((%=), (.=))
import           Control.Lens.TH (makeLenses)
import           Control.Monad.Except (MonadError (..))
import qualified Data.Map as Map
import qualified Data.Set as Set
import           Test.QuickCheck

import           Cardano.Wallet.Kernel.CoinSelection.Types (ExpenseRegulation (..))

import           Util.Histogram (BinSize (..), Histogram)
import qualified Util.Histogram as Histogram
import           Util.MultiSet (MultiSet)
import qualified Util.MultiSet as MultiSet
import           UTxO.DSL

{-------------------------------------------------------------------------------
  Auxiliary: lift QuickCheck computations
-------------------------------------------------------------------------------}

-- | Monads in which we can run QuickCheck generators
class Monad m => LiftQuickCheck m where
   -- | Run a QuickCheck computation
  liftQuickCheck :: Gen x -> m x

-- | TODO: We probably don't want this instance (or abstract in a different
-- way over "can generate random numbers")
instance LiftQuickCheck IO where
  liftQuickCheck = generate

instance LiftQuickCheck m => LiftQuickCheck (StateT s m) where
  liftQuickCheck = lift . liftQuickCheck

{-------------------------------------------------------------------------------
  Transaction statistics
-------------------------------------------------------------------------------}

-- | Transaction statistics
--
-- Transaction statistics are used for policy evaluation. For "real" input
-- selection policies we don't necessarily need to return this information,
-- although it may be beneficial to do so even there -- it may be useful
-- to monitor these statistics and learn something about the wallet as it
-- operates in reality.
data TxStats = TxStats {
      -- | Number of inputs
      --
      -- This is a histogram because although a single transaction only has
      -- a single value for its number of inputs, recording this as a histogram
      -- allows us to combine the statistics of many transactions.
      txStatsNumInputs :: !Histogram

      -- | Change/payment ratios
    , txStatsRatios    :: !(MultiSet Double)
    }

instance Monoid TxStats where
  mempty = TxStats {
        txStatsNumInputs = Histogram.empty
      , txStatsRatios    = MultiSet.empty
      }
  mappend a b = TxStats {
        txStatsNumInputs = mappendUsing Histogram.add  txStatsNumInputs
      , txStatsRatios    = mappendUsing MultiSet.union txStatsRatios
      }
    where
      mappendUsing :: (a -> a -> a) -> (TxStats -> a) -> a
      mappendUsing op f = f a `op` f b

-- | Partial transaciton statistics
--
-- Partial transactions statistics are useful when constructing a transaciton
-- piece by piece.
data PartialTxStats = PartialTxStats {
      -- | Number of inputs
      --
      -- Unlike for 'TxStats', this is not a histogram. Suppose we have two
      -- 'PartialTxStats' with 'ptxStatsNumInputs' equal to @n@ and @m@.
      -- Then the final histogram should have a single bin at @n + m@ with
      -- count 1. This is rather different from having two transactions with
      -- @n@ inputs and @m@ outputs; this would result in a histogram with
      -- /two/ bins at @n@ and @m@ both with count 1, or, if @n == m@, a
      -- single bin at @n@ with count 2.
      ptxStatsNumInputs :: !Int

      -- | Change/payment ratios
    , ptxStatsRatios    :: !(MultiSet Double)
    }

instance Monoid PartialTxStats where
  mempty = PartialTxStats {
        ptxStatsNumInputs = 0
      , ptxStatsRatios    = MultiSet.empty
      }
  mappend a b = PartialTxStats {
        ptxStatsNumInputs = mappendUsing (+)            ptxStatsNumInputs
      , ptxStatsRatios    = mappendUsing MultiSet.union ptxStatsRatios
      }
    where
      mappendUsing :: (a -> a -> a) -> (PartialTxStats -> a) -> a
      mappendUsing op f = f a `op` f b

-- | Construct transaciton statistics from partial statistics
fromPartialTxStats :: PartialTxStats -> TxStats
fromPartialTxStats PartialTxStats{..} = TxStats{
      txStatsNumInputs = Histogram.singleton (BinSize 1) ptxStatsNumInputs 1
    , txStatsRatios    = ptxStatsRatios
    }

{-------------------------------------------------------------------------------
  Policy
-------------------------------------------------------------------------------}

class Eq a => HasTreasuryAddress a where
    treasuryAddr :: a

instance HasTreasuryAddress () where
    treasuryAddr = ()

-- | Monads in which we can run input selection policies
class Monad m => RunPolicy m a | m -> a where
  -- | Generate change address
  genChangeAddr :: m a

  -- | Generate fresh hash
  genFreshHash :: m Int

data InputSelectionFailure a = InputSelectionFailure
                             -- ^ A generic failure
                             | InsufficientFundsToCoverFee ExpenseRegulation (Output a)
                             -- ^ We need extra funds to cover the fee.

type InputSelectionPolicy h a m =
      (HasTreasuryAddress a, RunPolicy m a, Hash h a)
   => (Int -> [Value] -> Value)
      -- ^ Function to estimate the fee
   -> ExpenseRegulation
      -- ^ The expense regulation (i.e. how pays for the fee)
   -> Utxo h a
      -- ^ The initial UTXO
   -> [Output a]
      -- ^ The initial outputs we need to pay.
   -> m (Either (InputSelectionFailure a) (Transaction h a, TxStats))

{-------------------------------------------------------------------------------
  Input selection combinator
-------------------------------------------------------------------------------}

data InputPolicyState h a = InputPolicyState {
      -- | Available entries in the UTxO
      _ipsUtxo             :: Utxo h a

      -- | Selected inputs
    , _ipsSelectedInputs   :: Set (Input h a)

      -- | Generated outputs (e.g. change addresses)
    , _ipsGeneratedOutputs :: [Output a]
    }

initInputPolicyState :: Utxo h a -> InputPolicyState h a
initInputPolicyState utxo = InputPolicyState {
      _ipsUtxo             = utxo
    , _ipsSelectedInputs   = Set.empty
    , _ipsGeneratedOutputs = []
    }

makeLenses ''InputPolicyState

newtype InputPolicyT h a m x = InputPolicyT {
      unInputPolicyT :: StateT (InputPolicyState h a) (ExceptT (InputSelectionFailure a) m) x
    }
  deriving ( Functor
           , Applicative
           , Monad
           , MonadState (InputPolicyState h a)
           , MonadError (InputSelectionFailure a)
           )

instance MonadTrans (InputPolicyT h a) where
  lift = InputPolicyT . lift . lift

instance LiftQuickCheck m => LiftQuickCheck (InputPolicyT h a m) where
  liftQuickCheck = lift . liftQuickCheck

instance RunPolicy m a => RunPolicy (InputPolicyT h a m) a where
  genChangeAddr = lift genChangeAddr
  genFreshHash  = lift genFreshHash

runInputPolicyT :: forall h a m. RunPolicy m a
                => (Int -> [Value] -> Value)
                -- ^ A function to estimate the fee.
                -> ExpenseRegulation
                -- ^ Who pays the fees, if the sender or the receivers.
                -> Utxo h a
                -- ^ The original UTXO.
                -> [Output a]
                -- ^ The original outputs we need to pay to.
                -> InputPolicyT h a m PartialTxStats
                -- ^ The input policy
                -> m (Either (InputSelectionFailure a) (Transaction h a, TxStats))
runInputPolicyT estimateFee expenseRegulation originalUtxo originalOutputs policyT = do
     mx <- runExceptT (runStateT (unInputPolicyT policyT) initSt)
     case mx of
       Left err ->
         return $ Left err
       Right (ptxStats, finalSt) -> do
         let selectedInputs   = finalSt ^. ipsSelectedInputs
             generatedOutputs = finalSt ^. ipsGeneratedOutputs
             inputsLen = length selectedInputs
             allOutputs = generatedOutputs <> originalOutputs
             upperBoundFee = estimateFee inputsLen (map outVal allOutputs)
         case handleFee upperBoundFee selectedInputs of
            Left e -> return (Left e)
            Right (finalInputs, finalOutputs) -> do
              h <- genFreshHash
              return $ Right (
                  Transaction {
                      trFresh = 0
                    , trIns   = finalInputs
                    , trOuts  = finalOutputs <> generatedOutputs
                    , trFee   = upperBoundFee
                    , trHash  = h
                    , trExtra = []
                    }
                , fromPartialTxStats ptxStats
                )
  where
    initSt = initInputPolicyState originalUtxo

    -- Calculates the \"slice\" each Output has to pay.
    -- TODO(adn) avoid division by 0.
    -- TODO(adn) Rounding errors?
    epsilon :: Value -> Output a -> Value
    epsilon totalFee o = ceiling $ (fromIntegral (outVal o) / fromIntegral totalOutputValue) * ((fromIntegral totalFee) :: Double)

    totalOutputValue :: Value
    totalOutputValue = foldl' (\acc o -> acc + (outVal o)) 0 originalOutputs

    handleFee :: Value -> Set (Input h a) -> RegulationResult h a
    handleFee totalFee selectedInputs =
        case expenseRegulation of
            ReceiverPaysFee ->
                case foldl' (receiverCanAfford totalFee) ([], []) originalOutputs of
                     ([], amendedOutputs) ->
                         Right (selectedInputs, amendedOutputs)
                     (e : _, _) -> Left e
            SenderPaysFee  -> checkSenderCanAffordFee selectedInputs

    receiverCanAfford :: Value
                      -> ([InputSelectionFailure a], [Output a])
                      -> Output a
                      -> ([InputSelectionFailure a], [Output a])
    receiverCanAfford totalFee (!ls, !rs) o =
        case canCover o of
            Left l  -> (l : ls, rs)
            Right r -> (ls, r : rs)
        where
            canCover :: Output a -> Either (InputSelectionFailure a) (Output a)
            canCover output =
                let original = outVal output
                    amended  = original - (epsilon totalFee output)
                in case amended > original of -- We underflowed
                       True  -> Left (InsufficientFundsToCoverFee ReceiverPaysFee output)
                       False -> Right (output { outVal = amended })

    -- TODO.
    checkSenderCanAffordFee :: Set (Input h a) -> RegulationResult h a
    checkSenderCanAffordFee selectedInputs = Right (selectedInputs, originalOutputs)

type RegulationResult h a =
    Either (InputSelectionFailure a) (Set (Input h a), [Output a])

{-------------------------------------------------------------------------------
  Always find the largest UTxO possible
-------------------------------------------------------------------------------}

largestFirst :: forall h a m. InputSelectionPolicy h a m
largestFirst estimateFee expenseRegulation utxo goals =
  runInputPolicyT estimateFee expenseRegulation utxo goals (largestFirstT goals)

-- | Always use largest UTxO possible
--
-- NOTE: This is a very efficient implementation. Doesn't really matter, this
-- is just for testing; we're not actually considering using such a policy.
largestFirstT :: forall h a m. (RunPolicy m a, Hash h a)
              => [Output a]
              -> InputPolicyT h a m PartialTxStats
largestFirstT goals = mconcat <$> mapM go goals
  where
    go :: Output a -> InputPolicyT h a m PartialTxStats
    go (Output _a val) = do
        sorted   <- sortBy sortKey . utxoToList <$> use ipsUtxo
        selected <- case select sorted utxoEmpty 0 of
                      Nothing -> throwError InputSelectionFailure
                      Just u  -> return u

        ipsUtxo             %= utxoRemoveInputs (utxoDomain selected)
        ipsSelectedInputs   %= Set.union (utxoDomain selected)

        let selectedSum = utxoBalance selected
            change      = selectedSum - val

        unless (change == 0) $ do
          changeAddr <- genChangeAddr
          ipsGeneratedOutputs %= (Output changeAddr change :)

        return PartialTxStats {
            ptxStatsNumInputs = utxoSize selected
          , ptxStatsRatios    = MultiSet.singleton (fromIntegral change / fromIntegral val)
          }
      where
        select :: [(Input h a, Output a)] -- ^ Sorted available UTxO
               -> Utxo h a                -- ^ Selected UTxO
               -> Value                   -- ^ Accumulated value
               -> Maybe (Utxo h a)
        select _                   acc accSum | accSum >= val = Just acc
        select []                  _   _      = Nothing
        select ((i, o):available') acc accSum =
            select available' (utxoInsert (i, o) acc) (accSum + outVal o)

    -- Sort by output value, descending
    sortKey :: (Input h a, Output a) -> (Input h a, Output a) -> Ordering
    sortKey = flip (comparing (outVal . snd))

{-------------------------------------------------------------------------------
  Random
-------------------------------------------------------------------------------}

data PrivacyMode = PrivacyModeOn | PrivacyModeOff

random :: forall h a m. LiftQuickCheck m
       => PrivacyMode
       -> InputSelectionPolicy h a m
random privacyMode estimateFee expenseRegulation utxo goals =
  runInputPolicyT estimateFee expenseRegulation utxo goals (randomT privacyMode goals)

-- | Random input selection
--
-- Random input selection has the advantage that is it self correcting, in the
-- following sense: suppose that 90% of our UTxO consists of small outputs;
-- then random selection has a 90% change of choosing those small outputs.
--
-- For each output we add a change output that is between 0.5 and 2 times the
-- size of the output, making it hard to identify. This has the additional
-- benefit of introducing another self-correction: if there are frequent
-- requests for payments around certain size, the UTxO will contain lots of
-- available change outputs of around that size.
randomT :: forall h a m. (RunPolicy m a, LiftQuickCheck m, Hash h a)
        => PrivacyMode
        -> [Output a]
        -> InputPolicyT  h a m PartialTxStats
randomT privacyMode goals = mconcat <$> mapM go goals
  where
    go :: Output a -> InputPolicyT h a m PartialTxStats
    go (Output _a val) = do
        -- First attempt to find a change output in the ideal range.
        -- Failing that, try to at least cover the value.
        --
        -- TODO: We should take deposit/payment ratio into account and
        -- change number of change outputs accordingly
        selected <- case privacyMode of
          PrivacyModeOff -> randomInRange fallback
          PrivacyModeOn  -> randomInRange ideal `catchError` \_err ->
                            randomInRange fallback
        ipsSelectedInputs   %= Set.union (utxoDomain selected)
        let selectedSum = utxoBalance selected
            change      = selectedSum - val
        unless (change == 0) $ do
          changeAddr <- genChangeAddr
          ipsGeneratedOutputs %= (Output changeAddr change :)
        return PartialTxStats {
            ptxStatsNumInputs = utxoSize selected
          , ptxStatsRatios    = MultiSet.singleton (fromIntegral change / fromIntegral val)
          }
      where
        changeMin = val `div` 2
        changeMax = val *     2
        ideal     = (val + changeMin, val + changeMax)
        fallback  = (val, maxBound)

-- | Random input selection: core algorithm
--
-- Select random inputs until we reach a value in the given bounds.
-- Returns the selected outputs.
randomInRange :: forall h a m. (Hash h a, LiftQuickCheck m)
              => (Value, Value) -> InputPolicyT h a m (Utxo h a)
randomInRange (lo, hi) =
    go 0 utxoEmpty utxoEmpty
  where
    -- Returns the UTxO that we used to cover the range if successful
    go :: Value    -- ^ Accumulated value
       -> Utxo h a -- ^ Discarded UTxO (not used, but not useable either)
       -> Utxo h a -- ^ Used UTxO
       -> InputPolicyT h a m (Utxo h a)
    go acc discarded used =
      if lo <= acc && acc <= hi
        then do
          ipsUtxo %= utxoUnion discarded -- make discarded available again
          return used
        else do
          io@(_, out) <- useRandomOutput
          let acc' = acc + outVal out
          if acc' <= hi -- should we pick this value?
            then go acc' discarded (utxoInsert io used)
            else go acc  (utxoInsert io discarded) used

useRandomOutput :: LiftQuickCheck m
                => InputPolicyT h a m (Input h a, Output a)
useRandomOutput = do
    utxo <- utxoToMap <$> use ipsUtxo
    mIO  <- liftQuickCheck $ randomElement utxo
    case mIO of
      Nothing          -> throwError InputSelectionFailure
      Just (io, utxo') -> ipsUtxo .= utxoFromMap utxo' >> return io

{-------------------------------------------------------------------------------
  Auxiliary
-------------------------------------------------------------------------------}

-- | Pick a random element from a map
--
-- Returns 'Nothing' if the map is empty
randomElement :: forall k a. Map k a -> Gen (Maybe ((k, a), Map k a))
randomElement m
  | Map.null m = return Nothing
  | otherwise  = (Just . withIx) <$> choose (0, Map.size m - 1)
  where
    withIx :: Int -> ((k, a), Map k a)
    withIx ix = (Map.elemAt ix m, Map.deleteAt ix m)
