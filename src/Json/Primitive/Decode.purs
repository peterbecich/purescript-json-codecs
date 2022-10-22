module Json.Primitive.Decode where

import Prelude

import Control.Monad.Reader (ReaderT(..), runReaderT)
import Data.Argonaut.Core (Json, caseJson)
import Data.Array (foldMap)
import Data.Array as Array
import Data.Bifunctor (lmap)
import Data.Either (Either(..))
import Data.Maybe (Maybe(..))
import Data.Newtype (class Newtype, over, un, unwrap)
import Data.String (Pattern(..), contains)
import Data.Validation.Semigroup (V(..), invalid)
import Foreign.Object (Object)
import Foreign.Object as Object

-- | When decoding a primtive JSON value, this was the type of value we were expecting to decode.
data ExpectedJsonType
  = ExpectedNull
  | ExpectedBoolean
  | ExpectedNumber
  | ExpectedString
  | ExpectedArray
  | ExpectedObject

printExpectedJsonType :: ExpectedJsonType -> String
printExpectedJsonType = case _ of
  ExpectedNull -> "null"
  ExpectedBoolean -> "boolean"
  ExpectedNumber -> "number"
  ExpectedString -> "string"
  ExpectedArray -> "array"
  ExpectedObject -> "object"

-- | When decoding a primtive JSON value, this was the type of value we were actually got.
data ActualJsonType
  = ActualNull
  | ActualBoolean Boolean
  | ActualNumber Number
  | ActualString String
  | ActualArray (Array Json)
  | ActualObject (Object Json)

printActualJsonType :: ActualJsonType -> String
printActualJsonType = case _ of
  ActualNull -> "null"
  ActualBoolean b -> "boolean: " <> show b
  ActualNumber n -> "number: " <> show n
  ActualString s -> "string: " <> show s
  ActualArray a -> "array of length " <> show (Array.length a)
  ActualObject o -> "object with " <> show (Array.length $ Object.keys o) <> " keys"

-- | Indicates the path to the current JSON value within some larger JSON value
data JsonOffset
  = AtKey String
  | AtIndex Int

derive instance Eq JsonOffset

printJsonOffset :: JsonOffset -> String
printJsonOffset = case _ of
  AtKey s -> if contains (Pattern "'") s || contains (Pattern "\"") s then ".`" <> s <> "`" else "." <> s
  AtIndex i -> "[" <> show i <> "]"

printJsonOffsetPath :: Array JsonOffset -> String
printJsonOffsetPath = append "ROOT" <<< foldMap printJsonOffset

data TypeHint
  = TyName String
  | CtorName String
  | Subterm Int
  | Field String

derive instance Eq TypeHint

printTypeHint :: TypeHint -> String
printTypeHint = case _ of
  TyName s -> "while decoding the type, " <> s
  CtorName s -> "while decoding the constructor, " <> s
  Subterm i -> "while decoding the subterm at index, " <> show i
  Field f -> "while decoding the value under the label, " <> f

type JsonErrorHandlers e =
  { append :: e -> e -> e
  , onTypeMismatch :: Array JsonOffset -> ExpectedJsonType -> ActualJsonType -> e
  , onMissingField :: Array JsonOffset -> String -> e
  , onMissingIndex :: Array JsonOffset -> Int -> e
  , onUnrefinableValue :: Array JsonOffset -> String -> e
  , onStructureError :: Array JsonOffset -> String -> e
  , addHint :: Array JsonOffset -> TypeHint -> e -> e
  }

-- | Overview of values:
-- | - json - the JSON value currently being decoded at this point
-- | - pathSoFar - the position within the larger JSON that the current JSON is located
-- | - handlers - runtime-configured way to handling errors
-- | - extra - top-down custom data one may need for writing a decoder. This is where
-- |           local overrides for typeclass instances can be provided.
-- |           If this value isn't needed, you should set this to `Unit`.
newtype JsonDecoderInput e extra = JsonDecoderInput
  { json :: Json
  , pathSoFar :: Array JsonOffset
  , handlers :: JsonErrorHandlers e
  , extra :: extra
  }

