{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE EmptyDataDecls #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeFamilies #-}

-- | Interface for working with Git repositories.
module Git
       ( RepositoryFacts(..)
       , Repository(..)
       , RepositoryFactory(..)
       , RepositoryOptions(..)
       , withBackendDo
       , withRepository
       , withRepository'
       , MonadGit

       , IsOid(..)
       , copyOid
       , Object(..)
       , ObjRef(..)
       , objectOid

       , Blob(..)
       , BlobOid
       , BlobContents(..)
       , BlobKind(..)
       , ByteSource
       , BlobRef
       , blobEntry
       , blobRefOid
       , resolveBlobRef

       , TreeT
       , TreeEntry(..)
       , TreeOid
       , TreeRef
       , createTree
       , withNewTree
       , mutateTree
       , mutateTreeRef
       , currentTree
       , currentTreeRef
       , withTree
       , withTreeRef
       , getBuilder
       , putBuilder
       , dropEntry
       , getEntry
       , putBlob
       , putBlob'
       , putCommit
       , putEntry
       , putTree
       , resolveTreeRef
       , treeEntry
       , getTreeEntryOid
       , treeRef
       , treeRefOid
       , ModifyTreeResult(..)
       , fromModifyTreeResult
       , toModifyTreeResult

       , Commit(..)
       , CommitOid
       , CommitName(..)
       , CommitRef
       , Signature(..)
       , commitEntry
       , commitNameToRef
       , commitRef
       , commitRefOid
       , commitRefTarget
       , copyCommitName
       , copyCommitOid
       , nameOfCommit
       , renderCommitName
       , resolveCommitRef

       , Tag(..)
       , TagOid
       , TagRef
       , tagRefOid

       , RefTarget(..)
       , Reference(..)
       , referenceToRef

       , GitException(..)
       , ModificationKind(..)
       , MergeStatus(..)
       , MergeResult(..)
       , mergeStatus
       , copyConflict
       ) where

import           Control.Applicative
import qualified Control.Exception.Lifted as Exc
import           Control.Failure
import           Control.Monad
import           Control.Monad.Fix
import           Control.Monad.IO.Class
import           Control.Monad.Trans.Class
import           Control.Monad.Trans.State
import           Data.ByteString (ByteString)
import           Data.Conduit
import           Data.Default
import           Data.Map (Map)
import           Data.Maybe
import           Data.Tagged
import           Data.Text (Text)
import qualified Data.Text as T
import           Data.Time
import           Data.Typeable
import           Filesystem.Path.CurrentOS
import           Prelude hiding (FilePath)
import           System.Mem (performGC)

{- $repositories -}
data RepositoryFacts = RepositoryFacts
    { hasSymbolicReferences :: !Bool
    } deriving Show

type MonadGit m = (Failure Git.GitException m, Applicative m,
                   MonadIO m, MonadBaseControl IO m)

class (Eq o, Ord o, Show o) => IsOid o where
    renderOid :: o -> Text
    renderOid = renderObjOid . Tagged
    renderObjOid :: Tagged a o -> Text
    renderObjOid = renderOid . untag

-- | 'Repository' is the central point of contact between user code and
-- Git data objects.  Every object must belong to some repository.
class (Applicative m, Monad m, Failure GitException m, IsOid (Oid m))
      => Repository m where
    type Oid m :: *
    data Tree m :: *
    type TreeBuilder m :: *

    data Options m

    facts :: m RepositoryFacts

    parseOid :: Text -> m (Oid m)
    parseObjOid :: forall o. Text -> m (Tagged o (Oid m))
    parseObjOid sha = Tagged <$> parseOid sha

    -- References
    createReference  :: Text -> RefTarget m (Commit m)
                     -> m (Reference m (Commit m))
    createReference_ :: Text -> RefTarget m (Commit m) -> m ()
    createReference_ = (void .) . createReference
    lookupReference  :: Text -> m (Maybe (Reference m (Commit m)))
    updateReference  :: Text -> RefTarget m (Commit m)
                     -> m (Reference m (Commit m))
    updateReference_ :: Text -> RefTarget m (Commit m) -> m ()
    updateReference_ = (void .) . updateReference
    deleteReference  :: Text -> m ()

    allReferences :: m [Reference m (Commit m)]
    allReferences = catMaybes <$> (mapM lookupReference =<< allReferenceNames)

    allReferenceNames :: m [Text]
    allReferenceNames = map referenceName <$> allReferences

    resolveReference :: Text -> m (Maybe (CommitRef m))
    resolveReference name = lookupReference name >>= referenceToRef (Just name)

    -- Lookup
    lookupCommit :: CommitOid m -> m (Commit m)
    lookupTree   :: TreeOid m -> m (Tree m)
    lookupBlob   :: BlobOid m -> m (Blob m)
    lookupTag    :: TagOid m -> m (Tag m)

    lookupObject :: Text -> m (Object m)
    existsObject :: Oid m -> m Bool

    traverseObjects :: forall a.
                       (Object m -> m a) -> Maybe (CommitName m) -> m [a]
    traverseObjects_ :: (Object m -> m ()) -> Maybe (CommitName m) -> m ()
    traverseObjects_ = (void .) . traverseObjects

    pushCommit :: (MonadTrans t, MonadGit m, MonadGit (t m),
                   Repository m, Repository (t m))
               => CommitName m -> Maybe Text -> Text
               -> t m (CommitRef (t m))

    traverseCommits :: forall a.
                       (CommitRef m -> m a) -> CommitName m -> m [a]
    traverseCommits_ :: (CommitRef m -> m ()) -> CommitName m -> m ()
    traverseCommits_ = (void .) . traverseCommits

    missingObjects :: Maybe (CommitName m) -- ^ A commit we may already have
                   -> CommitName m         -- ^ The commit we need
                   -> m [Object m]         -- ^ All the objects in between

    -- Object creation
    newTreeBuilder :: Maybe (Tree m) -> m (TreeBuilder m)
    writeTree :: TreeBuilder m -> TreeT m (TreeRef m)

    unsafeUpdateTreeBuilder
        :: TreeBuilder m
        -> FilePath    -- path within the tree
        -> Bool        -- create subtree's leading up to path?
        -> (Maybe (TreeEntry m) -> ModifyTreeResult m)
        -> m (TreeBuilder m, Maybe (TreeEntry m))

    treeOid :: Tree m -> TreeOid m
    getTreeEntry :: Tree m -> FilePath -> m (Maybe (TreeEntry m))
    traverseEntries :: (FilePath -> TreeEntry m -> m a) -> Tree m -> m [a]
    traverseEntries_ :: (FilePath -> TreeEntry m -> m a) -> Tree m -> m ()
    traverseEntries_ = (void .) . traverseEntries

    hashContents :: BlobContents m -> m (BlobOid m)
    createBlob   :: BlobContents m -> m (BlobOid m)
    createCommit :: [CommitRef m] -> TreeRef m
                 -> Signature -> Signature -> Text -> Maybe Text -> m (Commit m)
    createTag :: CommitOid m -> Signature -> Text -> Text -> m (Tag m)

    deleteRepository :: m ()

    -- Pack files
    buildPackFile :: FilePath -> [Either (CommitOid m) (TreeOid m)]
                  -> m FilePath
    buildPackFile _ _ =
        failure (BackendError "Backend does not support building pack files")

    buildPackIndex :: FilePath -> ByteString -> m (Text, FilePath, FilePath)
    buildPackIndex _ _ =
        failure (BackendError "Backend does not support building pack indexes")

    writePackFile :: FilePath -> m ()
    writePackFile _ =
        failure (BackendError "Backend does not support writing  pack files")

    -- Git remotes
    remoteFetch :: Text {- URI -} -> Text {- fetch spec -} -> m ()

{- $exceptions -}
-- | There is a separate 'GitException' for each possible failure when
--   interacting with the Git repository.
data GitException = BackendError Text
                  | GitError Text
                  | RepositoryNotExist
                  | RepositoryInvalid
                  | RepositoryCannotAccess Text
                  | BlobCreateFailed
                  | BlobEmptyCreateFailed
                  | BlobEncodingUnknown Text
                  | BlobLookupFailed
                  | PushNotFastForward Text
                  | TranslationException Text
                  | TreeCreateFailed Text
                  | TreeBuilderCreateFailed
                  | TreeBuilderInsertFailed Text
                  | TreeBuilderRemoveFailed Text
                  | TreeBuilderWriteFailed Text
                  | TreeLookupFailed
                  | TreeCannotTraverseBlob
                  | TreeCannotTraverseCommit
                  | TreeEntryLookupFailed FilePath
                  | TreeUpdateFailed
                  | TreeWalkFailed
                  | CommitCreateFailed
                  | CommitLookupFailed Text
                  | ReferenceCreateFailed
                  | ReferenceDeleteFailed Text
                  | RefCannotCreateFromPartialOid
                  | ReferenceListingFailed
                  | ReferenceLookupFailed Text
                  | ObjectLookupFailed Text Int
                  | ObjectRefRequiresFullOid
                  | OidCopyFailed
                  | OidParseFailed Text
                  | QuotaHardLimitExceeded Int Int
                  deriving (Eq, Show, Typeable)

-- jww (2013-02-11): Create a BackendException data constructor of forall
-- e. Exception e => BackendException e, so that each can throw a derived
-- exception.
instance Exc.Exception GitException

{- $oids -}
type BlobOid m   = Tagged (Blob m) (Oid m)
type TreeOid m   = Tagged (Tree m) (Oid m)
type CommitOid m = Tagged (Commit m) (Oid m)
type TagOid m    = Tagged (Tag m) (Oid m)

{- $references -}
data RefTarget m a = RefObj !(ObjRef m a) | RefSymbolic !Text

data Reference m a = Reference
    { referenceName   :: !Text
    , referenceTarget :: !(RefTarget m a) }

data CommitName m = CommitObjectId !(CommitOid m)
                  | CommitRefName !Text
                  | CommitReference !(Reference m (Commit m))

instance Repository m => Show (CommitName m) where
    show (CommitObjectId coid) = T.unpack (renderObjOid coid)
    show (CommitRefName name)  = show name
    show (CommitReference ref) = show (referenceName ref)

nameOfCommit :: Commit m -> CommitName m
nameOfCommit = CommitObjectId . commitOid

commitNameToRef :: Repository m => CommitName m -> m (Maybe (CommitRef m))
commitNameToRef (CommitObjectId coid) = return (Just (ByOid coid))
commitNameToRef (CommitRefName name)  = resolveReference name
commitNameToRef (CommitReference ref) = referenceToRef Nothing (Just ref)

renderCommitName :: Repository m => CommitName m -> Text
renderCommitName (CommitObjectId coid) = renderObjOid coid
renderCommitName (CommitRefName name)  = name
renderCommitName (CommitReference ref) = referenceName ref

copyOid :: (Repository m, MonadGit m, Repository n, MonadGit n)
        => Oid m -> n (Oid n)
copyOid = parseOid . renderOid

copyCommitOid :: (Repository m, MonadGit m, Repository n, MonadGit n)
              => CommitOid m -> n (CommitOid n)
copyCommitOid coid = do
    ncoid <- parseOid (renderObjOid coid)
    return (Tagged ncoid)

copyCommitName :: (Repository m, MonadGit m, Repository n, MonadGit n)
               => CommitName m -> n (Maybe (CommitName n))
copyCommitName (CommitObjectId coid) =
    Just . CommitObjectId . Tagged <$> parseOid (renderObjOid coid)
copyCommitName (CommitRefName name) = return (Just (CommitRefName name))
copyCommitName (CommitReference ref) =
    fmap CommitReference <$> lookupReference (referenceName ref)

{- $objects -}
data ObjRef m a = ByOid !(Tagged a (Oid m)) | Known !a

type BlobRef m   = ObjRef m (Blob m)
type TreeRef m   = ObjRef m (Tree m)
type CommitRef m = ObjRef m (Commit m)
type TagRef m    = ObjRef m (Tag m)

data Object m = BlobObj      !(BlobRef m)
              | TreeObj      !(TreeRef m)
              | CommitObj    !(CommitRef m)
              | TagObj       !(TagRef m)

objectOid :: Repository m => Object m -> m (Oid m)
objectOid (BlobObj ref)   = return . untag $ blobRefOid ref
objectOid (TreeObj ref)   = return . untag $ treeRefOid ref
objectOid (CommitObj ref) = return . untag $ commitRefOid ref
objectOid (TagObj ref)    = return . untag $ tagRefOid ref

{- $blobs -}
data Blob m = Blob { blobOid      :: !(BlobOid m)
                   , blobContents :: !(BlobContents m) }

blobRefOid :: Repository m => BlobRef m -> BlobOid m
blobRefOid (ByOid oid) = oid
blobRefOid (Known (Blob {..})) = blobOid

resolveBlobRef :: Repository m => BlobRef m -> m (Blob m)
resolveBlobRef (ByOid oid) = lookupBlob oid
resolveBlobRef (Known obj) = return obj

type ByteSource m = Producer m ByteString

data BlobContents m = BlobString !ByteString
                    | BlobStream !(ByteSource m)
                    | BlobSizedStream !(ByteSource m) !Int

data BlobKind = PlainBlob | ExecutableBlob | SymlinkBlob | UnknownBlob
              deriving (Show, Eq, Enum)

instance Eq (BlobContents m) where
  BlobString str1 == BlobString str2 = str1 == str2
  _ == _ = False

{- $trees -}
newtype TreeT m a = TreeT { runTreeT :: StateT (TreeBuilder m) m a }

instance Functor m => Functor (TreeT m) where
    fmap f (TreeT t) = TreeT (fmap f t)

instance Monad m => Monad (TreeT m) where
    return x = TreeT (return x)
    TreeT x >>= f = TreeT (x >>= runTreeT . f)

instance (Functor m, Monad m) => Applicative (TreeT m) where
    pure = return
    (<*>) = ap

instance (Functor m, MonadPlus m) => Alternative (TreeT m) where
    empty = mzero
    (<|>) = mplus

instance (MonadPlus m) => MonadPlus (TreeT m) where
    mzero       = TreeT $ mzero
    m `mplus` n = TreeT $ runTreeT m `mplus` runTreeT n

instance (MonadFix m) => MonadFix (TreeT m) where
    mfix f = TreeT $ mfix $ \ ~a -> runTreeT (f a)

instance MonadTrans TreeT where
    lift m = TreeT $ lift m

instance (MonadIO m) => MonadIO (TreeT m) where
    liftIO = lift . liftIO

getBuilder :: Monad m => TreeT m (TreeBuilder m)
getBuilder = TreeT get

putBuilder :: Monad m => TreeBuilder m -> TreeT m ()
putBuilder = TreeT . put

getEntry :: Repository m => FilePath -> TreeT m (Maybe (TreeEntry m))
getEntry path = do
    tb <- getBuilder
    snd <$> lift (unsafeUpdateTreeBuilder tb path False
                  (toModifyTreeResult TreeEntryPersistent))

putEntry :: Repository m => FilePath -> TreeEntry m -> TreeT m ()
putEntry path ent = do
    tb  <- getBuilder
    tb' <- fst <$> lift (unsafeUpdateTreeBuilder tb path True
                         (const (TreeEntryMutated ent)))
    putBuilder tb'

