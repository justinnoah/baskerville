{-# LANGUAGE TemplateHaskell #-}

module Baskerville.Chunk where

import Prelude hiding ((.))

import Control.Category
import Codec.Compression.Zlib
import Data.Array
import Data.Bits
import qualified Data.ByteString as BS
import qualified Data.ByteString.Lazy as LBS
import Data.Int
import qualified Data.IntMap as IM
import Data.Lens.Common
import Data.Lens.Template
import Data.Serialize
import Data.Word

import Baskerville.Coords

type ChunkArray = Array BCoord Word8

newtype MicroChunk = MicroChunk { getMicroChunk :: ChunkArray }
    deriving (Eq, Show)

data Chunk = Chunk { _cX, _cZ :: Int32, _cBlocks :: IM.IntMap MicroChunk }
    deriving (Eq, Show)

$( makeLens ''Chunk )

instance Serialize MicroChunk where
    put _ = do
        put $ BS.replicate 4096 0x02 -- block type
        put $ BS.replicate 2048 0x00 -- block meta
        put $ BS.replicate 2048 0xff -- block light
        put $ BS.replicate 2048 0xff -- sky light
        -- not sending additional array
        -- not sending biome data

    get = error "Can't get ye chunk!"

instance Serialize Chunk where
    put (Chunk x z blocks) = let
        bitmap :: Word16
        bitmap = foldr (\i j -> (1 `shiftL` i) .|. j) 0 (IM.keys blocks)
        chunks = runPut $ mapM_ put $ IM.elems blocks
        compressed = compress . LBS.fromChunks $ [chunks]
        converter :: Int64 -> Word32
        converter = fromIntegral
        in do
            put x
            put z
            put False -- whether biome data
            put bitmap
            put (0x0 :: Word16) -- additional bitmap
            put $ converter $ LBS.length compressed
            put (0x0 :: Word32) -- hole in packet
            put compressed

    get = error "Can't get ye chunk!"

-- | Create a new array with a given value.
newFilledArray :: Word8 -> ChunkArray
newFilledArray x = let
    boundaries = (BCoord 0 0 0, BCoord 16 16 16)
    in array boundaries [(i, x) | i <- range boundaries]

-- | Create a zeroed-out chunk array.
newArray :: ChunkArray
newArray = newFilledArray 0x0

-- | Create a chunk at the given chunk coordinates.
newChunk :: Int32 -> Int32 -> Chunk
newChunk x z = Chunk x z IM.empty

type Generator = Int -> Maybe MicroChunk -> Maybe MicroChunk

pureGenerator :: (Int -> MicroChunk -> MicroChunk) -> Generator
pureGenerator g i = fmap $ g i

-- | Run a generator on a given chunk.
runGenerator :: Generator -> Chunk -> Chunk
runGenerator g chunk = let
    l :: Int -> Lens Chunk (Maybe MicroChunk)
    l x = intMapLens x . cBlocks
    f :: Int -> Chunk -> Chunk
    f i = modL (l i) (g i)
    in foldr f chunk [0..15]
