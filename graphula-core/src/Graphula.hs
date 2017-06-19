{-|
  Graphula is a compact interface for generating data and linking its
  dependencies. You can use this interface to generate fixtures for automated
  testing.

  The interface is extensible and supports pluggable front-ends.

  @
  runGraphula graphIdentity $ do
    -- Compose dependencies at the value level
    Identity vet <- node @Veterinarian
    Identity owner <- nodeWith @Owner $ only vet
    -- TypeApplications is not necessary, but recommended for clarity.
    Identity dog <- nodeEditWith @Dog (owner, vet) $ \d ->
      d { name = "fido" }
  @
-}
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DefaultSignatures #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveFoldable #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveTraversable #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE KindSignatures #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TupleSections #-}

module Graphula
  ( -- * Graph Declaration
    node
  , nodeEdit
  , nodeWith
  , nodeEditWith
  -- * Declaring Dependencies
  , HasDependencies(..)
  -- ** Singular Dependencies
  , Only(..)
  , only
  -- * The Graph Monad
  , Graph
  , runGraphula
  , runGraphulaLogged
  , runGraphulaLoggedWithFile
  , runGraphulaReplay
  -- * Graph Implementation
  , Frontend(..)
  , Backend(..)
  -- * Extras
  , NoConstraint
  -- * Exceptions
  , GenerationFailure(..)
  ) where

