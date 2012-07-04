{-# LANGUAGE TemplateHaskell #-}

module Baskerville.Beta.Session where

import Control.Concurrent.Chan
import Control.Monad
import Control.Monad.IO.Class
import Control.Monad.Trans.Class
import Control.Monad.Trans.State
import Data.Conduit
import Data.Lens.Lazy
import Data.Lens.Template
import qualified Data.Text as T

import Baskerville.Beta.Packets

instance (Show a) => Show (Chan a) where
    show _ = "Chan (...)"

data SessionStatus = Invalid | Connected | Authenticated | Located
   deriving (Eq, Show)

data SessionState = SessionState { _ssStatus :: SessionStatus
                                 , _ssNick :: T.Text
                                 , _ssBroadcast :: Chan Packet
                                 }
    deriving (Show)

$( makeLens ''SessionState )

type Session m = StateT SessionState m

-- | The default starting state for a protocol.
startingState :: IO SessionState
startingState = do
    chan <- newChan
    return $ SessionState Connected T.empty chan

-- | Helper to empty out a Chan and yield all of its contents.
yieldChan :: Chan Packet -> Conduit Packet (Session IO) Packet
yieldChan chan = do
    isEmpty <- liftIO $ isEmptyChan chan
    if isEmpty then return () else do
        opacket <- liftIO $ readChan chan
        yield opacket
        yieldChan chan

-- | Repeatedly read in packets, process them, and output them.
-- Internally holds the state required for a protocol.
worker :: Conduit Packet (Session IO) Packet
worker = do
    s <- lift get
    liftIO $ putStrLn $ "Top of pipeline: " ++ show s
    chan <- lift $ access ssBroadcast
    yieldChan chan
    mpacket <- await
    case mpacket of
        Nothing -> liftIO $ putStrLn "No more packets!"
        Just InvalidPacket -> liftIO $ putStrLn "Invalid packet!"
        Just packet -> do
            liftIO $ putStrLn $ "Got a " ++ show packet ++ " packet!"
            processPacket packet
            status <- lift $ access ssStatus
            unless (status == Invalid) worker

protocol :: Conduit Packet (Session IO) Packet
protocol = do
    chan <- lift $ access ssBroadcast
    chan' <- liftIO $ dupChan chan
    _ <- lift $ ssBroadcast ~= chan'
    worker

invalidate :: (Monad m) => Conduit Packet (Session m) Packet
invalidate = lift $ ssStatus ~= Invalid >> return ()

errorOut :: (Monad m) => String -> Conduit Packet (Session m) Packet
errorOut s = invalidate >> yield (ErrorPacket $ T.pack s)

-- | Broadcast to everybody.
broadcast :: (MonadIO m) => Packet -> Conduit Packet (Session m) Packet
broadcast packet = do
    chan <- lift $ access ssBroadcast
    liftIO $ writeChan chan packet

-- | The main entry point for a protocol.
--   Run this function over a packet and receive zero or more packets in
--   reply. This function should be provided with state so that it can
--   process consecutive packets.
--   The type requires a Monad constraint in order to function correctly with
--   StateT, but doesn't require IO in order to faciliate possible refactoring
--   down the road.
processPacket :: (MonadIO m) => Packet -> Conduit Packet (Session m) Packet

-- | A ping or keep alive packet. Send one back after receiving one from the
--   client.
processPacket (PingPacket _) = yield $ PingPacket 0

-- | Login. Examine all of the bits, make sure they match, and then reply in
--   kind.
processPacket (LoginPacket protoVersion _ _ _ _ _ _ _) =
    -- Is the protocol invalid? Kick the client with an unsupported-protocol
    -- message.
    if protoVersion /= 29
        then errorOut "Unsupported protocol"
        else do
            _ <- lift $ ssStatus ~= Authenticated
            yield $ LoginPacket 1 T.empty (T.pack "default") Creative Earth Peaceful 0 10

-- | Handshake. Just write down the username.
processPacket (HandshakePacket nick) = do
    _ <- lift $ ssNick ~= nick
    yield $ HandshakePacket $ T.pack "-"

-- | Chat packet. Broadcast it to everybody else.
processPacket cp@(ChatPacket chat) = do
    status <- lift $ access ssStatus
    when (status == Authenticated) $ broadcast cp

-- | A poll. Reply with a formatted error packet and close the connection.
processPacket PollPacket = errorOut "Baskerville§0§1"

-- | An error on the client side. They have no right to do this, but let them
--   get away with it anyway. They clearly want to be disconnected, so
--   disconnect them.
processPacket (ErrorPacket _) = invalidate

-- | A packet which we don't handle. Kick the client, we're wasting time here.
processPacket _ = invalidate
