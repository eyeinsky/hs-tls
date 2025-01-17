-- |
-- Module      : Network.TLS.Sending13
-- License     : BSD-style
-- Maintainer  : Vincent Hanquez <vincent@snarc.org>
-- Stability   : experimental
-- Portability : unknown
--
-- the Sending module contains calls related to marshalling packets according
-- to the TLS state
--
module Network.TLS.Sending13
       ( writePacket13
       , updateHandshake13
       ) where

import Control.Monad.State
import qualified Data.ByteString as B

import Network.TLS.Struct
import Network.TLS.Struct13
import Network.TLS.Record (RecordM)
import Network.TLS.Record.Types
import Network.TLS.Record.Engage
import Network.TLS.Packet
import Network.TLS.Packet13
import Network.TLS.Context.Internal
import Network.TLS.Handshake.Random
import Network.TLS.Handshake.State
import Network.TLS.Handshake.State13
import Network.TLS.Util
import Network.TLS.Imports

makeRecord :: ProtocolType -> Fragment Plaintext -> RecordM (Record Plaintext)
makeRecord pt fragment =
    return $ Record pt TLS12 fragment

getPacketFragments :: Int -> Packet13 -> [Fragment Plaintext]
getPacketFragments len pkt = map fragmentPlaintext (writePacketContent pkt)
  where writePacketContent (Handshake13 hss)  = getChunks len (encodeHandshakes13 hss)
        writePacketContent (Alert13 a)        = [encodeAlerts a]
        writePacketContent (AppData13 x)      = [x]
        writePacketContent ChangeCipherSpec13 = [encodeChangeCipherSpec]

encodeRecord :: Record Ciphertext -> RecordM ByteString
encodeRecord record = return $ B.concat [ encodeHeader hdr, content ]
  where (hdr, content) = recordToRaw record

writePacket13 :: Context -> Packet13 -> IO (Either TLSError ByteString)
writePacket13 ctx pkt@(Handshake13 hss) = do
    forM_ hss $ updateHandshake13 ctx
    writeFragments ctx pkt
writePacket13 ctx pkt = writeFragments ctx pkt

writeFragments :: Context -> Packet13 -> IO (Either TLSError ByteString)
writeFragments ctx pkt =
    let fragments = getPacketFragments 16384 pkt
        pt = contentType pkt
     in fmap B.concat <$> forEitherM fragments (\frg ->
            prepareRecord ctx (makeRecord pt frg >>= engageRecord >>= encodeRecord))

prepareRecord :: Context -> RecordM a -> IO (Either TLSError a)
prepareRecord = runTxState

updateHandshake13 :: Context -> Handshake13 -> IO ()
updateHandshake13 ctx hs
    | isIgnored hs = return ()
    | otherwise    = usingHState ctx $ do
        when (isHRR hs) wrapAsMessageHash13
        updateHandshakeDigest encoded
        addHandshakeMessage encoded
  where
    encoded = encodeHandshake13 hs

    isHRR (ServerHello13 srand _ _ _) = isHelloRetryRequest srand
    isHRR _                           = False

    isIgnored NewSessionTicket13{} = True
    isIgnored KeyUpdate13{}        = True
    isIgnored _                    = False
