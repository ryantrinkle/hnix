{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}

module EvalTests (tests) where

import           Control.Monad.Trans.State
import           Data.Fix
import qualified Data.Map as Map
import           Data.String.Interpolate
import           Nix.Builtins
import           Nix.Eval
import           Nix.Expr
import           Nix.Parser
import           Test.Tasty
import           Test.Tasty.HUnit
import           Test.Tasty.TH

case_basic_sum =
    constantEqualStr "2" "1 + 1"

case_basic_function =
    constantEqualStr "2" "(a: a) 2"

case_set_attr =
    constantEqualStr "2" "{ a = 2; }.a"

case_function_set_arg =
    constantEqualStr "2" "({ a }: 2) { a = 1; }"

case_function_set_two_arg =
    constantEqualStr "2" "({ a, b ? 3 }: b - a) { a = 1; }"

case_function_set_two_arg_default_scope =
    constantEqualStr "2" "({ x ? 1, y ? x * 3 }: y - x) {}"

case_function_default_env =
    constantEqualStr "2" "let default = 2; in ({ a ? default }: a) {}"

case_function_definition_uses_environment =
    constantEqualStr "3" "let f = (let a=1; in x: x+a); in f 2"

case_function_atpattern =
    constantEqualStr "2" "(({a}@attrs:attrs) {a=2;}).a"

case_function_ellipsis =
    constantEqualStr "2" "(({a, ...}@attrs:attrs) {a=0; b=2;}).b"

case_function_default_value_in_atpattern =
    constantEqualStr "2" "({a ? 2}@attrs:attrs.a) {}"

case_function_recursive_args =
    constantEqualStr "2" "({ x ? 1, y ? x * 3}: y - x) {}"

case_function_recursive_sets =
    constantEqualStr "[ [ 6 4 100 ] 4 ]" [i|
        let x = rec {

          y = 2;
          z = { w = 4; };
          v = rec {
            u = 6;
            t = [ u z.w s ];
          };

        }; s = 100; in [ x.v.t x.z.w ]
    |]

-----------------------

tests :: TestTree
tests = $testGroupGenerator

instance (Show r, Eq r) => Eq (NValueF m r) where
    NVConstant x == NVConstant y = x == y
    NVList x == NVList y = and (zipWith (==) x y)
    x == y = error $ "Need to add comparison for values: "
                 ++ show x ++ " == " ++ show y

constantEqual :: NExpr -> NExpr -> Assertion
constantEqual a b = do
    a' <- evaluate a
    b' <- evaluate b
    assertEqual "" a' b'
  where
    run expr = evalStateT (runCyclic expr)

    evaluate expr = do
        base  <- run baseEnv Map.empty
        expr' <- tracingExprEval expr
        thnk  <- run expr' base
        run (normalForm thnk) base

constantEqualStr :: String -> String -> Assertion
constantEqualStr a b =
  let Success a' = parseNixString a
      Success b' = parseNixString b
  in constantEqual a' b'