dropEntry :: Repository m => FilePath -> TreeT m ()
dropEntry path = do
    tb  <- getBuilder
    tb' <- fst <$> lift (unsafeUpdateTreeBuilder tb path False
                         (const TreeEntryDeleted))
    putBuilder tb'

putBlob' :: Repository m => FilePath -> BlobOid m -> BlobKind -> TreeT m ()
putBlob' path b kind = putEntry path (BlobEntry b kind)

putBlob :: Repository m => FilePath -> BlobOid m -> TreeT m ()
putBlob path b = putBlob' path b PlainBlob

putTree :: Repository m => FilePath -> TreeOid m -> TreeT m ()
putTree path t = putEntry path (TreeEntry t)

putCommit :: Repository m => FilePath -> CommitOid m -> TreeT m ()
putCommit path c = putEntry path (CommitEntry c)

doWithTree :: Repository m => Maybe (Tree m) -> TreeT m a -> m (a, TreeRef m)
doWithTree mtr act =
    fst <$> (runStateT (runTreeT go) =<< newTreeBuilder mtr)
  where
    go = do
        a  <- act
        tb <- getBuilder
        tr <- writeTree tb
        return (a,tr)

withTree :: Repository m => Tree m -> TreeT m a -> m (a, TreeRef m)
withTree tr = doWithTree (Just tr)

