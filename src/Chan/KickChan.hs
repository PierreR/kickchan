{-# LANGUAGE CPP #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeFamilies #-}

{-# OPTIONS_GHC -Wall #-}
module Chan.KickChan (
  -- * Kick Channels
  KickChan
-- ** Creation
, newKickChan
, kcSize
-- ** Writing
, putKickChan
, invalidateKickChan
-- ** Reading
, KCReader
, newReader
, readNext
, currentLag
-- ** type constraint helpers
, KickChanS
, KickChanV
, KickChanU
, kcUnboxed
, kcStorable
, kcDefault

, KCReaderS
, KCReaderV
, KCReaderU
) where

import Control.Concurrent.MVar

import Data.Bits
import Data.IORef
import Data.IntMap (IntMap)
import qualified Data.IntMap as IM
import Data.Foldable as Fold
import Data.Maybe (maybeToList)

import Data.Vector.Generic.Mutable (MVector)
import qualified Data.Vector.Generic.Mutable as M
import qualified Data.Vector.Mutable as V
import qualified Data.Vector.Storable.Mutable as S
import qualified Data.Vector.Unboxed.Mutable as U
import Control.Monad.Primitive

#if MIN_VERSION_base(4,6,0)
-- nothing to do here...
#else
atomicModifyIORef' :: IORef a -> (a -> (a,b)) -> IO b
atomicModifyIORef' ref f = do
    b <- atomicModifyIORef ref
            (\x -> let (a, b) = f x
                    in (a, a `seq` b))
    b `seq` return b
#endif

-- internal structure to hold the channel head
data Position a = Position
    { nSeq     :: {-# UNPACK #-} !Int
    , waiting  :: IntMap [MVar (Maybe a)]
    }

{- invariants
 - the Int is the next position to be written (buffer head, initialized to 0)
 - the Int changes monotonically
 - the [MVar a] are actions to be run when the next value is ready
-}

emptyPosition :: Position a
emptyPosition = Position 0 IM.empty

-- increment a Position, returning the current sequence number
incrPosition :: Position a -> (Position a,Int)
incrPosition (Position curSeq pMap) = (newP,curSeq)
  where
    newP = Position
           { nSeq = curSeq+1
           , waiting=IM.insertWith (++) curSeq [] pMap
           }

-- increment a position by a given value, which must be enough to wrap the
-- buffer.  Returns a list of all current waiting readers.
invalidatePosition :: Int -> Position a -> (Position a,[MVar (Maybe a)])
invalidatePosition wrapAmount (Position oldP waiting) = (newP,pList)
  where
    newP = Position (oldP+wrapAmount) IM.empty
    pList = Prelude.concat $ IM.elems waiting

-- | commit a value that's been written to the vector.
commit :: Int -> Position a -> (Position a,[MVar (Maybe a)])
commit seqNum (Position nSeq pMap) = (newP,pList)
  where
    pList = Prelude.concat $ maybeToList pending
    (pending,pMap') = IM.updateLookupWithKey (\_ _ -> Nothing) seqNum pMap
    newP = Position nSeq pMap'

data CheckResult = Await | Ok | Invalid

-- check if a value is possibly ready to be read from.  If so, return True,
-- else add ourselves to the waiting map on that value.
readyOrWait :: MVar (Maybe a) -> Int -> Position a -> (Position a, Bool)
readyOrWait await readP p@(Position nextP pMap) =
  case IM.updateLookupWithKey (\_ xs -> Just $ await:xs) readP pMap of
    (Just _waitList,pMap') -> (p { waiting = pMap' }, False)
    (Nothing,_)
      | readP >= nextP ->
          (p{waiting=IM.insertWith (++) readP [await] pMap} ,False)
      | otherwise -> (p,True)

checkWithPosition :: MVar (Maybe a) -> Int -> Int -> Position a -> (Position a, CheckResult)
checkWithPosition await sz readP pos@(Position nextP pMap) =
  case IM.updateLookupWithKey (\_ xs -> Just $ await:xs) readP pMap of
    -- the key was in the map, so it's not committed yet.
    (Just _waitList,pMap') -> (pos { waiting = pMap' }, Await)
    -- key not in map, so the value is either already committed or not yet
    -- claimed by a writer.
    (Nothing,pMap') -> case nextP-readP of
      -- requesting the next position, but it hasn't been claimed by a writer
      -- (or another reader), so insert it into the map.
      0 -> (pos { waiting = IM.insert nextP [await] pMap' }, Await)
      dif -- result should be ok.
          | dif > 0 && dif <= sz -> (pos,Ok)
          -- requests that are too old or too far in the future
          | otherwise -> (pos,Invalid)

-- | A Channel that drops elements from the end when a 'KCReader' lags too far
-- behind the writer.
data KickChan v a = KickChan
    { kcSz  :: {-# UNPACK #-} !Int
    , kcPos :: (IORef (Position a))
    , kcV   :: (v a)
    }

{- invariants
 - kcSz is a power of 2
 -}

-- | Create a new 'KickChan' of the requested size.  The actual size will be
-- rounded up to the next highest power of 2.
newKickChan :: (MVector v' a, v ~ v' RealWorld) => Int -> IO (KickChan v a)
newKickChan sz = do
    kcPos <- newIORef emptyPosition
    kcV <- M.new kcSz
    return KickChan {..}
  where
    kcSz = 2^(ceiling (logBase 2 (fromIntegral $ sz) :: Double) :: Int)
{-# INLINABLE newKickChan #-}

-- | Get the size of a 'KickChan'.
kcSize :: KickChan v a -> Int
kcSize KickChan {kcSz} = kcSz

-- | Put a value into a 'KickChan'.
--
-- O(k), where k == number of readers on this channel.
--
-- putKickChan will never block, instead 'KCReader's will be invalidated if
-- they lag too far behind.
putKickChan :: (MVector v' a, v ~ v' RealWorld) => KickChan v a -> a -> IO ()
putKickChan  KickChan {..} x = do
    curSeq <- atomicModifyIORef' kcPos incrPosition
    M.unsafeWrite kcV (curSeq .&. (kcSz-1)) x
    waiting <- atomicModifyIORef' kcPos $ commit curSeq
    Fold.mapM_ (\v -> putMVar v (Just x)) waiting
{-# INLINE putKickChan #-}

-- | Invalidate all current readers on a channel.
invalidateKickChan :: KickChan v a -> IO ()
invalidateKickChan KickChan {..} = do
    waiting <- atomicModifyIORef' kcPos (invalidatePosition $ 1+kcSz)
    Fold.mapM_ (flip putMVar Nothing) waiting

-- | get a value from a 'KickChan', or 'Nothing' if no longer available.
-- 
-- O(1)
getKickChan :: (MVector v' a, v ~ v' RealWorld) => KickChan v a -> Int -> IO (Maybe a)
getKickChan KickChan {..} readP = do
    await <- newEmptyMVar
    proceed <- atomicModifyIORef' kcPos $ readyOrWait await readP
    if proceed
      then do
        x <- M.unsafeRead kcV (readP .&. (kcSz-1))
        result <- atomicModifyIORef' kcPos (checkWithPosition await kcSz readP)
        case result of
            Ok    -> return $ Just x
            Await -> takeMVar await
            Invalid -> return Nothing
      else takeMVar await

-- | A reader for a 'KickChan'
data KCReader v a = KCReader
    { kcrChan :: {-# UNPACK #-} !(KickChan v a)
    , kcrPos  :: IORef Int
    }

{- invariants
 - kcrPos is the position of the most recently read element (initialized to -1)
 -}

-- | create a new reader for a 'KickChan'.  The reader will be initialized to
-- the head of the KickChan, so that an immediate call to 'readNext' will
-- block (provided no new values have been put into the chan in the meantime).
newReader :: KickChan v a -> IO (KCReader v a)
newReader kcrChan@KickChan{..} = do
    (Position writeP _pMap) <- readIORef kcPos
    kcrPos <- newIORef (writeP-1)
    return KCReader {..}
{-# INLINABLE newReader #-}

-- | get the next value from a 'KCReader'.  This function will block if the next
-- value is not yet available.
--
-- if Nothing is returned, the reader has lagged the writer and values have
-- been dropped.
readNext :: (MVector v' a, v ~ v' RealWorld) => KCReader v a -> IO (Maybe a)
readNext (KCReader {..}) = do
    readP <- atomicModifyIORef' kcrPos (\lastP -> let p = lastP+1 in (p,p))
    getKickChan kcrChan readP
{-# INLINE readNext #-}

-- | The lag between a 'KCReader' and its writer.  Mostly useful for
-- determining if a call to 'readNext' will block.
currentLag :: KCReader v a -> IO Int
currentLag KCReader {..} = do
    lastRead <- readIORef kcrPos
    Position nextWrite pMap <- readIORef $ kcPos kcrChan
    return $! nextWrite - lastRead - IM.size pMap - 1


type KickChanU a = KickChan (U.MVector RealWorld) a
type KickChanS a = KickChan (S.MVector RealWorld) a
type KickChanV a = KickChan (V.MVector RealWorld) a

type KCReaderU a = KCReader (U.MVector RealWorld) a
type KCReaderS a = KCReader (S.MVector RealWorld) a
type KCReaderV a = KCReader (V.MVector RealWorld) a

-- | Constrain a KickChan to work with an 'Unboxed' data storage
kcUnboxed :: KickChan (U.MVector RealWorld) a -> KickChan (U.MVector RealWorld) a
kcUnboxed = id

-- | Constrain a KickChan to work with a standard boxed vector data storage
kcDefault :: KickChan (V.MVector RealWorld) a -> KickChan (V.MVector RealWorld) a
kcDefault = id

-- | Constrain a KickChan to work with a 'Storable' data storage
kcStorable :: KickChan (S.MVector RealWorld) a -> KickChan (S.MVector RealWorld) a
kcStorable = id
