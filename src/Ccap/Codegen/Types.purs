module Ccap.Codegen.Types
  ( IsRequired(..)
  , Module(..)
  , Primitive(..)
  , TyTypeNonRecord(..)
  , RecordProp(..)
  , TyTypeOrRecord(..)
  , TypeDecl(..)
  , Variant
  ) where

import Data.Generic.Rep (class Generic)
import Data.Generic.Rep.Show (genericShow)
import Prelude (class Eq, class Show)
import Text.Parsing.Parser.Pos (Position)

data Module = Module String (Array TypeDecl)

data TypeDecl = TypeDecl String TyTypeOrRecord

data TyTypeOrRecord
  = TyTypeNonRecord TyTypeNonRecord
  | TyRecord (Array RecordProp)

data TyTypeNonRecord
  = Primitive Primitive
  | TyRef Position String
  | TyArray TyTypeNonRecord
  | TySum (Array Variant)

data RecordProp = RecordProp String TyTypeNonRecord IsRequired

type Variant = String

data IsRequired
  = Required
  | Optional

data Primitive
  = PBoolean
  | PDate
  | PDateTime
  | PInt
  | PDecimal
  | PString
  | PTime

-- Instances here to avoid cluttering the above

derive instance eqModule :: Eq Module
derive instance genericModule :: Generic Module _
instance showModule :: Show Module where
  show = genericShow

derive instance eqTyTypeNonRecord :: Eq TyTypeNonRecord
derive instance genericTyTypeNonRecord :: Generic TyTypeNonRecord _
instance showTyTypeNonRecord :: Show TyTypeNonRecord where
  show t = genericShow t

derive instance eqTyType :: Eq TyTypeOrRecord
derive instance genericTyType :: Generic TyTypeOrRecord _
instance showTyType :: Show TyTypeOrRecord where
  show = genericShow

derive instance eqTypeDecl :: Eq TypeDecl
derive instance genericTypeDecl :: Generic TypeDecl _
instance showTypeDecl :: Show TypeDecl where
  show = genericShow

derive instance eqRecordProp :: Eq RecordProp
derive instance genericRecordProp :: Generic RecordProp _
instance showRecordProp :: Show RecordProp where
  show = genericShow

derive instance eqIsRequired :: Eq IsRequired
derive instance genericIsRequired :: Generic IsRequired _
instance showIsRequired :: Show IsRequired where
  show = genericShow

derive instance eqPrimitive :: Eq Primitive
derive instance genericPrimitive :: Generic Primitive _
instance showPrimitive :: Show Primitive where
  show = genericShow