withTreeRef :: Repository m => TreeRef m -> TreeT m a -> m (a, TreeRef m)
withTreeRef ref action = do
    tree <- resolveTreeRef ref
    doWithTree (Just tree) action

mutateTree :: Repository m => Tree m -> TreeT m a -> m (TreeRef m)
mutateTree tr action = snd <$> withTree tr action

mutateTreeRef :: Repository m => TreeRef m -> TreeT m a -> m (TreeRef m)
mutateTreeRef tr action = snd <$> withTreeRef tr action

currentTreeRef :: Repository m => TreeT m (TreeRef m)
currentTreeRef = writeTree =<< getBuilder

currentTree :: Repository m => TreeT m (Tree m)
currentTree = lift . resolveTreeRef =<< currentTreeRef

withNewTree :: Repository m => TreeT m a -> m (a, TreeRef m)
withNewTree = doWithTree Nothing

createTree :: Repository m => TreeT m a -> m (TreeRef m)
createTree action = snd <$> withNewTree action

data TreeEntry m = BlobEntry   { blobEntryOid   :: !(BlobOid m)
                               , blobEntryKind  :: !BlobKind }
                 | TreeEntry   { treeEntryOid   :: !(TreeOid m) }
                 | CommitEntry { commitEntryOid :: !(CommitOid m) }