import Prelude hiding (readFile, lines)
import Test.QuickCheck (Arbitrary(..), generate)
import Test.HUnit.Lang (HUnitFailure(..), FailureReason(..), formatFailureReason)
import Control.Monad.Catch (MonadCatch(..), MonadThrow(..))
import Control.Monad.Trans.Free (FreeT, iterT, liftF, transFreeT)
import Control.Monad.IO.Class (MonadIO(..))
import Control.Exception (Exception, bracket)
import Data.Semigroup ((<>))
import Data.Aeson (ToJSON, FromJSON, encode, eitherDecode)
import Data.ByteString (ByteString, hPutStr, readFile)
import Data.ByteString.Char8 (lines)
import Data.ByteString.Lazy (toStrict, fromStrict)
import Data.Functor.Sum (Sum(..))
import Data.IORef (IORef, newIORef, readIORef, writeIORef, modifyIORef')
import Data.Proxy (Proxy(..))
import Data.Typeable (Typeable, TypeRep, typeRep)
import Generics.Eot (fromEot, toEot, Eot, HasEot)
import GHC.Exts (Constraint)
import GHC.Generics (Generic)
import System.IO (hClose, openFile, IOMode(..), Handle)
import System.IO.Temp (openTempFile)
import System.Directory (getTemporaryDirectory)

import Graphula.Internal

-- | 'Graph' is a type alias for graphula's underlying monad. This type carries
-- constraints via 'ConstraintKinds', which enable pluggable frontends and backends.
--
-- * __generate__: A constraint for pluggable node generation. 'runGraphula'
--   utilizes 'Arbitrary', 'runGraphulaReplay' utilizes 'FromJSON'.
-- * __log__: A constraint provided to log details of the graph to some form of
--   persistence. This is used by 'runGraphulaLogged' to store graph nodes as
--   JSON 'Value's.
-- * __nodeConstraint__: A constraint applied to nodes. This is utilized during
--   insertion and can be leveraged by frontends with typeclass interfaces
--   to insertion.
-- * __entity__: A wrapper type used to return relevant information about a given
--   node. `graphula-persistent` returns all nodes in the 'Entity' type.
type Graph generate log nodeConstraint entity
  = FreeT (Sum (Backend generate log) (Frontend nodeConstraint entity))

-- | Interpret a 'Graph' with a given 'Frontend' interpreter, utilizing
-- 'Arbitrary' for node generation.
runGraphula
  :: (MonadIO m, MonadCatch m)
  => (Frontend nodeConstraint entity (m a) -> m a)
  -> Graph Arbitrary NoConstraint nodeConstraint entity m a
  -> m a
runGraphula frontend f =
  flip iterT f $ \case
    InR r -> frontend r
    InL l -> backendArbitrary l

-- | An extension of 'runGraphula' that logs all json 'Value's to a temporary
-- file on 'Exception' and re-throws the 'Exception'.
runGraphulaLogged
  :: (MonadIO m, MonadCatch m)
  => (Frontend nodeConstraint entity (m a) -> m a)
  -> Graph Arbitrary ToJSON nodeConstraint entity m a
  -> m a
runGraphulaLogged =
  runGraphulaLoggedUsing logFailTemp

-- | A variant of 'runGraphulaLogged' that accepts a file path to logged to
-- instead of utilizing a temp file.
runGraphulaLoggedWithFile
  :: (MonadIO m, MonadCatch m)
  => FilePath
  -> (Frontend nodeConstraint entity (m a) -> m a)
  -> Graph Arbitrary ToJSON nodeConstraint entity m a
  -> m a
runGraphulaLoggedWithFile logPath =
  runGraphulaLoggedUsing (logFailFile logPath)

runGraphulaLoggedUsing
  :: (MonadIO m, MonadCatch m)
  => (IORef ByteString -> HUnitFailure -> m a)
  -> (Frontend nodeConstraint entity (m a) -> m a)
  -> Graph Arbitrary ToJSON nodeConstraint entity m a
  -> m a
runGraphulaLoggedUsing logFail frontend f = do
  graphLog <- liftIO $ newIORef ""
  catch (go graphLog) (logFail graphLog)
  where
    go graphLog =
      flip iterT f $ \case
        InR r -> frontend r
        InL l -> backendArbitraryLogged graphLog l

-- | Interpret a 'Graph' with a given 'Frontend' interpreter, utilizing a JSON
-- file for node generation via 'FromJSON'.
runGraphulaReplay
  :: (MonadIO m, MonadCatch m)
  => FilePath
  -> (Frontend nodeConstraint entity (m a) -> m a)
  -> Graph FromJSON NoConstraint nodeConstraint entity m a -> m a
runGraphulaReplay replayFile frontend f = do
  replayLog <- liftIO $ newIORef =<< (lines <$> readFile replayFile)
  catch (go replayLog) (rethrowHUnitReplay replayFile)
  where
    go replayLog =
      flip iterT f $ \case
        InR r -> frontend r
        InL l -> backendReplay replayLog l



backendArbitrary :: (MonadThrow m, MonadIO m) => Backend Arbitrary NoConstraint (m b) -> m b
backendArbitrary = \case
  GenerateNode next -> do
    a <- liftIO . generate $ arbitrary
    next a
  LogNode _ next -> next ()
  Throw e next ->
    next =<< throwM e

backendArbitraryLogged :: (MonadThrow m, MonadIO m) => IORef ByteString -> Backend Arbitrary ToJSON (m b) -> m b
backendArbitraryLogged graphLog = \case
  GenerateNode next -> do
    a <- liftIO . generate $ arbitrary
    next a
  LogNode a next -> do
    liftIO $ modifyIORef' graphLog (<> (toStrict (encode a) <> "\n"))
    next ()
  Throw e next ->
    next =<< throwM e

backendReplay :: (MonadThrow m, MonadIO m) => IORef [ByteString] -> Backend FromJSON NoConstraint (m b) -> m b
backendReplay replayRef = \case
  GenerateNode next -> do
    mJsonNode <- popReplay replayRef
    case mJsonNode of
      Nothing -> throwM $ userError "Not enough replay data to fullfill graph."
      Just jsonNode ->
        case eitherDecode $ fromStrict jsonNode of
          Left err -> throwM $ userError err
          Right a -> next a
  LogNode _ next -> next ()
  Throw e next ->
    next =<< throwM e

popReplay :: MonadIO m => IORef [ByteString] -> m (Maybe ByteString)
popReplay ref = liftIO $ do
  nodes <- readIORef ref
  case nodes of
    [] -> pure Nothing
    n:ns -> do
      writeIORef ref ns
      pure $ Just n

logFailUsing :: (MonadIO m, MonadThrow m) => IO (FilePath, Handle) -> IORef ByteString -> HUnitFailure -> m a
logFailUsing f graphLog hunitfailure =
  flip rethrowHUnitLogged hunitfailure =<< logGraphToHandle graphLog f

logFailFile :: (MonadIO m, MonadThrow m) => FilePath -> IORef ByteString -> HUnitFailure -> m a
logFailFile path =
  logFailUsing ((path, ) <$> openFile path WriteMode)

logFailTemp :: (MonadIO m, MonadThrow m) => IORef ByteString -> HUnitFailure -> m a
logFailTemp =
  logFailUsing (flip openTempFile "fail-.graphula" =<< getTemporaryDirectory)

logGraphToHandle :: (MonadIO m) => IORef ByteString -> IO (FilePath, Handle) -> m FilePath
logGraphToHandle graphLog openHandle =
  liftIO $ bracket
    openHandle
    (hClose . snd)
    (\(path, handle) -> readIORef graphLog >>= hPutStr handle >> pure path )


rethrowHUnitWith :: MonadThrow m => String -> HUnitFailure -> m a
rethrowHUnitWith message (HUnitFailure l r)  =
  throwM . HUnitFailure l . Reason $ message ++ "\n\n" ++ formatFailureReason r

rethrowHUnitLogged :: MonadThrow m => FilePath -> HUnitFailure -> m a
rethrowHUnitLogged path  =
  rethrowHUnitWith ("Graph dumped in temp file: " ++ path)

rethrowHUnitReplay :: (MonadIO m, MonadThrow m) => FilePath -> HUnitFailure -> m a
rethrowHUnitReplay filePath =
  rethrowHUnitWith ("Using graph file: " ++ filePath)


liftLeft :: (Monad m, Functor f, Functor g) => FreeT f m a -> FreeT (Sum f g) m a
liftLeft = transFreeT InL

liftRight :: (Monad m, Functor f, Functor g) => FreeT g m a -> FreeT (Sum f g) m a
liftRight = transFreeT InR


data Frontend (nodeConstraint :: * -> Constraint) entity next where
  Insert :: nodeConstraint a => a -> (Maybe (entity a) -> next) -> Frontend nodeConstraint entity next

deriving instance Functor (Frontend nodeConstraint entity)

insert :: (Monad m, nodeConstraint a) => a -> Graph generate log nodeConstraint entity m (Maybe (entity a))
insert n = liftRight $ liftF (Insert n id)


data Backend (generate :: * -> Constraint) (log :: * -> Constraint) next where
  GenerateNode :: (generate a) => (a -> next) -> Backend generate log next
  LogNode :: (log a) => a -> (() -> next) -> Backend generate log next
  Throw :: Exception e => e -> (a -> next) -> Backend generate log next

deriving instance Functor (Backend generate log)

generateNode :: (Monad m, generate a) => Graph generate log nodeConstraint entity m a
generateNode = liftLeft . liftF $ GenerateNode id

logNode :: (Monad m, log a) => a -> Graph generate log nodeConstraint entity m ()
logNode a = liftLeft . liftF $ LogNode a (const ())

throw :: (Monad m, Exception e) => e -> Graph generate log nodeConstraint entity m a
throw e = liftLeft . liftF $ Throw e id

-- | `Graph` accepts constraints for various uses. Frontends do not always
-- utilize these constraints. 'NoConstraint' is a universal class that all
-- types inhabit. It has no behavior and no additional constraints.
class NoConstraint a where

instance NoConstraint a where

class HasDependencies a where
  -- | A data type that contains values to be injected into @a@ via
  -- `dependsOn`. The default generic implementation of `dependsOn` supports
  -- tuples as 'Dependencies'. Data types with a single dependency should use
  -- 'Only' as a 1-tuple.
  --
  -- note: The contents of a tuple must be ordered as they appear in the
  -- definition of @a@.
  type Dependencies a
  type instance Dependencies a = ()

  -- | Assign values from the 'Dependencies' collection to a value.
  -- 'dependsOn' must be an idempotent operation.
  --
  -- Law:
  --
  -- prop> dependsOn . dependsOn = dependsOn
  dependsOn :: a -> Dependencies a -> a
  default dependsOn
    ::
      ( HasEot a
      , HasEot (Dependencies a)
      , GHasDependencies (Proxy a) (Proxy (Dependencies a)) (Eot a) (Eot (Dependencies a))
      )
    => a -> Dependencies a -> a
  dependsOn a dependencies =
    fromEot $
      genericDependsOn
        (Proxy :: Proxy a)
        (Proxy :: Proxy (Dependencies a))
        (toEot a)
        (toEot dependencies)

data GenerationFailure =
  GenerationFailureMaxAttempts TypeRep
  deriving (Show, Typeable, Eq)

instance Exception GenerationFailure

{-|
  Generate and edit a value with data dependencies. This leverages
  'HasDependencies' to insert the specified data in the generated value. All
  dependency data is inserted after editing operations.

  > nodeEdit @Dog (ownerId, veterinarianId) $ \dog ->
  >   dog {name = "fido"}
-}
nodeEditWith
  :: forall a generate log entity nodeConstraint m. (Monad m, nodeConstraint a, Typeable a, generate a, log a, HasDependencies a)
  => Dependencies a -> (a -> a) -> Graph generate log nodeConstraint entity m (entity a)
nodeEditWith dependencies edits =
  tryInsert 10 0 $ do
    x <- edits <$> generateNode
    logNode x
    pure (x `dependsOn` dependencies)

{-|
  Generate a value with data dependencies. This leverages 'HasDependencies' to
  insert the specified data in the generated value.

  > nodeEdit @Dog (ownerId, veterinarianId)
-}
nodeWith
  :: forall a generate log entity nodeConstraint m. (Monad m, nodeConstraint a, Typeable a, generate a, log a, HasDependencies a)
  => Dependencies a -> Graph generate log nodeConstraint entity m (entity a)
nodeWith = flip nodeEditWith id

{-|
  Generate and edit a value that does not have any dependencies.

  > nodeEdit @Dog $ \dog -> dog {name = "fido"}
-}
nodeEdit
  :: forall a generate log entity nodeConstraint m. (Monad m, nodeConstraint a, Typeable a, generate a, log a, HasDependencies a, Dependencies a ~ ())
  => (a -> a) -> Graph generate log nodeConstraint entity m (entity a)
nodeEdit = nodeEditWith ()

-- | Generate a value that does not have any dependencies
--
-- > node @Dog
node
  :: forall a generate log entity nodeConstraint m. (Monad m, nodeConstraint a, Typeable a, generate a, log a, HasDependencies a, Dependencies a ~ ())
  => Graph generate log nodeConstraint entity m (entity a)
node = nodeWith ()

tryInsert
  :: forall a generate log entity nodeConstraint m. (Monad m, nodeConstraint a, Typeable a)
  => Int -> Int -> Graph generate log nodeConstraint entity m a -> Graph generate log nodeConstraint entity m (entity a)
tryInsert maxAttempts currentAttempts source
  | currentAttempts >= maxAttempts =
      throw . GenerationFailureMaxAttempts $ typeRep (Proxy :: Proxy a)
  | otherwise = do
    value <- source
    insert value >>= \case
      Just a -> pure a
      Nothing -> tryInsert maxAttempts (succ currentAttempts) source

-- | For entities that only have singular 'Dependencies'. It uses data instead
-- of newtype to match laziness of builtin tuples.
data Only a = Only { fromOnly :: a }
  deriving (Eq, Show, Ord, Generic, Functor, Foldable, Traversable)

only :: a -> Only a
only = Only
