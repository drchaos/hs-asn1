-- |
-- Module      : Data.ASN1.DER
-- License     : BSD-style
-- Maintainer  : Vincent Hanquez <vincent@snarc.org>
-- Stability   : experimental
-- Portability : unknown
--
-- A module containing ASN1 DER specification serialization/derialization tools
--
module Data.ASN1.DER
	( ASN1Class(..)
	, ASN1(..)
	, ASN1ConstructionType(..)

	-- * enumeratee to transform between ASN1 and raw
	, enumReadRawRepr
	, enumReadRaw
	, enumWriteRaw

	-- * enumeratee to transform between ASN1 and bytes
	, enumReadBytes
	, enumReadBytesRepr
	, enumWriteBytes

	-- * DER serialize functions
	, decodeASN1EventsRepr
	, decodeASN1Events
	, encodeASN1Events

	, decodeASN1Stream
	, decodeASN1StreamRepr
	, encodeASN1Stream

	) where

import Data.ASN1.Raw (ASN1Class(..), ASN1Length(..), ASN1Header(..), ASN1Event(..), ASN1Err(..))
import qualified Data.ASN1.Raw as Raw

import Data.ASN1.Prim
import Data.ASN1.Stream (ASN1Repr)

import qualified Data.ASN1.BER as BER

import Data.ByteString (ByteString)
import qualified Data.ByteString.Lazy as L

import Control.Monad.Identity
import Control.Exception

import Data.Enumerator (Iteratee, Enumeratee, ($$), (>>==))
import Data.Enumerator.Binary (enumFile)
import qualified Data.Enumerator as E
import qualified Data.Enumerator.List as EL

{- | Check if the length is the minimum possible and it's not indefinite -}
checkLength :: ASN1Length -> Maybe ASN1Err
checkLength LenIndefinite = Just $ PolicyFailed "DER" "indefinite length not allowed"
checkLength (LenShort _)  = Nothing
checkLength (LenLong n i)
	| n == 1 && i < 0x80  = Just $ PolicyFailed "DER" "long length should be a short length"
	| n == 1 && i >= 0x80 = Nothing
	| otherwise           = if i >= 2^((n-1)*8) && i < 2^(n*8)
		then Nothing
		else Just $ PolicyFailed "DER" "long length is not shortest"

checkRawDER :: Monad m => Enumeratee Raw.ASN1Event Raw.ASN1Event m a
checkRawDER = E.checkDone $ \k -> k (E.Chunks []) >>== loop
	where
		loop = E.checkDone go
		go k = EL.head >>= \x -> case x of
			Nothing -> k (E.Chunks []) >>== return
			Just l  -> case tyCheck l of
				Nothing  -> k (E.Chunks [l]) >>== loop
				Just err -> E.throwError err
		tyCheck (Header (ASN1Header _ _ _ len)) = checkLength len
		tyCheck _                               = Nothing

{- | enumReadRaw is an enumeratee from raw events to asn1 -}
enumReadRaw :: Monad m => Enumeratee Raw.ASN1Event ASN1 m a
enumReadRaw = \f -> E.joinI (checkRawDER $$ BER.enumReadRaw f)

{- | enumReadRawRepr is an enumeratee from raw events to asn1repr -}
enumReadRawRepr :: Monad m => Enumeratee Raw.ASN1Event ASN1Repr m a
enumReadRawRepr = \f -> E.joinI (checkRawDER $$ BER.enumReadRawRepr f)

{- | enumWriteRaw is an enumeratee from asn1 to raw events -}
enumWriteRaw :: Monad m => Enumeratee ASN1 Raw.ASN1Event m a
enumWriteRaw = BER.enumWriteRaw

{-| enumReadBytes is an enumeratee converting from bytestring to ASN1
  it transforms chunks of bytestring into chunks of ASN1 objects -}
enumReadBytes :: Monad m => Enumeratee ByteString ASN1 m a
enumReadBytes = \f -> E.joinI (Raw.enumReadBytes $$ (enumReadRaw f))

{-| enumReadBytes is an enumeratee converting from bytestring to ASN1
  it transforms chunks of bytestring into chunks of ASN1 objects -}
enumReadBytesRepr :: Monad m => Enumeratee ByteString ASN1Repr m a
enumReadBytesRepr = \f -> E.joinI (Raw.enumReadBytes $$ (enumReadRawRepr f))

{-| enumWriteBytes is an enumeratee converting from ASN1 to bytestring.
  it transforms chunks of ASN1 objects into chunks of bytestring  -}
enumWriteBytes :: Monad m => Enumeratee ASN1 ByteString m a
enumWriteBytes = \f -> E.joinI (enumWriteRaw $$ (Raw.enumWriteBytes f))

{- helper to transform a Someexception from the enumerator to an ASN1Err if possible -}
wrapASN1Err :: Either SomeException a -> Either ASN1Err a
wrapASN1Err (Left err) = Left (maybe (ASN1ParsingFail $ show err) id $ fromException err)
wrapASN1Err (Right x)  = Right x

{-| decode a list of raw ASN1Events into a stream of ASN1 types -}
decodeASN1Events :: [Raw.ASN1Event] -> Either ASN1Err [ASN1]
decodeASN1Events evs = wrapASN1Err $ runIdentity (iterateEvents evs EL.consume)

{-| decode a list of raw ASN1Events into a stream of ASN1Repr types -}
decodeASN1EventsRepr :: [Raw.ASN1Event] -> Either ASN1Err [ASN1Repr]
decodeASN1EventsRepr evs = wrapASN1Err $ runIdentity (iterateEventsRepr evs EL.consume)

{-| decode a lazy bytestring as an ASN1 stream -}
decodeASN1Stream :: L.ByteString -> Either ASN1Err [ASN1]
decodeASN1Stream l = wrapASN1Err $ runIdentity (iterateByteString l EL.consume)

{-| decode a lazy bytestring as an ASN1repr stream -}
decodeASN1StreamRepr :: L.ByteString -> Either ASN1Err [ASN1Repr]
decodeASN1StreamRepr l = wrapASN1Err $ runIdentity (iterateByteStringRepr l EL.consume)

{-| encode an ASN1 Stream as raw ASN1 Events -}
encodeASN1Events :: [ASN1] -> Either ASN1Err [Raw.ASN1Event]
encodeASN1Events o = wrapASN1Err $ runIdentity run
	where run = E.run (E.enumList 8 o $$ E.joinI $ enumWriteRaw $$ EL.consume)

{-| encode an ASN1 Stream as lazy bytestring -}
encodeASN1Stream :: [ASN1] -> Either ASN1Err L.ByteString
encodeASN1Stream l = either Left (Right . L.fromChunks) $ wrapASN1Err $ runIdentity run
	where run = E.run (E.enumList 1 l $$ E.joinI $ enumWriteBytes $$ EL.consume)
