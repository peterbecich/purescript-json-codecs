module Json.Decode.Class where

import Prelude

import Control.Monad.Reader (ReaderT(..))
import Data.Argonaut.Core (Json)
import Data.Array.NonEmpty (NonEmptyArray)
import Data.Either (Either)
import Data.Identity (Identity)
import Data.List (List)
import Data.List.Types (NonEmptyList)
import Data.Map (Map)
import Data.Maybe (Maybe(..))
import Data.Newtype (class Newtype, unwrap)
import Data.NonEmpty (NonEmpty)
import Data.Nullable (Nullable)
import Data.Set (Set)
import Data.Set.NonEmpty (NonEmptySet)
import Data.String (CodePoint)
import Data.String.NonEmpty.Internal (NonEmptyString)
import Data.Symbol (class IsSymbol, reflectSymbol)
import Data.These (These)
import Data.Tuple (Tuple)
import Data.Validation.Semigroup (V)
import Foreign.Object (Object)
import Json.Primitive.Decode (JsonDecoder(..), JsonDecoderInput(..), decodeField', failWithMissingField)
import Json.Types (K0(..), K1(..), K2(..), K3(..), Optional(..))
import Json.Unidirectional.Decode.Value (decodeArray, decodeBoolean, decodeChar, decodeCodePoint, decodeEither, decodeIdentity, decodeInt, decodeList, decodeMap, decodeMaybeTagged, decodeNonEmpty, decodeNonEmptyArray, decodeNonEmptyList, decodeNonEmptySet, decodeNonEmptyString, decodeNullToUnit, decodeNullable, decodeNumber, decodeObject, decodeRecordPrim, decodeSet, decodeString, decodeThese, decodeTuple, decodeVoid)
import Prim.Coerce (class Coercible)
import Prim.Row as Row
import Prim.RowList as RowList
import Prim.RowList as RowToList
import Record as Record
import Record.Builder (Builder, buildFromScratch)
import Record.Builder as Builder
import Safe.Coerce (coerce)
import Type.Proxy (Proxy(..))

class DecodeJson err extra a where
  decodeJson :: JsonDecoder err extra a

instance DecodeJson err extra Void where
  decodeJson = decodeVoid

instance DecodeJson err extra Unit where
  decodeJson = decodeNullToUnit

instance DecodeJson err extra Boolean where
  decodeJson = decodeBoolean

instance DecodeJson err extra Int where
  decodeJson = decodeInt

instance DecodeJson err extra Char where
  decodeJson = decodeChar

instance DecodeJson err extra Number where
  decodeJson = decodeNumber

instance DecodeJson err extra String where
  decodeJson = decodeString

instance DecodeJson err extra NonEmptyString where
  decodeJson = decodeNonEmptyString

instance (DecodeJson err extra a) => DecodeJson err extra (Array a) where
  decodeJson = decodeArray decodeJson

instance (DecodeJson err extra a) => DecodeJson err extra (NonEmptyArray a) where
  decodeJson = decodeNonEmptyArray decodeJson

instance (DecodeJson err extra a) => DecodeJson err extra (Object a) where
  decodeJson = decodeObject decodeJson

instance (DecodeJson err extra a) => DecodeJson err extra (Nullable a) where
  decodeJson = decodeNullable decodeJson

instance (Coercible (JsonDecoder err extra a) (JsonDecoder err extra (Identity a)), DecodeJson err extra a) => DecodeJson err extra (Identity a) where
  decodeJson = decodeIdentity decodeJson

instance (DecodeJson err extra a) => DecodeJson err extra (Maybe a) where
  decodeJson = decodeMaybeTagged decodeJson

instance (DecodeJson err extra l, DecodeJson err extra r) => DecodeJson err extra (Either l r) where
  decodeJson = decodeEither decodeJson decodeJson

instance (DecodeJson err extra l, DecodeJson err extra r) => DecodeJson err extra (Tuple l r) where
  decodeJson = decodeTuple decodeJson decodeJson

instance (DecodeJson err extra l, DecodeJson err extra r) => DecodeJson err extra (These l r) where
  decodeJson = decodeThese decodeJson decodeJson

instance (DecodeJson err extra a, DecodeJson err extra (f a)) => DecodeJson err extra (NonEmpty f a) where
  decodeJson = decodeNonEmpty decodeJson decodeJson

instance (DecodeJson err extra a) => DecodeJson err extra (List a) where
  decodeJson = decodeList decodeJson

instance (DecodeJson err extra a) => DecodeJson err extra (NonEmptyList a) where
  decodeJson = decodeNonEmptyList decodeJson

instance (Ord k, DecodeJson err extra k, DecodeJson err extra v) => DecodeJson err extra (Map k v) where
  decodeJson = decodeMap decodeJson decodeJson

instance (Ord a, DecodeJson err extra a) => DecodeJson err extra (Set a) where
  decodeJson = decodeSet decodeJson

instance (Ord a, DecodeJson err extra a) => DecodeJson err extra (NonEmptySet a) where
  decodeJson = decodeNonEmptySet decodeJson

instance DecodeJson err extra CodePoint where
  decodeJson = decodeCodePoint

-- | Local overrides for types with kind `Type`. Implementation for types annotated with the `K0` type 
-- | are provided via the `extra` label in `JsonDecoderInput`. Value for `extra` must be a
-- | newtyped record. The `sym` in `K0 sym a` must be the label name witin that newtyped record
-- | that contains the local override (i.e. `JsonDecoder err extra a`).
instance
  ( Newtype extra { | rows }
  , Row.Cons sym (JsonDecoder err extra a) tail rows
  , IsSymbol sym
  ) =>
  DecodeJson err extra (K0 sym a) where
  decodeJson = JsonDecoder $ ReaderT \input@(JsonDecoderInput r) -> do
    let
      localOverrides :: { | rows }
      localOverrides = unwrap r.extra
      (JsonDecoder (ReaderT f)) = Record.get (Proxy :: Proxy sym) localOverrides

      reAddNewtype :: V err a -> V err (K0 sym a)
      reAddNewtype = coerce
    reAddNewtype $ f input

-- | Local overrides for types with kind `Type`. Implementation for types annotated with the `K1` type 
-- | are provided via the `extra` label in `JsonDecoderInput`. Value for `extra` must be a
-- | newtyped record. The `sym` in `K1 sym a` must be the label name witin that newtyped record
-- | that contains the function, `JsonDecoder err extra a -> JsonDecoder err extra (f a)`. The input
-- | argument is the corresponding `DecodeJson` implementation for `a`. Thus, one is only overriding
-- | the implementation for `f`, not `a` as well.
instance
  ( Newtype extra { | rows }
  , Row.Cons sym (JsonDecoder err extra a -> JsonDecoder err extra (f a)) tail rows
  , DecodeJson err extra a
  , IsSymbol sym
  ) =>
  DecodeJson err extra (K1 sym (f a)) where
  decodeJson = JsonDecoder $ ReaderT \input@(JsonDecoderInput r) -> do
    let
      localOverrides :: { | rows }
      localOverrides = unwrap r.extra

      buildDecoder :: JsonDecoder err extra a -> JsonDecoder err extra (f a)
      buildDecoder = Record.get (Proxy :: Proxy sym) localOverrides

      (JsonDecoder (ReaderT f)) = buildDecoder decodeJson

      reAddNewtype :: V err (f a) -> V err (K1 sym (f a))
      reAddNewtype = coerce
    reAddNewtype $ f input

-- | Local overrides for types with kind `Type`. Implementation for types annotated with the `K2` type 
-- | are provided via the `extra` label in `JsonDecoderInput`. Value for `extra` must be a
-- | newtyped record. The `sym` in `K2 sym a` must be the label name witin that newtyped record
-- | that contains the function, `JsonDecoder err extra a -> JsonDecoder err extra b -> JsonDecoder err extra (f a b)`. The input
-- | arguments are the corresponding `DecodeJson` implementations for `a` and `b`. Thus, one is only overriding
-- | the implementation for `f`, not `a` and `b` as well.
instance
  ( Newtype extra { | rows }
  , Row.Cons sym (JsonDecoder err extra a -> JsonDecoder err extra b -> JsonDecoder err extra (f a b)) tail rows
  , DecodeJson err extra a
  , DecodeJson err extra b
  , IsSymbol sym
  ) =>
  DecodeJson err extra (K2 sym (f a b)) where
  decodeJson = JsonDecoder $ ReaderT \input@(JsonDecoderInput r) -> do
    let
      localOverrides :: { | rows }
      localOverrides = unwrap r.extra

      buildDecoder :: JsonDecoder err extra a -> JsonDecoder err extra b -> JsonDecoder err extra (f a b)
      buildDecoder = Record.get (Proxy :: Proxy sym) localOverrides

      (JsonDecoder (ReaderT f)) = buildDecoder decodeJson decodeJson

      reAddNewtype :: V err (f a b) -> V err (K2 sym (f a b))
      reAddNewtype = coerce
    reAddNewtype $ f input

-- | Local overrides for types with kind `Type`. Implementation for types annotated with the `K3` type 
-- | are provided via the `extra` label in `JsonDecoderInput`. Value for `extra` must be a
-- | newtyped record. The `sym` in `K3 sym a` must be the label name witin that newtyped record
-- | that contains the function, `JsonDecoder err extra a -> JsonDecoder err extra b -> JsonDecoder err extra c -> JsonDecoder err extra (f a b c)`. The input
-- | arguments are the corresponding `DecodeJson` implementations for `a`, `b`, and `c`. Thus, one is only overriding
-- | the implementation for `f`, not `a`, `b`, and `c` as well.
instance
  ( Newtype extra { | rows }
  , Row.Cons sym (JsonDecoder err extra a -> JsonDecoder err extra b -> JsonDecoder err extra c -> JsonDecoder err extra (f a b c)) tail rows
  , DecodeJson err extra a
  , DecodeJson err extra b
  , DecodeJson err extra c
  , IsSymbol sym
  ) =>
  DecodeJson err extra (K3 sym (f a b c)) where
  decodeJson = JsonDecoder $ ReaderT \input@(JsonDecoderInput r) -> do
    let
      localOverrides :: { | rows }
      localOverrides = unwrap r.extra

      buildDecoder :: JsonDecoder err extra a -> JsonDecoder err extra b -> JsonDecoder err extra c -> JsonDecoder err extra (f a b c)
      buildDecoder = Record.get (Proxy :: Proxy sym) localOverrides

      (JsonDecoder (ReaderT f)) = buildDecoder decodeJson decodeJson decodeJson

      reAddNewtype :: V err (f a b c) -> V err (K3 sym (f a b c))
      reAddNewtype = coerce
    reAddNewtype $ f input

newtype RowListObject :: Type -> Type -> RowList.RowList Type -> Type -> Type
newtype RowListObject err extra rl a = RowListObject (Object a)

instance
  ( RowToList.RowToList rows rl
  , BuildPropDecoders err extra rl { | rows }
  ) =>
  DecodeJson err extra { | rows } where
  decodeJson = decodeRecordPrim \obj -> buildFromScratch <$> buildPropDecoders (RowListObject obj :: RowListObject err extra rl Json)

class BuildPropDecoders err extra rl out | err extra rl -> out where
  buildPropDecoders :: RowListObject err extra rl Json -> JsonDecoder err extra (Builder {} out)

instance BuildPropDecoders err extra RowList.Nil {} where
  buildPropDecoders _ = pure identity
else instance
  ( DecodeJson err extra a
  , BuildPropDecoders err extra tailList { | intermediate }
  , Row.Lacks sym intermediate
  , Row.Cons sym (Optional (Maybe a)) intermediate out
  , IsSymbol sym
  ) =>
  BuildPropDecoders err extra (RowList.Cons sym (Optional (Maybe a)) tailList) { | out } where
  buildPropDecoders (RowListObject obj) = ado
    tailBuilder <- buildPropDecoders (RowListObject obj :: RowListObject err extra tailList Json)
    value <- decodeField' obj keyStr (pure (Optional Nothing)) ((\a -> Optional (Just a)) <$> decodeJson)
    in Builder.insert _sym value <<< tailBuilder
    where
    _sym = Proxy :: Proxy sym
    keyStr = reflectSymbol _sym
else instance
  ( DecodeJson err extra a
  , BuildPropDecoders err extra tailList { | intermediate }
  , Row.Lacks sym intermediate
  , Row.Cons sym a intermediate out
  , IsSymbol sym
  ) =>
  BuildPropDecoders err extra (RowList.Cons sym a tailList) { | out } where
  buildPropDecoders (RowListObject obj) = ado
    tailBuilder <- buildPropDecoders (RowListObject obj :: RowListObject err extra tailList Json)
    value <- decodeField' obj keyStr (failWithMissingField keyStr) decodeJson
    in Builder.insert _sym value <<< tailBuilder
    where
    _sym = Proxy :: Proxy sym
    keyStr = reflectSymbol _sym