derive instance Newtype (JsonDecoderInput e extra) _

newtype JsonDecoder e extra a = JsonDecoder (ReaderT (JsonDecoderInput e extra) (V e) a)

derive newtype instance functorJsonDecoder :: Functor (JsonDecoder e extra)

instance applyJsonDecoder :: Apply (JsonDecoder e extra) where
  apply (JsonDecoder (ReaderT ff)) (JsonDecoder (ReaderT fa)) = JsonDecoder $ ReaderT \input@(JsonDecoderInput a) ->
    case fa input, ff input of
      V (Left e1), V (Left e2) -> V (Left $ a.handlers.append e1 e2)
      V (Left e1), _ -> V (Left e1)
      _, V (Left e2) -> V (Left e2)
      V (Right a'), V (Right f') -> V (Right (f' a'))

instance applicativeJsonDecoder :: Applicative (JsonDecoder e extra) where
  pure a = JsonDecoder $ ReaderT \_ -> V $ Right a

getPathSoFar :: forall e extra. JsonDecoder e extra (Array JsonOffset)
getPathSoFar = JsonDecoder $ ReaderT \(JsonDecoderInput r) -> V $ Right r.pathSoFar

withOffset :: forall e extra a. JsonOffset -> Json -> JsonDecoder e extra a -> JsonDecoder e extra a
withOffset offset json (JsonDecoder (ReaderT f)) = JsonDecoder $ ReaderT $ f <<< over JsonDecoderInput \r -> r { json = json, pathSoFar = Array.snoc r.pathSoFar offset }

onError :: forall e extra a. (Array JsonOffset -> e -> e) -> JsonDecoder e extra a -> JsonDecoder e extra a
onError mapErrs (JsonDecoder (ReaderT f)) = JsonDecoder $ ReaderT \input@(JsonDecoderInput { pathSoFar }) ->
  lmap (mapErrs pathSoFar) $ f input

failWithMissingField :: forall e extra a. String -> JsonDecoder e extra a
failWithMissingField str = JsonDecoder $ ReaderT \(JsonDecoderInput input) ->
  invalid $ input.handlers.onMissingField input.pathSoFar str

failWithMissingIndex :: forall e extra a. Int -> JsonDecoder e extra a
failWithMissingIndex idx = JsonDecoder $ ReaderT \(JsonDecoderInput input) ->
  invalid $ input.handlers.onMissingIndex input.pathSoFar idx

failWithUnrefinableValue :: forall e extra a. String -> JsonDecoder e extra a
failWithUnrefinableValue msg = JsonDecoder $ ReaderT \(JsonDecoderInput input) ->
  invalid $ input.handlers.onUnrefinableValue input.pathSoFar msg

failWithStructureError :: forall e extra a. String -> JsonDecoder e extra a
failWithStructureError msg = JsonDecoder $ ReaderT \(JsonDecoderInput input) ->
  invalid $ input.handlers.onStructureError input.pathSoFar msg

addHint :: forall e extra a. TypeHint -> JsonDecoder e extra a -> JsonDecoder e extra a
addHint hint (JsonDecoder (ReaderT f)) = JsonDecoder $ ReaderT \input@(JsonDecoderInput r) ->
  lmap (r.handlers.addHint r.pathSoFar hint) $ f input

addTypeHint :: forall e extra a. String -> JsonDecoder e extra a -> JsonDecoder e extra a
addTypeHint = addHint <<< TyName

addCtorHint :: forall e extra a. String -> JsonDecoder e extra a -> JsonDecoder e extra a
addCtorHint = addHint <<< CtorName

addSubtermHint :: forall e extra a. Int -> JsonDecoder e extra a -> JsonDecoder e extra a
addSubtermHint = addHint <<< Subterm

