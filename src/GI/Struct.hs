module GI.Struct ( genStructOrUnionFields
                 , genZeroStruct
                 , genZeroUnion
                 , extractCallbacksInStruct
                 , fixAPIStructs
                 , ignoreStruct)
    where

#if !MIN_VERSION_base(4,8,0)
import Control.Applicative ((<$>))
#endif
import Control.Monad (forM_, when)

import Data.Maybe (mapMaybe, isJust)
import Data.Text (Text)
import qualified Data.Text as T

import GI.API
import GI.Conversions
import GI.Code
import GI.SymbolNaming
import GI.Type
import GI.Util

-- | Whether (not) to generate bindings for the given struct.
ignoreStruct :: Name -> Struct -> Bool
ignoreStruct (Name _ name) s = isJust (gtypeStructFor s) ||
                               "Private" `T.isSuffixOf` name

-- | Canonical name for the type of a callback type embedded in a
-- struct field.
fieldCallbackType :: Text -> Field -> Text
fieldCallbackType structName field =
    structName <> (underscoresToCamelCase . fieldName) field <> "FieldCallback"

-- | Fix the interface names of callback fields in the struct to
-- correspond to the ones that we are going to generate.
fixCallbackStructFields :: Name -> Struct -> Struct
fixCallbackStructFields (Name ns structName) s = s {structFields = fixedFields}
    where fixedFields :: [Field]
          fixedFields = map fixField (structFields s)

          fixField :: Field -> Field
          fixField field =
              case fieldCallback field of
                Nothing -> field
                Just _ -> let n' = fieldCallbackType structName field
                          in field {fieldType = TInterface ns n'}

-- | Fix the interface names of callback fields in an APIStruct to
-- correspond to the ones that we are going to generate. If something
-- other than an APIStruct is passed in we don't touch it.
fixAPIStructs :: (Name, API) -> (Name, API)
fixAPIStructs (n, APIStruct s) = (n, APIStruct $ fixCallbackStructFields n s)
fixAPIStructs api = api

-- | Extract the callback types embedded in the fields of structs, and
-- at the same time fix the type of the corresponding fields. Returns
-- the list of APIs associated to this struct, not including the
-- struct itself.
extractCallbacksInStruct :: (Name, API) -> [(Name, API)]
extractCallbacksInStruct (n@(Name ns structName), APIStruct s)
    | ignoreStruct n s = []
    | otherwise =
        mapMaybe callbackInField (structFields s)
            where callbackInField :: Field -> Maybe (Name, API)
                  callbackInField field = do
                    callback <- fieldCallback field
                    let n' = fieldCallbackType structName field
                    return (Name ns n', APICallback callback)
extractCallbacksInStruct _ = []

-- | Extract a field from a struct.
buildFieldReader :: Text -> Name -> Field -> ExcCodeGen ()
buildFieldReader getter n field = group $ do
  name' <- upperName n

  hType <- tshow <$> haskellType (fieldType field)
  fType <- tshow <$> foreignType (fieldType field)

  line $ getter <> " :: MonadIO m => " <> name' <> " -> m " <>
              if T.any (== ' ') hType
              then parenthesize hType
              else hType
  line $ getter <> " s = liftIO $ withManagedPtr s $ \\ptr -> do"
  indent $ do
    line $ "val <- peek (ptr `plusPtr` " <> tshow (fieldOffset field)
         <> ") :: IO " <> if T.any (== ' ') fType
                         then parenthesize fType
                         else fType
    result <- convert "val" $ fToH (fieldType field) TransferNothing
    line $ "return " <> result

buildFieldAttributes :: Name -> Field -> ExcCodeGen (Maybe (Text, Text))
buildFieldAttributes n field
    | not (fieldVisible field) = return Nothing
    | otherwise = do
  name' <- upperName n

  hType <- tshow <$> haskellType (fieldType field)
  if ("Private" `T.isSuffixOf` hType ||
     not (fieldVisible field))
  then return Nothing
  else do
     let fName = (underscoresToCamelCase . fieldName) field
         getter = lcFirst name' <> "Read" <> ucFirst fName

     buildFieldReader getter n field

     exportProperty fName getter

     return Nothing

genStructOrUnionFields :: Name -> [Field] -> CodeGen ()
genStructOrUnionFields n fields = do
  name' <- upperName n

  _ <- forM_ fields $ \field ->
      handleCGExc (\e -> line ("-- XXX Skipped attribute for \"" <> name' <>
                               ":" <> fieldName field <> "\" :: " <>
                               describeCGError e) >>
                   return Nothing)
                  (buildFieldAttributes n field)

  line $ "type instance AttributeList " <> name' <> " = '[]"


-- | Generate a constructor for a zero-filled struct/union of the given
-- type, using the boxed (or GLib, for unboxed types) allocator.
genZeroSU :: Name -> Int -> Bool -> CodeGen ()
genZeroSU n size isBoxed =
    when (size /= 0) $ group $ do
      name <- upperName n
      let builder = "newZero" <> name
          tsize = tshow size
      line $ "-- | Construct a `" <> name <> "` struct initialized to zero."
      line $ builder <> " :: MonadIO m => m " <> name
      line $ builder <> " = liftIO $ " <>
           if isBoxed
           then "callocBoxedBytes " <> tsize <> " >>= wrapBoxed " <> name
           else "callocBytes " <> tsize <> " >>= wrapPtr " <> name
      exportDecl builder

      blank

      -- Overloaded "new"
      group $ do
        line $ "instance tag ~ 'AttrSet => Constructible " <> name <> " tag where"
        indent $ do
           line $ "new _ attrs = do"
           indent $ do
              line $ "o <- " <> builder
              line $ "GI.Attributes.set o attrs"
              line $ "return o"

-- | Specialization for structs of `genZeroSU`.
genZeroStruct :: Name -> Struct -> CodeGen ()
genZeroStruct n s = genZeroSU n (structSize s) (structIsBoxed s)

-- | Specialization for unions of `genZeroSU`.
genZeroUnion :: Name -> Union -> CodeGen ()
genZeroUnion n u = genZeroSU n (unionSize u) (unionIsBoxed u)
