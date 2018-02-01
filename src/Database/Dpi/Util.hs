{-# LANGUAGE BangPatterns           #-}
{-# LANGUAGE FlexibleContexts       #-}
{-# LANGUAGE FlexibleInstances      #-}
{-# LANGUAGE FunctionalDependencies #-}
{-# LANGUAGE InstanceSigs           #-}
{-# LANGUAGE MultiParamTypeClasses  #-}
{-# LANGUAGE OverloadedStrings      #-}
{-# LANGUAGE TupleSections          #-}
{-# LANGUAGE UndecidableInstances   #-}
module Database.Dpi.Util where

import           Database.Dpi.Internal
import           Database.Dpi.Prelude

import           Control.Exception
import qualified Data.Text             as T

{-# INLINE isOk #-}
isOk :: CInt -> Bool
isOk = (== success)

data DpiException
  = ErrorInfoException Data_ErrorInfo
  deriving Show

instance Exception DpiException

class WithPtrs a where
  withPtrs :: (a -> IO b) -> IO b

instance Storable a => WithPtrs (Ptr a) where
  withPtrs = alloca

instance (WithPtrs a, WithPtrs b) => WithPtrs (a, b) where
  withPtrs f = withPtrs $ \a -> withPtrs $ \b -> f (a,b)

class HasMonad m r | r -> m where
  app :: m a -> (a -> r) -> r
  unM :: m r -> r
  unM ma = app ma id

instance Monad m => HasMonad m (m a) where
  app = (>>=)

instance (HasMonad m r) => HasMonad m (a -> r) where
  app mb f = app mb . flip f

{-# INLINE inVar #-}
inVar :: a -> (a -> r) -> r
inVar = (&)

class ToString s where
  toString :: s -> String

instance ToString String where
  toString = id

instance ToString Text where
   toString = T.unpack

{-# INLINE inStr #-}
inStr :: (HasMonad IO r, ToString s) => s -> (CString -> r) -> r
inStr !text f = unM $ withCString (toString text) (return . f)

{-# INLINE inStrLen #-}
inStrLen :: (HasMonad IO r, ToString s, Integral n) => s -> (Ptr CChar -> n -> r) -> r
inStrLen !text f = unM $ withCStringLen (toString text) $ \(c,clen) -> return $ f c (fromIntegral clen)

{-# INLINE inInt #-}
inInt :: (Num n, Integral i) => i -> (n -> r) -> r
inInt !n f = f $ fromIntegral n

{-# INLINE inEnum #-}
inEnum :: (Enum e, Integral n) => e -> (n -> r) -> r
inEnum !e f = f $ fe e

{-# INLINE inBool #-}
inBool :: Integral n => Bool -> (n -> r) -> r
inBool !b f = f $ fromBool b

{-# INLINE inPtr #-}
inPtr :: (HasMonad IO r, Storable a) => (Ptr a -> IO b) -> (Ptr a -> r) -> r
inPtr init f = unM $ withPtrs $ \c -> init c >> return (f c)

{-# INLINE outBool #-}
outBool :: IO CInt -> IO Bool
outBool = (isOk <$>)

{-# INLINE setText #-}
setText :: (Ptr a -> Ptr CChar -> CUInt -> IO CInt) -> HasCxtPtr a -> Text -> IO Bool
setText f (cxt,p) !s = f p & inStrLen s & outBool

-- | Returns error information for the last error that was raised by the library.
-- This function must be called with the same thread that generated the error.
--  It must also be called before any other ODPI-C library calls are made on
-- the calling thread since the error information specific to that thread is cleared
--  at the start of every ODPI-C function call.
{-# INLINE getContextError #-}
getContextError :: PtrContext -> IO Data_ErrorInfo
getContextError !p = alloca $ \pe -> libContextGetError p pe >> peek pe

{-# INLINE throwContextError #-}
throwContextError :: HasCallStack => PtrContext -> IO a
throwContextError !cxt = getContextError cxt >>= throw . ErrorInfoException

{-# INLINE outValue #-}
outValue :: (WithPtrs a) => PtrContext -> (a -> IO b) -> (a -> IO CInt) -> IO b
outValue cxt ab = outValue' cxt ab return

{-# INLINE outValue' #-}
outValue' :: (WithPtrs a, HasCallStack) => PtrContext -> (a -> IO b) -> (a -> IO c) -> (a -> IO CInt) -> IO b
outValue' !cxt ab be lib = withPtrs $ \a -> do
  be a
  r <- lib a
  if isOk r then ab a else throwContextError cxt

{-# INLINE runIndex #-}
runIndex f !(cxt,p) = f p & out2Value cxt go
  where
    {-# INLINE go #-}
    go (pos,pin) = do
      ok <- peekBool pin
      if ok then Just <$> peekInt pos else return Nothing

{-# INLINE out2Value #-}
out2Value :: (Storable x, Storable y) => PtrContext -> ((Ptr x, Ptr y) -> IO b) -> (Ptr x -> Ptr y -> IO CInt) -> IO b
out2Value !cxt f g = outValue cxt f (uncurry g)

{-# INLINE out3Value #-}
out3Value
  :: (Storable x, Storable y, Storable z)
  => PtrContext -> (((Ptr x, Ptr y), Ptr z) -> IO b) -> (Ptr x -> Ptr y -> Ptr z -> IO CInt) -> IO b
out3Value !cxt f g = outValue cxt f (go g)
  where
    {-# INLINE go #-}
    go f ((x,y),z) = f x y z

{-# INLINE out4Value #-}
out4Value
  :: (Storable x, Storable y, Storable z, Storable w)
  => PtrContext -> (((Ptr x, Ptr y), (Ptr z,Ptr w)) -> IO b) -> (Ptr x -> Ptr y -> Ptr z -> Ptr w -> IO CInt) -> IO b
out4Value cxt f g = outValue cxt f (go g)
  where
    {-# INLINE go #-}
    go f ((x,y),(z,w)) = f x y z w

{-# INLINE runBool #-}
runBool :: (Ptr a -> IO CInt) -> (PtrContext, Ptr a) -> IO Bool
runBool f (_, !p) = isOk <$> f p

{-# INLINE runInt #-}
runInt :: (Storable i, Integral i, Integral n) => (Ptr a -> Ptr i -> IO CInt) -> HasCxtPtr a -> IO n
runInt f !p = fromIntegral <$> runVar f p

{-# INLINE runMaybeInt #-}
runMaybeInt :: (Storable i, Integral i, Integral n) => (Ptr a -> Ptr i -> IO CInt) -> HasCxtPtr a -> IO (Maybe n)
runMaybeInt f !p = fmap fromIntegral <$> runMaybeVar f p

{-# INLINE runText #-}
runText :: (Ptr a -> Ptr (Ptr CChar) -> Ptr CUInt -> IO CInt) -> HasCxtPtr a -> IO Text
runText f (cxt,!p) = f p & out2Value cxt peekCStrLen

{-# INLINE runVar #-}
runVar :: Storable i => (Ptr a -> Ptr i -> IO CInt) -> HasCxtPtr a -> IO i
runVar f (cxt,!p) = f p & outValue cxt peek

{-# INLINE runMaybeVar #-}
runMaybeVar :: Storable i => (Ptr a -> Ptr i -> IO CInt) -> HasCxtPtr a -> IO (Maybe i)
runMaybeVar f (cxt,!p) = f p & outValue cxt (mapM peek . toMaybePtr)

{-# INLINE peekWithCxt #-}
peekWithCxt :: Storable a => PtrContext -> Ptr a -> IO (PtrContext, a)
peekWithCxt cxt !p = (cxt,) <$> peek p

{-# INLINE peekInt #-}
peekInt :: (Num n, Integral a, Storable a) => Ptr a -> IO n
peekInt !p = fromIntegral <$> peek p

{-# INLINE peekBool #-}
peekBool :: Ptr CInt -> IO Bool
peekBool !p = isOk <$> peek p

{-# INLINE peekEnum #-}
peekEnum :: (Enum e,Storable i, Integral i) => Ptr i -> IO e
peekEnum !p = te <$> peek p

-- peekCStrLen

{-# INLINE peekCStrLen #-}
peekCStrLen :: (Ptr (Ptr CChar), Ptr CUInt) -> IO Text
peekCStrLen (!p,!plen) = join $ ts <$> peek p <*> peek plen

{-# INLINE _get #-}
_get :: NativeTypeNum -> PtrData -> IO DataValue
_get !t !p = do
  Data !get <- peek p
  get t
