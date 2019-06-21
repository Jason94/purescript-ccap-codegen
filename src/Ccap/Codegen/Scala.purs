module Ccap.Codegen.Scala
  ( outputSpec
  ) where

import Prelude

import Ccap.Codegen.Annotations (getMaxLength, getWrapOpts, field) as Annotations
import Ccap.Codegen.Shared (Codegen, DelimitedLiteralDir(..), ExtraImports, OutputSpec, delimitedLiteral, indented, runCodegen)
import Ccap.Codegen.Types (Annotations, Module(..), Primitive(..), RecordProp(..), TopType(..), Type(..), TypeDecl(..), isRecord)
import Control.Alt ((<|>))
import Control.Monad.Reader (ask, asks)
import Data.Array ((:))
import Data.Array as Array
import Data.Maybe (Maybe(..), fromMaybe, maybe)
import Data.String (Pattern(..), Replacement(..), replaceAll) as String
import Data.Traversable (for, traverse)
import Data.Tuple (Tuple(..))
import Text.PrettyPrint.Boxes (Box, char, emptyBox, hcat, render, text, vcat, vsep, (//), (<<+>>), (<<>>))
import Text.PrettyPrint.Boxes (left, top) as Boxes

outputSpec :: String -> Array Module -> OutputSpec
outputSpec defaultPackage modules =
  { render: render <<< oneModule defaultPackage modules
  , filePath: \(Module n _ an) ->
      let path = String.replaceAll
                    (String.Pattern ".")
                    (String.Replacement "/")
                    (package defaultPackage an)
      in path <> "/" <> n <> ".scala"
  }

package :: String -> Annotations -> String
package defaultPackage annots =
  fromMaybe defaultPackage (Annotations.field "scala" "package" annots)

oneModule :: String -> Array Module -> Module -> Box
oneModule defaultPackage all mod@(Module name decls annots) = do
  let modDecl = Array.find (\(TypeDecl n tt _) -> n == name && isRecord tt) decls
      env = { defaultPrefix: defaultPackage, currentModule: mod, allModules: all }
      Tuple body extra = runCodegen env do
        modDeclOutput <- traverse (typeDecl TopLevelCaseClass) modDecl
        declsOutput <- traverse (typeDecl CompanionObject) decls
        pure $
          Array.fromFoldable modDeclOutput
            <> [ text ("object " <> name <> " {") ]
            <> (declsOutput <#> indented)
            <> [ char '}']
  vsep 1 Boxes.left do
    [ text ("package " <> package defaultPackage annots)
    , imports extra
    ] <> body

curly :: Box -> Array Box -> Box
curly pref inner =
  vcat Boxes.left (pref <<+>> char '{' : (indented <$> inner) `Array.snoc` char '}')

paren :: Box -> Array Box -> Box
paren pref inner =
  vcat Boxes.left (pref <<>> char '(' : (indented <$> inner) `Array.snoc` char ')')

paren_ :: Box -> Array Box -> Box -> Box
paren_ pref inner suffix =
  vcat Boxes.left (pref <<>> char '(' : (indented <$> inner) `Array.snoc` (char ')' <<>> suffix))

-- TODO: Clean up when we switch to a proper pretty printer.
-- Like `paren`, but outputs on a sigle line.
paren1 :: Box -> Array Box -> Box
paren1 pref inner =
  hcat Boxes.top (pref <<>> char '(' : inner `Array.snoc` char ')')

standardImports :: Array String
standardImports =
  [ "gov.wicourts.jsoncommon.Encoder"
  , "gov.wicourts.jsoncommon.Decoder"
  , "scalaz.Monad"
  ]

imports :: ExtraImports -> Box
imports extra =
  let all = (extra <> standardImports) # Array.sort >>> Array.nub
  in vcat Boxes.left (all <#> \s -> text ("import " <> s))

defEncoder :: String -> Box -> Box
defEncoder name enc =
  text ("lazy val jsonEncoder" <> name <> ": Encoder[" <> name <> ", argonaut.Json] =")
    // indented enc

defDecoder :: String -> String -> Box -> Box
defDecoder name dType dec =
  text ("def jsonDecoder" <> name <> "[M[_]: Monad]: Decoder." <> dType <> "[M, " <> name <> "] =")
    // indented dec

wrapEncoder :: String -> Type -> Box -> Codegen Box
wrapEncoder name t enc = do
  e <- encoder t
  pure $ defEncoder name ((e <<>> text ".compose") `paren` [ enc ])

wrapDecoder :: Annotations -> String -> Type -> Box -> Codegen Box
wrapDecoder annots name t dec = do
  d <- decoderType t
  topDec <- topDecoder annots t
  let body = (topDec <<>> text ".disjunction.andThen") `paren` [ dec ] // text ".validation"
  pure $ defDecoder name d body

data TypeDeclOutputMode = TopLevelCaseClass | CompanionObject
derive instance eqTypeDeclOutputMode :: Eq TypeDeclOutputMode

typeDecl :: TypeDeclOutputMode -> TypeDecl -> Codegen Box
typeDecl outputMode (TypeDecl name tt an) =
  case tt of
    Type t -> do
      dTy <- decoderType t
      ty <- tyType Nothing t
      e <- encoder t
      d <- topDecoder an t
      pure $
        text "type" <<+>> text name <<+>> char '=' <<+>> ty
          // defEncoder name e
          // defDecoder name dTy d
    Wrap t -> do
      case Annotations.getWrapOpts "scala" an of
        Nothing -> do
          dTy <- decoderType t
          ty <- tyType Nothing t
          e <- encoder t
          d <- topDecoder an t
          let
            tagname = text (name <> "T")
            scalatyp = text"scalaz.@@[" <<>> ty <<>> char ',' <<+>> tagname <<>> char ']'
          pure $ vcat Boxes.left
            [ text "final abstract class" <<+>> tagname
            , text "type" <<+>> text name <<+>> char '=' <<+>> scalatyp
            , defEncoder name (e <<>> text ".tagged")
            , defDecoder name dTy (d <<>> text ".tagged")
            ]
        Just { typ, decode, encode } -> do
          wrappedEncoder <-  wrapEncoder name t (text encode)
          wrappedDecoder <- wrapDecoder an name t (text decode <<>> text ".disjunction")
          pure $
            text "type" <<+>> text name <<+>> char '=' <<+>> text typ
              // wrappedEncoder
              // wrappedDecoder
    Record props -> do
      Module modName _ _ <- asks _.currentModule
      let
        qualify =
          if modName == name && outputMode == TopLevelCaseClass
            then Just modName
            else Nothing
      recordFieldTypes <- traverse (recordFieldType qualify) props
      recordFieldEncoders <- traverse recordFieldEncoder props
      let
        cls = (text "final case class" <<+>> text name) `paren` recordFieldTypes
        enc = defEncoder name (text "x => argonaut.Json.obj" `paren` recordFieldEncoders)
      decBody <-
        case Array.length props of
          1 -> maybe (pure (emptyBox 0 0)) (singletonRecordDecoder name) (Array.head props)
          x | x <= 12 -> smallRecordDecoder name props
          x -> bigRecordDecoder name props
      let
        dec = defDecoder name "Form" decBody
        output | modName == name && outputMode == TopLevelCaseClass = cls
        output | modName == name && outputMode == CompanionObject = enc // dec
        output | otherwise = cls // enc // dec
      pure output
    Sum vs -> do
      let
        trait = (text "sealed trait" <<+>> text name) `curly` [ text "def tag: String"]
        variants = vs <#> \v ->
          text ("case object " <> v <> " extends " <> name)
            `curly` [ text ("override def tag: String = " <> show v)]
        assocs = vs <#> \v ->
          paren1 (emptyBox 0 0) [ text (show v), text ", ", text name <<>> char '.' <<>> text v ] <<>> char ','
        params = text (show name) <<>> char ',' : assocs
      enc <- wrapEncoder name (Primitive PString) (text "_.tag")
      dec <- wrapDecoder
              an
              name
              (Primitive PString)
              (((text ("Decoder.enum[M, " <> name) <<>> char ']') `paren` params) // text ".disjunction")
      pure $ trait // ((text "object" <<+>> text name) `curly` variants) // enc // dec

tyType :: Maybe String -> Type -> Codegen Box
tyType qualify ty = do
  allModules <- asks _.allModules
  let wrap tycon t = do
        ty_ <- tyType qualify t
        pure $ text tycon <<>> char '[' <<>> ty_ <<>> char ']'
  case ty of
    Ref _ { mod, typ } ->
      pure $ text (maybe "" (_ <> ".") ((mod >>= modRef allModules) <|> mod <|> qualify) <> typ)
    Array t -> wrap "List" t
    Option t ->  wrap "Option" t
    Primitive p -> pure $ text (case p of
      PBoolean -> "Boolean"
      PInt -> "Int"
      PDecimal -> "BigDecimal"
      PString -> "String"
    )

modRef :: Array Module -> String -> Maybe String
modRef all modName = do
  Module _ _ annots <- Array.find (\(Module n _ _) -> n == modName) all
  p <- Annotations.field "scala" "package" annots
  pure $ p <> "." <> modName

encoderDecoder :: String -> Type -> Codegen Box
encoderDecoder which ty = do
  allModules <- asks _.allModules
  case ty of
    Ref _ { mod, typ } ->
      pure $ text (maybe "" (_ <> ".") ((mod >>= modRef allModules) <|> mod) <> "json" <> which <> typ)
    Array t -> encoderDecoder which t <#> (_ <<>> text ".list")
    Option t -> encoderDecoder which t <#> (_ <<>> text ".option")
    Primitive p -> pure $
      text (case p of
        PBoolean -> which <> ".boolean"
        PInt -> which <> ".int"
        PDecimal -> which <> ".decimal"
        PString -> which <> ".string"
      )

encoder :: Type -> Codegen Box
encoder = encoderDecoder "Encoder"

decoder :: Type -> Codegen Box
decoder = encoderDecoder "Decoder"

topDecoder :: Annotations -> Type -> Codegen Box
topDecoder annots ty = do
  let maxLength = Annotations.getMaxLength annots
  decoder ty <#> (_ <<>> (maybe (emptyBox 0 0) (\s -> text (".maxLength(" <> s <> ")")) maxLength))

decoderType :: Type -> Codegen String
decoderType ty =
  case ty of
    Ref _ { mod, typ } -> do
      { currentModule, allModules } <- ask
      let external = mod >>= (\m -> Array.find (\(Module n _ _) -> n == m) allModules)
          Module _ ds _ = fromMaybe currentModule external
          tt = Array.find (\(TypeDecl n _ _) -> n == typ) ds
                <#> (\(TypeDecl _ t _) -> t)
      maybe (pure "MISSING") decoderTopType tt
    Array t -> decoderType t
    Option t -> decoderType t
    Primitive _ -> pure "Field"

decoderTopType :: TopType -> Codegen String
decoderTopType = case _ of
  Type ty -> decoderType ty
  Wrap ty -> decoderType ty
  Record _ -> pure "Form"
  Sum _ -> pure "Field"

encodeType :: Type -> Box -> Codegen Box
encodeType t e =
  encoder t <#> (_ <<>> text ".encode" `paren1` [ e ])

recordFieldType :: Maybe String -> RecordProp -> Codegen Box
recordFieldType qualify (RecordProp n t) = do
  ty <- tyType qualify t
  pure $ text n <<>> char ':' <<+>> ty <<>> char ','

recordFieldEncoder :: RecordProp -> Codegen Box
recordFieldEncoder (RecordProp n t) = do
  ty <- encodeType t (text ("x." <> n))
  pure $ text (show n <> " ->") <<+>> ty <<>> char ','

recordFieldDecoder :: RecordProp -> Codegen Box
recordFieldDecoder (RecordProp n t) =
  decoder t <#> (_ <<>> text ".property(" <<>> text (show n) <<>> char ')')

singletonRecordDecoder :: String -> RecordProp -> Codegen Box
singletonRecordDecoder name prop =
  recordFieldDecoder prop <#> (_ <<>> text (".map(" <> name <> ".apply)"))

smallRecordDecoder :: String -> Array RecordProp -> Codegen Box
smallRecordDecoder name props = do
  ps <- traverse (\r -> recordFieldDecoder r <#> (_ <<>> char ',')) props
  pure $
    paren_
      (text ("scalaz.Apply[Decoder.Form[M, ?]].apply" <> show (Array.length props)))
      ps
      (text ("(" <> name <> ".apply)"))

bigRecordDecoder :: String -> Array RecordProp -> Codegen Box
bigRecordDecoder name props = do
  body <-
    for parts \part ->
      if Array.length part == 1
        then
          maybe
            (pure (emptyBox 0 0))
            (\r -> recordFieldDecoder r <#> (_ <<>> char ','))
            (Array.head part)
        else do
          decs <- traverse (\r -> recordFieldDecoder r <#> (_ <<>> char ',')) part
          pure $
            paren_
              (text ("scalaz.Apply[Decoder.Form[M, ?]].tuple" <> show (Array.length part)))
              decs
              (char ',')
  pure $
    paren_
      (text ("scalaz.Apply[Decoder.Form[M, ?]].apply" <> show (Array.length parts)))
      body
      (curly (emptyBox 0 0) [ applyAllParams ])
  where
    parts = chunksOf 5 props
    applyAllParams =
      paren_
        (text "case ")
        (parts <#> \part ->
            -- No trailing commas allowed when matching a tuple pattern
            (delimitedLiteral Horiz '(' ')' (part <#> \(RecordProp n _) -> text n)) <<>> char ',')
        (text " =>" // indented applyAllConstructor)
    applyAllConstructor =
      paren (text name) (props <#> \(RecordProp n _) -> text (n <> " = " <> n <> ","))

chunksOf :: forall a. Int -> Array a -> Array (Array a)
chunksOf n as =
  Array.range 0 ((Array.length as - 1) / n) <#> \i ->
    Array.slice (i*n) (i*n + n) as
