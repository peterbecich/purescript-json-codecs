module Codec.Json.Errors.PrimitiveJsonError where

import Prelude

import Codec.Json.Errors.Tree (TreeError(..))
import Codec.Json.JsonDecoder (JsonDecoder, runJsonDecoder)
import Codec.Json.Types (ActualJsonType, ExpectedJsonType, JsonErrorHandlers(..), JsonOffset, TypeHint, printActualJsonType, printExpectedJsonType, printJsonOffsetPath, printTypeHint)
import Data.Argonaut.Core (Json)
import Data.Array as Array
import Data.Array.NonEmpty as NEA
import Data.Bifoldable (bifoldMap)
import Data.Either (Either(..))
import Data.Function.Uncurried (mkFn2, mkFn3)
import Data.Monoid (power)
import Data.Newtype (class Newtype, over, unwrap)
import Data.These (These(..))

data JsonLeafError
  = TypeMismatch ExpectedJsonType ActualJsonType
  | MissingField String
  | MissingIndex Int
  | UnrefinableValue String
  | StructureError String

printJsonLeafError :: JsonLeafError -> String
printJsonLeafError = case _ of
  TypeMismatch exp act -> printTypeMismatchErr exp act
  MissingField field -> printMissingField field
  MissingIndex idx -> printMissingIndex idx
  UnrefinableValue str -> str
  StructureError str -> str

printTypeMismatchErr :: ExpectedJsonType -> ActualJsonType -> String
printTypeMismatchErr exp act =
  "Expected " <> printExpectedJsonType exp <> " but got " <> printActualJsonType act

printMissingField :: String -> String
printMissingField str =
  "Failed to decode a value under the field `" <> str <> "` because the field did not exist."

printMissingIndex :: Int -> String
printMissingIndex idx =
  "Failed to decode a value under the index `" <> show idx <> "` because the element did not exist."

newtype PrimitiveJsonError = PrimitiveJsonError
  ( TreeError
      { path :: Array JsonOffset, hint :: TypeHint }
      { path :: Array JsonOffset, error :: JsonLeafError }
  )

derive instance Newtype PrimitiveJsonError _
derive newtype instance Semigroup PrimitiveJsonError

pjeHandlers :: JsonErrorHandlers PrimitiveJsonError
pjeHandlers = JsonErrorHandlers
  { onTypeMismatch: mkFn3 \path exp -> PrimitiveJsonError <<< TreeError <<< Right <<< { path, error: _ } <<< TypeMismatch exp
  , onMissingField: mkFn2 \path -> PrimitiveJsonError <<< TreeError <<< Right <<< { path, error: _ } <<< MissingField
  , onMissingIndex: mkFn2 \path -> PrimitiveJsonError <<< TreeError <<< Right <<< { path, error: _ } <<< MissingIndex
  , onUnrefinableValue: mkFn2 \path -> PrimitiveJsonError <<< TreeError <<< Right <<< { path, error: _ } <<< UnrefinableValue
  , onStructureError: mkFn2 \path -> PrimitiveJsonError <<< TreeError <<< Right <<< { path, error: _ } <<< StructureError
  , includeJsonOffset: true
  , addHint: mkFn3 \path hint -> over PrimitiveJsonError case _ of
      TreeError (Left (That x)) -> TreeError $ Left $ Both { path, hint } x
      x -> TreeError $ Left $ Both { path, hint } $ NEA.singleton x
  }

printPrimitiveJsonError :: PrimitiveJsonError -> String
printPrimitiveJsonError =
  Array.intercalate "\n"
    <<< bifoldMap
      ( \{ path, hint } -> do
          let indent = indentByPathLength path
          [ indent <> printTypeHint hint
          , indent <> printPath path
          ]
      )
      ( \{ path, error } -> do
          let indent = indentByPathLength path
          [ indent <> printJsonLeafError error
          , indent <> printPath path
          ]
      )
    <<< unwrap
  where
  printPath p = "  at path: " <> printJsonOffsetPath p
  indentByPathLength p = power "  " $ Array.length p

runJsonDecoderPJE :: forall a. Json -> JsonDecoder PrimitiveJsonError Unit a -> Either PrimitiveJsonError a
runJsonDecoderPJE = runJsonDecoderPJE' unit

runJsonDecoderPJE' :: forall a extra. extra -> Json -> JsonDecoder PrimitiveJsonError extra a -> Either PrimitiveJsonError a
runJsonDecoderPJE' = runJsonDecoder pjeHandlers (<>)

pje :: forall a. JsonDecoder PrimitiveJsonError Unit a -> JsonDecoder PrimitiveJsonError Unit a
pje = identity

pje' :: forall a extra. JsonDecoder PrimitiveJsonError extra a -> JsonDecoder PrimitiveJsonError extra a
pje' = identity