getTreeEntryOid :: Repository m => TreeEntry m -> Oid m
getTreeEntryOid (BlobEntry boid _) = untag boid
getTreeEntryOid (TreeEntry toid)   = untag toid
getTreeEntryOid (CommitEntry coid) = untag coid

blobEntry :: Repository m => BlobOid m -> BlobKind -> TreeEntry m
blobEntry = BlobEntry

treeEntry :: Repository m => Tree m -> TreeEntry m
treeEntry = TreeEntry . treeOid

commitEntry :: Repository m => Commit m -> TreeEntry m
commitEntry = CommitEntry . commitOid

data ModifyTreeResult m = TreeEntryNotFound
                        | TreeEntryDeleted
                        | TreeEntryPersistent (TreeEntry m)
                        | TreeEntryMutated (TreeEntry m)

fromModifyTreeResult :: ModifyTreeResult m -> Maybe (TreeEntry m)
fromModifyTreeResult TreeEntryNotFound       = Nothing
fromModifyTreeResult TreeEntryDeleted        = Nothing
fromModifyTreeResult (TreeEntryPersistent x) = Just x
fromModifyTreeResult (TreeEntryMutated x)    = Just x

toModifyTreeResult :: (TreeEntry m -> ModifyTreeResult m)
                   -> Maybe (TreeEntry m)
                   -> ModifyTreeResult m
