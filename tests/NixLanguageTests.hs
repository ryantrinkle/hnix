{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module NixLanguageTests (genTests) where

import           Control.Arrow ((&&&))
import           Control.Exception
import           Control.Monad.Trans.State
import           Data.List (delete, sort)
import           Data.List.Split (splitOn)
import           Data.Map (Map)
import qualified Data.Map as Map
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import           GHC.Exts
import           Nix.Builtins
import           Nix.Eval
import           Nix.Parser
import           Nix.Pretty
import           System.FilePath.Glob (compile, globDir1)
import           System.FilePath.Posix
import           Test.Tasty
import           Test.Tasty.HUnit

{-
From (git://nix)/tests/lang.sh we see that

    lang/parse-fail-*.nix -> parsing should fail
    lang/parse-okay-*.nix -> parsing should succeed
    lang/eval-fail-*.nix -> eval should fail

    lang/eval-okay-*.{nix,xml} -> eval should succeed,
        xml dump should be the same as the .xml
    lang/eval-okay-*.{nix,exp} -> eval should succeed,
        plain text output should be the same as the .exp
    lang/eval-okay-*.{nix,exp,flags} -> eval should succeed,
        plain text output should be the same as the .exp,
        pass the extra flags to nix-instantiate

    NIX_PATH=lang/dir3:lang/dir4 should be in the environment of all eval-okay-*.nix evaluations
    TEST_VAR=foo should be in all the environments # for eval-okay-getenv.nix
-}


groupBy :: Ord k => (v -> k) -> [v] -> Map k [v]
groupBy key = Map.fromListWith (++) . map (key &&& pure)

genTests :: IO TestTree
genTests = do
  testFiles <- sort . filter ((/= ".xml") . takeExtension)
      <$> globDir1 (compile "*-*-*.*") "data/nix/tests/lang"
  let testsByName = groupBy takeBaseName testFiles
  let testsByType = groupBy testType (Map.toList testsByName)
  let testGroups  = map mkTestGroup (Map.toList testsByType)
  return $ localOption (mkTimeout 100000)
         $ testGroup "Nix (upstream) language tests" testGroups
  where
    testType (fullpath, _files) = take 2 $ splitOn "-" $ takeFileName fullpath
    mkTestGroup (kind, tests) =
        testGroup (unwords kind) $ map (mkTestCase kind) tests
    mkTestCase kind (basename, files) =
        testCase (takeFileName basename) $ case kind of
            ["parse", "okay"] -> assertParse $ the files
            ["parse", "fail"] -> assertParseFail $ the files
            ["eval", "okay"] -> assertEval files
            ["eval", "fail"] -> assertEvalFail $ the files

assertParse :: FilePath -> Assertion
assertParse file = parseNixFile file >>= \case
  Success expr -> do
      base <- run baseEnv Map.empty
      run (checkExpr expr) base
  Failure err -> assertFailure $ "Failed to parse " ++ file ++ ":\n" ++ show err
  where
    run expr = evalStateT (runCyclic expr)

assertParseFail :: FilePath -> Assertion
assertParseFail file = do
    eres <- parseNixFile file
    catch (case eres of
               Success expr -> do
                   base <- run baseEnv Map.empty
                   run (checkExpr expr) base
                   assertFailure $ "Unexpected success parsing `"
                       ++ file ++ ":\nParsed value: " ++ show expr
               Failure _ -> return ()) $ \(_ :: SomeException) ->
        return ()
  where
    run expr = evalStateT (runCyclic expr)

assertLangOk :: FilePath -> Assertion
assertLangOk file = do
  actual <- printNix <$> nixEvalFile (file ++ ".nix")
  expected <- Text.readFile $ file ++ ".exp"
  seq actual $ seq expected $
      assertEqual "" expected $ Text.pack (actual ++ "\n")

assertLangOkXml :: FilePath -> Assertion
assertLangOkXml name = assertFailure $ "Not implemented: " ++ name

assertEval :: [FilePath] -> Assertion
assertEval files =
  case delete ".nix" $ sort $ map takeExtension files of
    [] -> assertLangOkXml name
    [".exp"] -> assertLangOk name
    [".exp-disabled"] -> return ()
    [".exp", ".flags"] -> assertFailure $ "Support for flags not implemented (needed by " ++ name ++ ".nix)."
    _ -> assertFailure $ "Unknown test type " ++ show files
  where
    name = "data/nix/tests/lang/" ++ the (map takeBaseName files)

assertEvalFail :: FilePath -> Assertion
assertEvalFail file = catch eval (\(ErrorCall _) -> return ())
  where
    eval = do
      evalResult <- printNix <$> nixEvalFile file
      evalResult `seq` assertFailure $ file ++ " should not evaluate.\nThe evaluation result was `" ++ evalResult ++ "`."

nixEvalFile :: FilePath -> IO (NValueNF (Cyclic IO))
nixEvalFile file =  do
  parseResult <- parseNixFile file
  case parseResult of
    Failure err        -> error $ "Parsing failed for file `" ++ file ++ "`.\n" ++ show err
    Success expression -> evalTopLevelExprIO expression