addFieldHint :: forall e extra a. String -> JsonDecoder e extra a -> JsonDecoder e extra a
addFieldHint = addHint <<< Field

-- | Works like `alt`/`<|>`. Decodes using the first decoder and, if that fails,
-- | decodes using the second decoder. Errors from both decoders accumulate.
altAccumulate :: forall e extra a. JsonDecoder e extra a -> JsonDecoder e extra a -> JsonDecoder e extra a
altAccumulate (JsonDecoder (ReaderT f1)) (JsonDecoder (ReaderT f2)) = JsonDecoder $ ReaderT \input@(JsonDecoderInput r) ->
  case unwrap $ f1 input of
    Left e -> case unwrap $ f2 input of
      Left e2 -> invalid $ r.handlers.append e e2
      Right a -> V $ Right a
    Right a -> V $ Right a

-- | Same as `altAccumulate` except only the last error is kept. Helpful in cases
-- | where one is decoding a sum type with a large number of data constructors.
altLast :: forall e extra a. JsonDecoder e extra a -> JsonDecoder e extra a -> JsonDecoder e extra a
altLast (JsonDecoder (ReaderT f1)) (JsonDecoder (ReaderT f2)) = JsonDecoder $ ReaderT \input ->
  case unwrap $ f1 input of
    Left _ -> f2 input
    Right a -> V $ Right a

runJsonDecoder
  :: forall e extra a
   . JsonErrorHandlers e
  -> extra
  -> Json
  -> JsonDecoder e extra a
  -> Either e a
runJsonDecoder handlers extra json (JsonDecoder reader) =
  un V $ runReaderT reader $ JsonDecoderInput { handlers, json, pathSoFar: [], extra }

decodeNull :: forall e extra. JsonDecoder e extra Unit
decodeNull = JsonDecoder $ ReaderT \(JsonDecoderInput { json, pathSoFar, handlers }) ->
  caseJson
    (V <<< Right)
    (invalid <<< handlers.onTypeMismatch pathSoFar ExpectedNull <<< ActualBoolean)
    (invalid <<< handlers.onTypeMismatch pathSoFar ExpectedNull <<< ActualNumber)
    (invalid <<< handlers.onTypeMismatch pathSoFar ExpectedNull <<< ActualString)
    (invalid <<< handlers.onTypeMismatch pathSoFar ExpectedNull <<< ActualArray)
    (invalid <<< handlers.onTypeMismatch pathSoFar ExpectedNull <<< ActualObject)
    json

decodeBoolean :: forall e extra. JsonDecoder e extra Boolean
decodeBoolean = JsonDecoder $ ReaderT \(JsonDecoderInput { json, pathSoFar, handlers }) ->
  caseJson
    (const $ invalid $ handlers.onTypeMismatch pathSoFar ExpectedBoolean ActualNull)
    (V <<< Right)
    (invalid <<< handlers.onTypeMismatch pathSoFar ExpectedBoolean <<< ActualNumber)
    (invalid <<< handlers.onTypeMismatch pathSoFar ExpectedBoolean <<< ActualString)
    (invalid <<< handlers.onTypeMismatch pathSoFar ExpectedBoolean <<< ActualArray)
    (invalid <<< handlers.onTypeMismatch pathSoFar ExpectedBoolean <<< ActualObject)
    json

decodeNumber :: forall e extra. JsonDecoder e extra Number
decodeNumber = JsonDecoder $ ReaderT \(JsonDecoderInput { json, pathSoFar, handlers }) ->
  caseJson
    (const $ invalid $ handlers.onTypeMismatch pathSoFar ExpectedNumber ActualNull)
    (invalid <<< handlers.onTypeMismatch pathSoFar ExpectedNumber <<< ActualBoolean)
    (V <<< Right)
    (invalid <<< handlers.onTypeMismatch pathSoFar ExpectedNumber <<< ActualString)
    (invalid <<< handlers.onTypeMismatch pathSoFar ExpectedNumber <<< ActualArray)
    (invalid <<< handlers.onTypeMismatch pathSoFar ExpectedNumber <<< ActualObject)
    json

