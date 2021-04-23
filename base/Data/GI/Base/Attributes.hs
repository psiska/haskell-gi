{-# LANGUAGE GADTs, ScopedTypeVariables, DataKinds, KindSignatures,
  TypeFamilies, TypeOperators, MultiParamTypeClasses, ConstraintKinds,
  UndecidableInstances, FlexibleInstances, TypeApplications,
  DefaultSignatures, PolyKinds, AllowAmbiguousTypes,
  ImplicitParams, RankNTypes #-}

-- |
--
-- == Basic attributes interface
--
-- Attributes of an object can be get, set and constructed. For types
-- descending from 'Data.GI.Base.BasicTypes.GObject', properties are
-- encoded in attributes, although attributes are slightly more
-- general (every property of a `Data.GI.Base.BasicTypes.GObject` is an
-- attribute, but we can also have attributes for types not descending
-- from `Data.GI.Base.BasicTypes.GObject`).
--
-- If you're wondering what the possible attributes of a GObject are,
-- look at the list of properties in the documentation, e.g. the
-- Properties heading of the docs for 'GI.Gtk.Objects.Button' lists
-- properties such as @image@ and @relief@. Parent classes may also
-- introduce properties, so since a Button is an instance of
-- @IsActionable@, it inherits properties like @actionName@ from
-- 'GI.Gtk.Interfaces.Actionable' too.
--
-- As an example consider a @button@ widget and a property (of the
-- Button class, or any of its parent classes or implemented
-- interfaces) called "label". The simplest way of getting the value
-- of the button is to do
--
-- > value <- getButtonLabel button
--
-- And for setting:
--
-- > setButtonLabel button label
--
-- This mechanism quickly becomes rather cumbersome, for example for
-- setting the "window" property in a DOMDOMWindow in WebKit:
--
-- > win <- getDOMDOMWindowWindow dom
--
-- and perhaps more importantly, one needs to chase down the type
-- which introduces the property:
--
-- > setWidgetSensitive button False
--
-- There is no @setButtonSensitive@, since it is the @Widget@ type
-- that introduces the "sensitive" property.
--
-- == Overloaded attributes
--
-- A much more convenient overloaded attribute resolution API is
-- provided by this module. Getting the value of an object's attribute
-- is straightforward:
--
-- > value <- get button _label
--
-- The definition of @_label@ is basically a 'Proxy' encoding the name
-- of the attribute to get:
--
-- > _label = fromLabelProxy (Proxy :: Proxy "label")
--
-- These proxies can be automatically generated by invoking the code
-- generator with the @-l@ option. The leading underscore is simply so
-- the autogenerated identifiers do not pollute the namespace, but if
-- this is not a concern the autogenerated names (in the autogenerated
-- @GI/Properties.hs@) can be edited as one wishes.
--
-- In addition, for ghc >= 8.0, one can directly use the overloaded
-- labels provided by GHC itself. Using the "OverloadedLabels"
-- extension, the code above can also be written as
--
-- > value <- get button #label
--
-- The syntax for setting or updating an attribute is only slightly more
-- complex. At the simplest level it is just:
--
-- > set button [ _label := value ]
--
-- or for the WebKit example above
--
-- > set dom [_window := win]
--
-- However as the list notation would indicate, you can set or update multiple
-- attributes of the same object in one go:
--
-- > set button [ _label := value, _sensitive := False ]
--
-- You are not limited to setting the value of an attribute, you can also
-- apply an update function to an attribute's value. That is the function
-- receives the current value of the attribute and returns the new value.
--
-- > set spinButton [ _value :~ (+1) ]
--
-- There are other variants of these operators, see 'AttrOp'
-- below. ':=>' and ':~>' are like ':=' and ':~' but operate in the
-- 'IO' monad rather than being pure.
--
-- Attributes can also be set during construction of a
-- `Data.GI.Base.BasicTypes.GObject` using `Data.GI.Base.Constructible.new`
--
-- > button <- new Button [_label := "Can't touch this!", _sensitive := False]
--
-- In addition for value being set/get having to have the right type,
-- there can be attributes that are read-only, or that can only be set
-- during construction with `Data.GI.Base.Properties.new`, but cannot be
-- `set` afterwards. That these invariants hold is also checked during
-- compile time.
--
-- == Nullable attributes
--
-- Whenever the attribute is represented as a pointer in the C side,
-- it is often the case that the underlying C representation admits or
-- returns @NULL@ as a valid value for the property. In these cases
-- the `get` operation may return a `Maybe` value, with `Nothing`
-- representing the @NULL@ pointer value (notable exceptions are
-- `Data.GI.Base.BasicTypes.GList` and
-- `Data.GI.Base.BasicTypes.GSList`, for which @NULL@ is represented
-- simply as the empty list). This can be overridden in the
-- introspection data, since sometimes attributes are non-nullable,
-- even if the type would allow for @NULL@.
--
-- For convenience, in nullable cases the `set` operation will by
-- default /not/ take a `Maybe` value, but rather assume that the
-- caller wants to set a non-@NULL@ value. If setting a @NULL@ value
-- is desired, use `clear` as follows
--
-- > clear object _propName
--
module Data.GI.Base.Attributes (
  AttrInfo(..),

  AttrOpTag(..),

  AttrOp(..),
  AttrOpAllowed,

  AttrGetC,
  AttrSetC,
  AttrConstructC,
  AttrClearC,

  get,
  set,
  clear,

  AttrLabelProxy(..)
  ) where

import Control.Monad (void)
import Control.Monad.IO.Class (MonadIO, liftIO)

import Data.GI.Base.BasicTypes (GObject)
import Data.GI.Base.GValue (GValueConstruct)
import Data.GI.Base.Overloading (HasAttributeList, ResolveAttribute)

import {-# SOURCE #-} Data.GI.Base.Signals (SignalInfo(..), SignalProxy,
                                            on, after)

import Data.Proxy (Proxy(..))
import Data.Kind (Type)

import GHC.TypeLits
import GHC.Exts (Constraint)

import GHC.OverloadedLabels (IsLabel(..))

infixr 0 :=,:~,:=>,:~>

-- | A proxy for attribute labels.
data AttrLabelProxy (a :: Symbol) = AttrLabelProxy

#if MIN_VERSION_base(4,10,0)
instance a ~ x => IsLabel x (AttrLabelProxy a) where
    fromLabel = AttrLabelProxy
#else
instance a ~ x => IsLabel x (AttrLabelProxy a) where
    fromLabel _ = AttrLabelProxy
#endif

-- | Info describing an attribute.
class AttrInfo (info :: Type) where
    -- | The operations that are allowed on the attribute.
    type AttrAllowedOps info :: [AttrOpTag]

    -- | Constraint on the type for which we are allowed to
    -- create\/set\/get the attribute.
    type AttrBaseTypeConstraint info :: Type -> Constraint

    -- | Type returned by `attrGet`.
    type AttrGetType info

    -- | Constraint on the value being set.
    type AttrSetTypeConstraint info :: Type -> Constraint
    type AttrSetTypeConstraint info = (~) (AttrGetType info)

    -- | Constraint on the value being set, with allocation allowed
    -- (see ':&=' below).
    type AttrTransferTypeConstraint info :: Type -> Constraint
    type AttrTransferTypeConstraint info = (~) (AttrTransferType info)

    -- | Type resulting from the allocation.
    type AttrTransferType info :: Type
    type AttrTransferType info = AttrGetType info

    -- | Name of the attribute.
    type AttrLabel info :: Symbol

    -- | Type which introduces the attribute.
    type AttrOrigin info

    -- | Get the value of the given attribute.
    attrGet :: AttrBaseTypeConstraint info o =>
               o -> IO (AttrGetType info)
    default attrGet :: -- Make sure that a non-default method
                       -- implementation is provided if AttrGet
                       -- is set.
                        CheckNotElem 'AttrGet (AttrAllowedOps info)
                         (GetNotProvidedError info) =>
                       o -> IO (AttrGetType info)
    attrGet = undefined

    -- | Set the value of the given attribute, after the object having
    -- the attribute has already been created.
    attrSet :: (AttrBaseTypeConstraint info o,
                AttrSetTypeConstraint info b) =>
               o -> b -> IO ()
    default attrSet :: -- Make sure that a non-default method
                        -- implementation is provided if AttrSet
                        -- is set.
                        CheckNotElem 'AttrSet (AttrAllowedOps info)
                         (SetNotProvidedError info) =>
                       o -> b -> IO ()
    attrSet = undefined

    -- | Set the value of the given attribute to @NULL@ (for nullable
    -- attributes).
    attrClear :: AttrBaseTypeConstraint info o =>
                 o -> IO ()
    default attrClear ::  -- Make sure that a non-default method
                          -- implementation is provided if AttrClear
                          -- is set.
                          CheckNotElem 'AttrClear (AttrAllowedOps info)
                                       (ClearNotProvidedError info) =>
                      o -> IO ()
    attrClear = undefined

    -- | Build a `Data.GI.Base.GValue.GValue` representing the attribute.
    attrConstruct :: (AttrBaseTypeConstraint info o,
                      AttrSetTypeConstraint info b) =>
                     b -> IO (GValueConstruct o)
    default attrConstruct :: -- Make sure that a non-default method
                             -- implementation is provided if AttrConstruct
                             -- is set.
                             CheckNotElem 'AttrConstruct (AttrAllowedOps info)
                               (ConstructNotProvidedError info) =>
                      b -> IO (GValueConstruct o)
    attrConstruct = undefined

    -- | Allocate memory as necessary to generate a settable type from
    -- the transfer type. This is useful for types which needs
    -- allocations for marshalling from Haskell to C, this makes the
    -- allocation explicit.
    attrTransfer :: forall o b. (AttrBaseTypeConstraint info o,
                               AttrTransferTypeConstraint info b) =>
                    Proxy o -> b -> IO (AttrTransferType info)
    default attrTransfer :: forall o b. (AttrBaseTypeConstraint info o,
                             AttrTransferTypeConstraint info b,
                             b ~ AttrGetType info,
                             b ~ AttrTransferType info) =>
                            Proxy o -> b -> IO (AttrTransferType info)
    attrTransfer _ = return

-- | Pretty print a type, indicating the parent type that introduced
-- the attribute, if different.
type family TypeOriginInfo definingType useType :: ErrorMessage where
    TypeOriginInfo definingType definingType =
        'Text "‘" ':<>: 'ShowType definingType ':<>: 'Text "’"
    TypeOriginInfo definingType useType =
        'Text "‘" ':<>: 'ShowType useType ':<>:
        'Text "’ (inherited from parent type ‘" ':<>:
        'ShowType definingType ':<>: 'Text "’)"

-- | Look in the given list to see if the given `AttrOp` is a member,
-- if not return an error type.
type family AttrOpIsAllowed (tag :: AttrOpTag) (ops :: [AttrOpTag]) (label :: Symbol) (definingType :: Type) (useType :: Type) :: Constraint where
    AttrOpIsAllowed tag '[] label definingType useType =
        TypeError ('Text "Attribute ‘" ':<>: 'Text label ':<>:
                   'Text "’ for type " ':<>:
                   TypeOriginInfo definingType useType ':<>:
                   'Text " is not " ':<>:
                   'Text (AttrOpText tag) ':<>: 'Text ".")
    AttrOpIsAllowed tag (tag ': ops) label definingType useType = ()
    AttrOpIsAllowed tag (other ': ops) label definingType useType = AttrOpIsAllowed tag ops label definingType useType

-- | Whether a given `AttrOpTag` is allowed on an attribute, given the
-- info type.
type family AttrOpAllowed (tag :: AttrOpTag) (info :: Type) (useType :: Type) :: Constraint where
    AttrOpAllowed tag info useType =
        AttrOpIsAllowed tag (AttrAllowedOps info) (AttrLabel info) (AttrOrigin info) useType

-- | Error to be raised when an operation is allowed, but an
-- implementation has not been provided.
type family OpNotProvidedError (info :: o) (op :: AttrOpTag) (methodName :: Symbol) :: ErrorMessage where
  OpNotProvidedError info op methodName =
    'Text "The attribute ‘" ':<>: 'Text (AttrLabel info) ':<>:
    'Text "’ for type ‘" ':<>:
    'ShowType (AttrOrigin info) ':<>:
    'Text "’ is declared as " ':<>:
    'Text (AttrOpText op) ':<>:
    'Text ", but no implementation of ‘" ':<>:
    'Text methodName ':<>:
    'Text "’ has been provided."
    ':$$: 'Text "Either provide an implementation of ‘" ':<>:
    'Text methodName ':<>:
    'Text "’ or remove ‘" ':<>:
    'ShowType op ':<>:
    'Text "’ from ‘AttrAllowedOps’."

-- | Error to be raised when AttrClear is allowed, but an
-- implementation has not been provided.
type family ClearNotProvidedError (info :: o) :: ErrorMessage where
  ClearNotProvidedError info = OpNotProvidedError info 'AttrClear "attrClear"

-- | Error to be raised when AttrGet is allowed, but an
-- implementation has not been provided.
type family GetNotProvidedError (info :: o) :: ErrorMessage where
  GetNotProvidedError info = OpNotProvidedError info 'AttrGet "attrGet"

-- | Error to be raised when AttrSet is allowed, but an
-- implementation has not been provided.
type family SetNotProvidedError (info :: o) :: ErrorMessage where
  SetNotProvidedError info = OpNotProvidedError info 'AttrSet "attrSet"

-- | Error to be raised when AttrConstruct is allowed, but an
-- implementation has not been provided.
type family ConstructNotProvidedError (info :: o) :: ErrorMessage where
  ConstructNotProvidedError info = OpNotProvidedError info 'AttrConstruct "attrConstruct"

-- | Check if the given element is a member, and if so raise the given
-- error.
type family CheckNotElem (a :: k) (as :: [k]) (msg :: ErrorMessage) :: Constraint where
  CheckNotElem a '[] msg = ()
  CheckNotElem a (a ': rest) msg = TypeError msg
  CheckNotElem a (other ': rest) msg = CheckNotElem a rest msg

-- | Possible operations on an attribute.
data AttrOpTag = AttrGet
               -- ^ It is possible to read the value of the attribute
               -- with `get`.
               | AttrSet
               -- ^ It is possible to write the value of the attribute
               -- with `set`.
               | AttrConstruct
               -- ^ It is possible to set the value of the attribute
               -- in `Data.GI.Base.Constructible.new`.
               | AttrClear
               -- ^ It is possible to clear the value of the
               -- (nullable) attribute with `clear`.
  deriving (Eq, Ord, Enum, Bounded, Show)

-- | A user friendly description of the `AttrOpTag`, useful when
-- printing type errors.
type family AttrOpText (tag :: AttrOpTag) :: Symbol where
    AttrOpText 'AttrGet = "gettable"
    AttrOpText 'AttrSet = "settable"
    AttrOpText 'AttrConstruct = "constructible"
    AttrOpText 'AttrClear = "nullable"

-- | Constraint on a @obj@\/@attr@ pair so that `set` works on values
-- of type @value@.
type AttrSetC info obj attr value = (HasAttributeList obj,
                                     info ~ ResolveAttribute attr obj,
                                     AttrInfo info,
                                     AttrBaseTypeConstraint info obj,
                                     AttrOpAllowed 'AttrSet info obj,
                                     (AttrSetTypeConstraint info) value)

-- | Constraint on a @obj@\/@value@ pair so that
-- `Data.GI.Base.Constructible.new` works on values of type @value@.
type AttrConstructC info obj attr value = (HasAttributeList obj,
                                           info ~ ResolveAttribute attr obj,
                                           AttrInfo info,
                                           AttrBaseTypeConstraint info obj,
                                           AttrOpAllowed 'AttrConstruct info obj,
                                           (AttrSetTypeConstraint info) value)

-- | Constructors for the different operations allowed on an attribute.
data AttrOp obj (tag :: AttrOpTag) where
    -- | Assign a value to an attribute
    (:=)  :: (HasAttributeList obj,
              info ~ ResolveAttribute attr obj,
              AttrInfo info,
              AttrBaseTypeConstraint info obj,
              AttrOpAllowed tag info obj,
              (AttrSetTypeConstraint info) b) =>
             AttrLabelProxy (attr :: Symbol) -> b -> AttrOp obj tag
    -- | Assign the result of an IO action to an attribute
    (:=>) :: (HasAttributeList obj,
              info ~ ResolveAttribute attr obj,
              AttrInfo info,
              AttrBaseTypeConstraint info obj,
              AttrOpAllowed tag info obj,
              (AttrSetTypeConstraint info) b) =>
             AttrLabelProxy (attr :: Symbol) -> IO b -> AttrOp obj tag
    -- | Apply an update function to an attribute
    (:~)  :: (HasAttributeList obj,
              info ~ ResolveAttribute attr obj,
              AttrInfo info,
              AttrBaseTypeConstraint info obj,
              tag ~ 'AttrSet,
              AttrOpAllowed 'AttrSet info obj,
              AttrOpAllowed 'AttrGet info obj,
              (AttrSetTypeConstraint info) b,
              a ~ (AttrGetType info)) =>
             AttrLabelProxy (attr :: Symbol) -> (a -> b) -> AttrOp obj tag
    -- | Apply an IO update function to an attribute
    (:~>) :: (HasAttributeList obj,
              info ~ ResolveAttribute attr obj,
              AttrInfo info,
              AttrBaseTypeConstraint info obj,
              tag ~ 'AttrSet,
              AttrOpAllowed 'AttrSet info obj,
              AttrOpAllowed 'AttrGet info obj,
              (AttrSetTypeConstraint info) b,
              a ~ (AttrGetType info)) =>
             AttrLabelProxy (attr :: Symbol) -> (a -> IO b) -> AttrOp obj tag
    -- | Assign a value to an attribute, allocating any necessary
    -- memory for representing the Haskell value as a C value. Note
    -- that it is the responsibility of the caller to make sure that
    -- the memory is freed when no longer used, otherwise there will
    -- be a memory leak. In the majority of cases you probably want to
    -- use ':=' instead, which has no potential memory leaks (at the
    -- cost of sometimes requiring some explicit Haskell -> C
    -- marshalling).
    (:&=) :: (HasAttributeList obj,
              info ~ ResolveAttribute attr obj,
              AttrInfo info,
              AttrBaseTypeConstraint info obj,
              AttrOpAllowed tag info obj,
              (AttrTransferTypeConstraint info) b,
              AttrSetTypeConstraint info (AttrTransferType info)) =>
             AttrLabelProxy (attr :: Symbol) -> b -> AttrOp obj tag
    -- | Connect the given signal to a signal handler.
    On    :: (GObject obj, SignalInfo info) =>
             SignalProxy obj info
          -> ((?self :: HaskellSignalOwner info) => HaskellCallbackType info)
          -> AttrOp obj tag
    -- | Like 'On', but connect after the default signal.
    After :: (GObject obj, SignalInfo info) =>
             SignalProxy obj info
          -> ((?self :: HaskellSignalOwner info) => HaskellCallbackType info)
          -> AttrOp obj tag

-- | Set a number of properties for some object.
set :: forall o m. MonadIO m => o -> [AttrOp o 'AttrSet] -> m ()
set obj = liftIO . mapM_ app
 where
   app :: AttrOp o 'AttrSet -> IO ()
   app ((_attr :: AttrLabelProxy label) :=  x) =
     attrSet @(ResolveAttribute label o) obj x

   app ((_attr :: AttrLabelProxy label) :=> x) =
     x >>= attrSet @(ResolveAttribute label o) obj

   app ((_attr :: AttrLabelProxy label) :~  f) =
     attrGet @(ResolveAttribute label o) obj >>=
     \v -> attrSet @(ResolveAttribute label o) obj (f v)

   app ((_attr :: AttrLabelProxy label) :~> f) =
     attrGet @(ResolveAttribute label o) obj >>= f >>=
     attrSet @(ResolveAttribute label o) obj

   app ((_attr :: AttrLabelProxy label) :&= x) =
     attrTransfer @(ResolveAttribute label o) (Proxy @o) x >>=
     attrSet @(ResolveAttribute label o) obj

   app (On signal callback) = void $ on obj signal callback
   app (After signal callback) = void $ after obj signal callback

-- | Constraints on a @obj@\/@attr@ pair so `get` is possible,
-- producing a value of type @result@.
type AttrGetC info obj attr result = (HasAttributeList obj,
                                      info ~ ResolveAttribute attr obj,
                                      AttrInfo info,
                                      (AttrBaseTypeConstraint info) obj,
                                      AttrOpAllowed 'AttrGet info obj,
                                      result ~ AttrGetType info)

-- | Get the value of an attribute for an object.
get :: forall info attr obj result m.
       (AttrGetC info obj attr result, MonadIO m) =>
        obj -> AttrLabelProxy (attr :: Symbol) -> m result
get o _ = liftIO $ attrGet @info o

-- | Constraint on a @obj@\/@attr@ pair so that `clear` is allowed.
type AttrClearC info obj attr = (HasAttributeList obj,
                                 info ~ ResolveAttribute attr obj,
                                 AttrInfo info,
                                 (AttrBaseTypeConstraint info) obj,
                                 AttrOpAllowed 'AttrClear info obj)

-- | Set a nullable attribute to @NULL@.
clear :: forall info attr obj m.
         (AttrClearC info obj attr, MonadIO m) =>
         obj -> AttrLabelProxy (attr :: Symbol) -> m ()
clear o _ = liftIO $ attrClear @info o
