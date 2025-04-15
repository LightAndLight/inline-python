{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes       #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# LANGUAGE TypeFamilies      #-}
-- |
-- Definition of data types used by inline-python. They are moved to
-- separate module since some are required for @inline-c@'s context
-- and we need context for
module Python.Internal.Types
  ( -- * Data type
    PyObject(..)
  , unsafeWithPyObject
  , PyThreadState
  , PyError(..)
  , PyException(..)
  , PyInternalError(..)
  , Py(..)
  , pyIO
    -- * inline-C
  , pyCtx
    -- * Patterns
  , pattern IPY_OK
  , pattern IPY_ERR_COMPILE
  , pattern IPY_ERR_PYTHON
  , pattern NULL
  , pattern FALSE
  , pattern TRUE
  ) where

import Control.Monad.IO.Class
import Control.Monad.Catch
import Control.Monad.Primitive (PrimMonad(..),RealWorld)
import Control.Exception
import Data.Coerce
import Data.Int
import Data.Map.Strict             qualified as Map
import Foreign.Ptr
import Foreign.C.Types
import GHC.ForeignPtr

import Language.C.Types
import Language.C.Inline.Context


----------------------------------------------------------------
-- Primitives
----------------------------------------------------------------

-- | Pointer tag
data PyThreadState

-- | Some python object. Since almost everything in python is mutable
--   it could only be accessed only in IO monad.
newtype PyObject = PyObject (ForeignPtr PyObject)
  deriving stock Show

unsafeWithPyObject :: forall a. PyObject -> (Ptr PyObject -> Py a) -> Py a
unsafeWithPyObject = coerce (unsafeWithForeignPtr @PyObject @a)

-- | Python exception converted to haskell.
data PyError
  = PyError !PyException
    -- ^ Python exception. Contains exception type and message as strings.
  | BadPyType
    -- ^ It's not possible to convert given python value to a haskell
    --   value
  | OutOfRange
    -- ^ Data type is suitable but value is outside of allowed
    --   range. For example attempting to convert 1000 to @Word8@ will
    --   result in this exception.
  | PyInitializationFailed
    -- ^ Initialization of python interpreter failed
  | PythonNotInitialized
    -- ^ Python interpreter is not initialized
  | PythonIsFinalized
    -- ^ Python interpreter is not initialized    
  deriving stock    (Show)
  deriving anyclass (Exception)

-- | Python exception converted to haskell value
data PyException = PyException
  { ty        :: !String   -- ^ Exception type as a string
  , str       :: !String   -- ^ String representation of an exception
  , exception :: !PyObject -- ^ Exception object
  }
  deriving stock Show

-- | Internal error. If this exception is thrown it means there's bug
--   in a library.
data PyInternalError = PyInternalError String
  deriving stock    (Show)
  deriving anyclass (Exception)

-- | Monad for code which is interacts with python interpreter. Only
--   one haskell thread can interact with python interpreter at a
--   time. Function that execute @Py@ make sure that this invariant is
--   held. Also note that all code in @Py@ monad is executed with
--   asynchronous exception masked, but 'liftIO' removes mask.
newtype Py a = Py (IO a)
  -- See NOTE: [Python and threading]
  deriving newtype (Functor,Applicative,Monad,MonadFail,
                    MonadThrow,MonadCatch,MonadMask)

-- | Inject @IO@ into @Py@ monad without changing masking state
--   (unlike 'liftIO')
pyIO :: IO a -> Py a
pyIO = Py

-- | Removes exception masking
instance MonadIO Py where
  liftIO = Py . interruptible

instance PrimMonad Py where
  type PrimState Py = RealWorld
  primitive = Py . primitive
  {-# INLINE primitive #-}


----------------------------------------------------------------
-- inline-C
----------------------------------------------------------------

-- | @inline-c@ context for mapping
pyCtx :: Context
pyCtx = mempty { ctxTypesTable = Map.fromList tytabs } where
  tytabs =
    [ ( TypeName "PyObject",      [t| PyObject      |])
    , ( TypeName "PyThreadState", [t| PyThreadState |])
    , ( TypeName "PyCFunction"
      , [t| FunPtr (Ptr PyObject -> Ptr PyObject -> IO (Ptr PyObject)) |])
    , ( TypeName "PyCFunctionFast"
      , [t| FunPtr (Ptr PyObject -> Ptr (Ptr PyObject) -> Int64 -> IO (Ptr PyObject)) |])
    ]


----------------------------------------------------------------
-- Patterns
----------------------------------------------------------------

pattern IPY_OK, IPY_ERR_PYTHON, IPY_ERR_COMPILE :: CInt
-- | Success
pattern IPY_OK          = 0
-- | Python exception raised
pattern IPY_ERR_PYTHON  = 1
-- | Error while compiling python source to byte code. Normally it
--   shouldn't happen.
pattern IPY_ERR_COMPILE = 2


pattern NULL :: Ptr a
pattern NULL <- ((== nullPtr) -> True) where
  NULL = nullPtr

pattern FALSE :: CInt
pattern FALSE = 0

pattern TRUE :: CInt
pattern TRUE <- ((/= 0) -> True)