decodeString :: forall e extra. JsonDecoder e extra String
decodeString = JsonDecoder $ ReaderT \(JsonDecoderInput { json, pathSoFar, handlers }) ->
  caseJson
    (const $ invalid $ handlers.onTypeMismatch pathSoFar ExpectedString ActualNull)
    (invalid <<< handlers.onTypeMismatch pathSoFar ExpectedString <<< ActualBoolean)
    (invalid <<< handlers.onTypeMismatch pathSoFar ExpectedString <<< ActualNumber)
    (V <<< Right)
    (invalid <<< handlers.onTypeMismatch pathSoFar ExpectedString <<< ActualArray)
    (invalid <<< handlers.onTypeMismatch pathSoFar ExpectedString <<< ActualObject)
    json

decodeArrayPrim :: forall e extra. JsonDecoder e extra (Array Json)
decodeArrayPrim = JsonDecoder $ ReaderT \(JsonDecoderInput { json, pathSoFar, handlers }) ->
  caseJson
    (const $ invalid $ handlers.onTypeMismatch pathSoFar ExpectedArray ActualNull)
    (invalid <<< handlers.onTypeMismatch pathSoFar ExpectedArray <<< ActualBoolean)
    (invalid <<< handlers.onTypeMismatch pathSoFar ExpectedArray <<< ActualNumber)
    (invalid <<< handlers.onTypeMismatch pathSoFar ExpectedArray <<< ActualString)
    (V <<< Right)
    (invalid <<< handlers.onTypeMismatch pathSoFar ExpectedArray <<< ActualObject)
    json

decodeIndex :: forall e extra a. Array Json -> Int -> JsonDecoder e extra a -> JsonDecoder e extra a
decodeIndex arr idx = decodeIndex' arr idx do
  JsonDecoder $ ReaderT \(JsonDecoderInput { pathSoFar, handlers }) ->
    invalid $ handlers.onMissingIndex pathSoFar idx

decodeIndex' :: forall e extra a. Array Json -> Int -> JsonDecoder e extra a -> JsonDecoder e extra a -> JsonDecoder e extra a
decodeIndex' arr idx onMissingIndex decodeElem = case Array.index arr idx of
  Nothing ->
    onMissingIndex
  Just a ->
    withOffset (AtIndex idx) a decodeElem

decodeObjectPrim :: forall e extra. JsonDecoder e extra (Object Json)
decodeObjectPrim = JsonDecoder $ ReaderT \(JsonDecoderInput { json, pathSoFar, handlers }) ->
  caseJson
    (const $ invalid $ handlers.onTypeMismatch pathSoFar ExpectedObject ActualNull)
    (invalid <<< handlers.onTypeMismatch pathSoFar ExpectedObject <<< ActualBoolean)
    (invalid <<< handlers.onTypeMismatch pathSoFar ExpectedObject <<< ActualNumber)
    (invalid <<< handlers.onTypeMismatch pathSoFar ExpectedObject <<< ActualString)
    (invalid <<< handlers.onTypeMismatch pathSoFar ExpectedObject <<< ActualArray)
    (V <<< Right)
    json

decodeField :: forall e extra a. Object Json -> String -> JsonDecoder e extra a -> JsonDecoder e extra a
decodeField obj field = decodeField' obj field do
  JsonDecoder $ ReaderT \(JsonDecoderInput { pathSoFar, handlers }) ->
    invalid $ handlers.onMissingField pathSoFar field

decodeField' :: forall e extra a. Object Json -> String -> JsonDecoder e extra a -> JsonDecoder e extra a -> JsonDecoder e extra a
decodeField' obj field onMissingField decodeElem = case Object.lookup field obj of
  Nothing ->
    onMissingField
  Just a ->
    withOffset (AtKey field) a decodeElem