toModifyTreeResult _ Nothing  = TreeEntryNotFound
toModifyTreeResult f (Just x) = f x

-- | A 'Tree' is anything that is "treeish".
treeRef :: Tree m -> TreeRef m
treeRef = Known

treeRefOid :: Repository m => TreeRef m -> TreeOid m
treeRefOid (ByOid x) = x
treeRefOid (Known x) = treeOid x

resolveTreeRef :: Repository m => TreeRef m -> m (Tree m)
resolveTreeRef (ByOid oid) = lookupTree oid
resolveTreeRef (Known obj) = return obj

{- $commits -}
data Signature = Signature
    { signatureName  :: !Text
    , signatureEmail :: !Text
    , signatureWhen  :: !ZonedTime
    } deriving Show

instance Default Signature where
    def = Signature
        { signatureName  = T.empty
        , signatureEmail = T.empty
        , signatureWhen  = ZonedTime
            { zonedTimeToLocalTime = LocalTime
                { localDay = ModifiedJulianDay 0
                , localTimeOfDay = TimeOfDay 0 0 0
                }
            , zonedTimeZone = utc
            }
        }

data Commit m = Commit
    { commitOid       :: !(CommitOid m)
    , commitParents   :: ![CommitRef m]
    , commitTree      :: !(TreeRef m)
    , commitAuthor    :: !Signature
    , commitCommitter :: !Signature
    , commitLog       :: !Text
    , commitEncoding  :: !Text
    }

