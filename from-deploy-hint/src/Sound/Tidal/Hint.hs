module Sound.Tidal.Hint where

import           Control.Exception
import           Language.Haskell.Interpreter as Hint
import           Language.Haskell.Interpreter.Unsafe as Hint
import           Sound.Tidal.Context
import           System.IO
import           Control.Concurrent.MVar
import           Data.List (intercalate,isPrefixOf)
import           Sound.Tidal.Utils

data Response = HintOK {parsed :: ControlPattern}
              | HintError {errorMessage :: String}

instance Show Response where
  show (HintOK p)    = "Ok: " ++ show p
  show (HintError s) = "Error: " ++ s

runJob :: String -> IO (Response)
runJob job = do putStrLn $ "Parsing: " ++ job
                result <- hintControlPattern job
                let response = case result of
                      Left err -> HintError (show err)
                      Right p -> HintOK p
                return response

libs = [
    "Sound.Tidal.Context"
  , "Sound.Tidal.Simple"
  , "Control.Applicative"
  , "Data.Bifunctor"
  , "Data.Bits"
  , "Data.Bool"
  , "Data.Char"
  , "Data.Either"
  , "Data.Foldable"
  , "Data.Function"
  , "Data.Functor"
  , "Data.Int"
  , "Data.List"
  , "Data.Map"
  , "Data.Maybe"
  , "Data.Monoid"
  , "Data.Ord"
  , "Data.Ratio"
  , "Data.Semigroup"
  , "Data.String"
  , "Data.Traversable"
  , "Data.Tuple"
  , "Data.Typeable"
  , "GHC.Float"
  , "GHC.Real"
  ]

libdir = "/haskell-libs"

exts = [OverloadedStrings, NoImplicitPrelude]

hintControlPattern  :: String -> IO (Either InterpreterError ControlPattern)
hintControlPattern s = Hint.runInterpreter $ do
  Hint.set [languageExtensions := exts]
  Hint.setImports libs
  Hint.interpret s (Hint.as :: ControlPattern)

hintJob  :: MVar String -> MVar Response -> IO ()
hintJob mIn mOut =
  do result <- catch (do Hint.unsafeRunInterpreterWithArgsLibdir [] libdir $ do
                           Hint.set [languageExtensions := exts]
                           Hint.setImports libs
                           hintLoop
                     )
               (\e -> return (Left $ UnknownError $ "exception" ++ show (e :: SomeException)))
     let response = case result of
          Left err -> HintError (parseError err)
          Right p  -> HintOK p -- can happen
         parseError (UnknownError s) = "Unknown error: " ++ s
         parseError (WontCompile es) = "Compile error: " ++ (intercalate "\n" (Prelude.map errMsg es))
         parseError (NotAllowed s) = "NotAllowed error: " ++ s
         parseError (GhcException s) = "GHC Exception: " ++ s

     takeMVar mIn
     putMVar mOut response
     hintJob mIn mOut
     where hintLoop = do s <- liftIO (readMVar mIn)
                         let munged = deltaMini s
                         t <- Hint.typeChecksWithDetails munged
                         interp t munged
                         hintLoop
           interp (Left errors) _ = do liftIO $ do putMVar mOut $ HintError $ "Didn't typecheck " ++ concatMap show errors
                                                   hPutStrLn stderr $ "error: " ++ concatMap show errors
                                                   takeMVar mIn
                                       return ()
           interp (Right t) s =
             do p <- Hint.interpret s (Hint.as :: ControlPattern)
                liftIO $ putMVar mOut $ HintOK p
                liftIO $ takeMVar mIn
                return ()
