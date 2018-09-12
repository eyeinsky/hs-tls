{-# LANGUAGE OverloadedStrings, BangPatterns #-}

-- |
-- Module      : Network.TLS.Handshake.Common13
-- License     : BSD-style
-- Maintainer  : Vincent Hanquez <vincent@snarc.org>
-- Stability   : experimental
-- Portability : unknown
--
module Network.TLS.Handshake.Common13
       ( makeFinished
       , makeVerifyData
       , makeServerKeyShare
       , makeClientKeyShare
       , fromServerKeyShare
       , makeServerCertVerify
       , makeClientCertVerify
       , checkServerCertVerify
       , makePSKBinder
       , replacePSKBinder
       , createTLS13TicketInfo
       , ageToObfuscatedAge
       , isAgeValid
       , getAge
       , checkFreshness
       , getCurrentTimeFromBase
       , getSessionData13
       , safeNonNegative32
       , dumpKey
       ) where

import Data.Bits (finiteBitSize)
import qualified Data.ByteArray as BA
import qualified Data.ByteString as B
import Data.Hourglass
import Data.IORef (newIORef, readIORef)
import Network.TLS.Context.Internal
import Network.TLS.Cipher
import Network.TLS.Crypto
import qualified Network.TLS.Crypto.IES as IES
import Network.TLS.Extension
import Network.TLS.Handshake.Key
import Network.TLS.Handshake.State
import Network.TLS.Handshake.State13
import Network.TLS.Handshake.Signature
import Network.TLS.Imports
import Network.TLS.KeySchedule
import Network.TLS.MAC
import Network.TLS.State
import Network.TLS.Struct
import Network.TLS.Struct13
import Network.TLS.Types
import Network.TLS.Wire
import Network.TLS.Util
import System.IO
import Time.System

----------------------------------------------------------------

makeFinished :: Context -> Hash -> ByteString -> IO Handshake13
makeFinished ctx usedHash baseKey =
    Finished13 . makeVerifyData usedHash baseKey <$> transcriptHash ctx

makeVerifyData :: Hash -> ByteString -> ByteString -> ByteString
makeVerifyData usedHash baseKey hashValue = hmac usedHash finishedKey hashValue
  where
    hashSize = hashDigestSize usedHash
    finishedKey = hkdfExpandLabel usedHash baseKey "finished" "" hashSize

----------------------------------------------------------------

makeServerKeyShare :: Context -> KeyShareEntry -> IO (ByteString, KeyShareEntry)
makeServerKeyShare ctx (KeyShareEntry grp wcpub) = case ecpub of
  Left  e    -> throwCore $ Error_Protocol (show e, True, HandshakeFailure)
  Right cpub -> do
      (spub, share) <- fromJust "ECDHEShared" <$> generateECDHEShared ctx cpub
      let wspub = IES.encodeGroupPublic spub
          serverKeyShare = KeyShareEntry grp wspub
          key = BA.convert share
      return (key, serverKeyShare)
  where
    ecpub = IES.decodeGroupPublic grp wcpub

makeClientKeyShare :: Context -> Group -> IO (IES.GroupPrivate, KeyShareEntry)
makeClientKeyShare ctx grp = do
    (cpri, cpub) <- generateECDHE ctx grp
    let wcpub = IES.encodeGroupPublic cpub
        clientKeyShare = KeyShareEntry grp wcpub
    return (cpri, clientKeyShare)

fromServerKeyShare :: KeyShareEntry -> IES.GroupPrivate -> IO ByteString
fromServerKeyShare (KeyShareEntry grp wspub) cpri = case espub of
  Left  e    -> throwCore $ Error_Protocol (show e, True, HandshakeFailure)
  Right spub -> case IES.groupGetShared spub cpri of
    Just shared -> return $ BA.convert shared
    Nothing     -> throwCore $ Error_Protocol ("cannote generate a shared secret on (EC)DH", True, HandshakeFailure)
  where
    espub = IES.decodeGroupPublic grp wspub

----------------------------------------------------------------

serverContextString :: ByteString
serverContextString = "TLS 1.3, server CertificateVerify"

clientContextString :: ByteString
clientContextString = "TLS 1.3, client CertificateVerify"

makeServerCertVerify :: Context -> HashAndSignatureAlgorithm -> PrivKey -> ByteString -> IO Handshake13
makeServerCertVerify ctx hs privKey hashValue =
    CertVerify13 hs <$> sign ctx hs privKey target
  where
    target = makeTarget serverContextString hashValue

makeClientCertVerify :: Context -> HashAndSignatureAlgorithm -> PrivKey -> ByteString -> IO Handshake13
makeClientCertVerify ctx hs privKey hashValue =
    CertVerify13 hs <$> sign ctx hs privKey target
 where
    target = makeTarget clientContextString hashValue

checkServerCertVerify :: HashAndSignatureAlgorithm -> ByteString -> PubKey -> ByteString -> IO ()
checkServerCertVerify hs signature pubKey hashValue =
    unless ok $ throwCore $ Error_Protocol ("cannot verify CertificateVerify", True, BadCertificate)
  where
    sig = fromJust "fromPubKey" $ fromPubKey pubKey
    sigParams = signatureParams sig (Just hs)
    target = makeTarget serverContextString hashValue
    ok = kxVerify pubKey sigParams target signature

makeTarget :: ByteString -> ByteString -> ByteString
makeTarget contextString hashValue = runPut $ do
    putBytes $ B.pack $ replicate 64 32
    putBytes contextString
    putWord8 0
    putBytes hashValue

sign :: Context -> HashAndSignatureAlgorithm -> PrivKey -> ByteString -> IO ByteString
sign ctx hs privKey target = usingState_ ctx $ do
    r <- withRNG $ kxSign privKey sigParams target
    case r of
        Left err       -> fail ("sign failed: " ++ show err)
        Right econtent -> return econtent
  where
    sig = fromJust "fromPrivKey" $ fromPrivKey privKey
    sigParams = signatureParams sig (Just hs)

----------------------------------------------------------------

makePSKBinder :: Context -> ByteString -> Hash -> Int -> Maybe ByteString -> IO ByteString
makePSKBinder ctx earlySecret usedHash truncLen mch = do
    rmsgs0 <- usingHState ctx getHandshakeMessagesRev -- fixme
    let rmsgs = case mch of
          Just ch -> trunc ch : rmsgs0
          Nothing -> trunc (head rmsgs0) : tail rmsgs0
        hChTruncated = hash usedHash $ B.concat $ reverse rmsgs
        binderKey = deriveSecret usedHash earlySecret "res binder" (hash usedHash "")
    return $ makeVerifyData usedHash binderKey hChTruncated
  where
    trunc x = B.take takeLen x
      where
        totalLen = B.length x
        takeLen = totalLen - truncLen

replacePSKBinder :: ByteString -> ByteString -> ByteString
replacePSKBinder pskz binder = identities `B.append` binders
  where
    bindersSize = B.length binder + 3
    identities  = B.take (B.length pskz - bindersSize) pskz
    binders     = runPut $ putOpaque16 $ runPut $ putOpaque8 binder

----------------------------------------------------------------

createTLS13TicketInfo :: Word32 -> Either Context Word32 -> IO TLS13TicketInfo
createTLS13TicketInfo life ecw = do
    -- Left:  serverSendTime
    -- Right: clientReceiveTime
    bTime <- getCurrentTimeFromBase
    add <- case ecw of
        Left ctx -> B.foldl' (*+) 0 <$> usingState_ ctx (genRandom 4)
        Right ad -> return ad
    rttref <- newIORef Nothing
    return $ TLS13TicketInfo life add bTime rttref
  where
    x *+ y = x * 256 + fromIntegral y

ageToObfuscatedAge :: Word32 -> TLS13TicketInfo -> Word32
ageToObfuscatedAge age tinfo = obfage
  where
    !obfage = age + ageAdd tinfo

obfuscatedAgeToAge :: Word32 -> TLS13TicketInfo -> Word32
obfuscatedAgeToAge obfage tinfo = age
  where
    !age = obfage - ageAdd tinfo

isAgeValid :: Word32 -> TLS13TicketInfo -> Bool
isAgeValid age tinfo = age <= lifetime tinfo * 1000

getAge :: TLS13TicketInfo -> IO Word32
getAge tinfo = do
    let clientReceiveTime = txrxTime tinfo
    clientSendTime <- getCurrentTimeFromBase
    return $! fromIntegral (clientSendTime - clientReceiveTime) -- milliseconds

checkFreshness :: TLS13TicketInfo -> Word32 -> IO Bool
checkFreshness tinfo obfAge = do
    mrtt <- readIORef $ estimatedRTT tinfo
    case mrtt of
      Nothing -> return False
      Just rtt -> do
        let expectedArrivalTime = serverSendTime + rtt + fromIntegral age
        serverReceiveTime <- getCurrentTimeFromBase
        let freshness = if expectedArrivalTime > serverReceiveTime
                        then expectedArrivalTime - serverReceiveTime
                        else serverReceiveTime - expectedArrivalTime
        -- Some implementations round age up to second.
        -- We take max of 2000 and rtt in the case where rtt is too small.
        let tolerance = max 2000 rtt
            isFresh = freshness < tolerance
        return $ isAlive && isFresh
  where
    serverSendTime = txrxTime tinfo
    age = obfuscatedAgeToAge obfAge tinfo
    isAlive = isAgeValid age tinfo

getCurrentTimeFromBase :: IO Millisecond
getCurrentTimeFromBase = millisecondsFromBase <$> timeCurrentP

millisecondsFromBase :: ElapsedP -> Millisecond
millisecondsFromBase d = fromIntegral ms
  where
    ElapsedP (Elapsed (Seconds s)) (NanoSeconds ns) = d - timeConvert base
    ms = (s * 1000 + ns `div` 1000000)
    base = Date 2017 January 1

----------------------------------------------------------------

getSessionData13 :: Context -> Cipher -> TLS13TicketInfo -> Int -> ByteString -> IO SessionData
getSessionData13 ctx usedCipher tinfo maxSize psk = do
    ver   <- usingState_ ctx getVersion
    malpn <- usingState_ ctx getNegotiatedProtocol
    sni   <- usingState_ ctx getClientSNI
    mgrp  <- usingHState ctx getTLS13Group
    return SessionData {
        sessionVersion     = ver
      , sessionCipher      = cipherID usedCipher
      , sessionCompression = 0
      , sessionClientSNI   = sni
      , sessionSecret      = psk
      , sessionGroup       = mgrp
      , sessionTicketInfo  = Just tinfo
      , sessionALPN        = malpn
      , sessionMaxEarlyDataSize = maxSize
      }

----------------------------------------------------------------

-- Word32 is used in TLS 1.3 protocol.
-- Int is used for API for Haskell TLS because it is natural.
-- If Int is 64 bits, users can specify bigger number than Word32.
-- If Int is 32 bits, 2^31 or larger may be converted into minus numbers.
safeNonNegative32 :: (Num a, Ord a, FiniteBits a) => a -> a
safeNonNegative32 x
  | x <= 0                = 0
  | finiteBitSize x <= 32 = x
  | otherwise             = x `min` fromIntegral (maxBound :: Word32)

----------------------------------------------------------------

dumpKey :: Context -> String -> ByteString -> IO ()
dumpKey ctx label key = do
    mhst <- getHState ctx
    case mhst of
      Nothing  -> return ()
      Just hst -> do
          let cr = unClientRandom $ hstClientRandom hst
          hPutStrLn stderr $ label ++ " " ++ dump cr ++ " " ++ dump key
  where
    dump = init . tail . showBytesHex