commitRef :: Commit m -> CommitRef m
commitRef = Known

commitRefTarget :: Commit c -> RefTarget m (Commit c)
commitRefTarget = RefObj . Known

commitRefOid :: Repository m => CommitRef m -> CommitOid m
commitRefOid (ByOid x) = x
commitRefOid (Known x) = commitOid x

resolveCommitRef :: Repository m => CommitRef m -> m (Commit m)
resolveCommitRef (ByOid oid) = lookupCommit oid
resolveCommitRef (Known obj) = return obj

referenceToRef :: Repository m
               => Maybe Text -> Maybe (Reference m (Commit m))
               -> m (Maybe (CommitRef m))
referenceToRef mname mref =
    case mref of
        Nothing -> return Nothing
        Just (Reference { referenceTarget = RefObj x }) ->
            return (Just x)
        Just ref@(Reference { referenceTarget = RefSymbolic name' }) ->
            if fromMaybe name' mname /= name'
            then resolveReference name'
            else failure (ReferenceLookupFailed (referenceName ref))

{- $tags -}

data Tag m = Tag
    { tagOid    :: !(TagOid m)
    , tagCommit :: !(CommitRef m)
    }

tagRefOid :: Repository m => TagRef m -> TagOid m
tagRefOid (ByOid x) = x
tagRefOid (Known x) = tagOid x

{- $merges -}

data ModificationKind = Unchanged | Modified | Added | Deleted | TypeChanged
                      deriving (Eq, Ord, Enum, Show, Read)

data MergeStatus
    = NoConflict
    | BothModified
    | LeftModifiedRightDeleted
    | LeftDeletedRightModified
    | BothAdded
    | LeftModifiedRightTypeChanged
    | LeftTypeChangedRightModified
    | LeftDeletedRightTypeChanged
    | LeftTypeChangedRightDeleted
    | BothTypeChanged
    deriving (Eq, Ord, Enum, Show, Read)

mergeStatus :: ModificationKind -> ModificationKind -> MergeStatus
mergeStatus Unchanged Unchanged     = NoConflict
mergeStatus Unchanged Modified      = NoConflict
mergeStatus Unchanged Added         = undefined
mergeStatus Unchanged Deleted       = NoConflict
mergeStatus Unchanged TypeChanged   = NoConflict

mergeStatus Modified Unchanged      = NoConflict
mergeStatus Modified Modified       = BothModified
mergeStatus Modified Added          = undefined
mergeStatus Modified Deleted        = LeftModifiedRightDeleted
mergeStatus Modified TypeChanged    = LeftModifiedRightTypeChanged

mergeStatus Added Unchanged         = undefined
mergeStatus Added Modified          = undefined
mergeStatus Added Added             = BothAdded
mergeStatus Added Deleted           = undefined
mergeStatus Added TypeChanged       = undefined

mergeStatus Deleted Unchanged       = NoConflict
mergeStatus Deleted Modified        = LeftDeletedRightModified
mergeStatus Deleted Added           = undefined
mergeStatus Deleted Deleted         = NoConflict
mergeStatus Deleted TypeChanged     = LeftDeletedRightTypeChanged

mergeStatus TypeChanged Unchanged   = NoConflict
mergeStatus TypeChanged Modified    = LeftTypeChangedRightModified
mergeStatus TypeChanged Added       = undefined
mergeStatus TypeChanged Deleted     = LeftTypeChangedRightDeleted
mergeStatus TypeChanged TypeChanged = BothTypeChanged

data MergeResult m
    = MergeSuccess
        { mergeCommit    :: CommitOid m
        }
    | MergeConflicted
        { mergeCommit    :: CommitOid m
        , mergeHeadLeft  :: CommitOid m
        , mergeHeadRight :: CommitOid m
        , mergeConflicts :: Map FilePath (ModificationKind, ModificationKind)
        }

instance Repository m => Show (MergeResult m) where
    show (MergeSuccess mc) = "MergeSuccess (" ++ show mc ++ ")"
    show (MergeConflicted mc hl hr cs) =
        "MergeResult"
     ++ "\n    { mergeCommit    = " ++ show mc
     ++ "\n    , mergeHeadLeft  = " ++ show hl
     ++ "\n    , mergeHeadRight = " ++ show hr
     ++ "\n    , mergeConflicts = " ++ show cs
     ++ "\n    }"

copyConflict :: (Repository m, MonadGit m, Repository n, MonadGit n)
             => MergeResult m -> n (MergeResult n)
copyConflict (MergeSuccess mc) =
    MergeSuccess <$> (Tagged <$> parseOid (renderObjOid mc))
copyConflict (MergeConflicted hl hr mc cs) =
    MergeConflicted <$> (Tagged <$> parseOid (renderObjOid hl))
                    <*> (Tagged <$> parseOid (renderObjOid hr))
                    <*> (Tagged <$> parseOid (renderObjOid mc))
                    <*> pure cs

{- $miscellaneous -}

data RepositoryOptions = RepositoryOptions
    { repoPath       :: !FilePath
    , repoIsBare     :: !Bool
    , repoAutoCreate :: !Bool
    }

instance Default RepositoryOptions where
    def = RepositoryOptions "" True True

data RepositoryFactory t m c = RepositoryFactory
    { openRepository  :: RepositoryOptions -> m c
    , runRepository   :: forall a. c -> t m a -> m a
    , closeRepository :: c -> m ()
    , getRepository   :: t m c
    , defaultOptions  :: !RepositoryOptions
    , startupBackend  :: m ()
    , shutdownBackend :: m ()
    }

withBackendDo :: (MonadIO m, MonadBaseControl IO m)
              => RepositoryFactory t m a -> m b -> m b
withBackendDo fact f = do
    startupBackend fact
    Exc.finally f (liftIO performGC >> shutdownBackend fact)

withRepository' :: (Repository (t m), MonadTrans t,
                    MonadBaseControl IO m, MonadIO m)
                => RepositoryFactory t m c
                -> RepositoryOptions
                -> t m a
                -> m a
withRepository' factory opts action =
    Exc.bracket
        (openRepository factory opts)
        (closeRepository factory)
        (flip (runRepository factory) action)

withRepository :: (Repository (t m), MonadTrans t,
                   MonadBaseControl IO m, MonadIO m)
               => RepositoryFactory t m c
               -> FilePath
               -> t m a
               -> m a
withRepository factory path =
    withRepository' factory
        (defaultOptions factory) { repoPath = path }

-- Git.hs
