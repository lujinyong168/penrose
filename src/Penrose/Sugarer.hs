-- This module get as an input a Substance program (a text) and preform a
-- textual replacement of all the statement notation specified in the Element
-- environment / the Element AST, the result is a semi-sugared Substance program
-- which will be passed to the Substance parser
{-# OPTIONS_HADDOCK prune #-}

module Penrose.Sugarer
  ( sugarStmts
  ) where

--module Main (main) where -- for debugging purposes
import           Control.Arrow                  ((>>>))
import           Control.Monad                  (void)
import           Control.Monad.Combinators.Expr
import           Data.List
import           Data.List.Split
import           Data.Maybe
import           Data.Typeable
import           Data.Void
import           Debug.Trace
import           Penrose.Env
import           Penrose.Util
import           System.Environment
import           System.IO
import           System.Process
import           Text.Megaparsec
import           Text.Megaparsec.Char

import qualified Data.Map.Strict                as M
import qualified Penrose.Element                as D
import qualified Penrose.SubstanceTokenizer     as T
import qualified Penrose.Tokenizer              as Tokenizer
import qualified Text.Megaparsec.Char.Lexer     as L

-------------------------------- Sugaring --------------------------------------
-- | The top-level function for translating StmtNotations, gets as an input String of
--   sugared program + the Element env, and returns a string of desugared program.
--   All the NotationStmts are stored in elementEnv.
sugarStmts :: String -> VarEnv -> String
sugarStmts prog elementEnv =
  let notations = stmtNotations elementEnv
      tokenizedProg = Tokenizer.tokenizeSugaredSubstance prog elementEnv
      str =
        foldl
          (sugarStmt elementEnv)
          (filter Tokenizer.spaces tokenizedProg)
          notations
  in Tokenizer.reTokenize str

-- | Preform a replacement of a specific given StmtNotationRule over
--   a list of tokens.
sugarStmt :: VarEnv -> [T.Token] -> StmtNotationRule -> [T.Token]
sugarStmt elementEnv tokens rule =
  let from = fromSnr rule
      to = toSnr rule
      patterns = patternsSnr rule
  in if isRecursivePattern to
       then handleRecursivePattern from to patterns tokens
       else handleNonRecursivePattern from to patterns tokens

-- | Handle a specific recursive pattern, as part of handling recursive patterns
--  we need to refine the sugared substance tokens list to recognize recursive
--  patterns before the actual split
handleRecursivePattern from to patterns tokens =
  let c = groupBy cmpSubst tokens
      c' = concat (foldl replaceToRecursivePattern [] c)
      c'' = split (onSublist (filter Tokenizer.spaces to)) c'
      splittedReplaced = concat (foldl (replace from to patterns) [] c'')
      recursivePattern = foldl findRecursivePattern [] splittedReplaced
      final =
        foldl
          (replaceToRecursivePatternElement recursivePattern)
          []
          splittedReplaced
  in (traceShowId final)

replaceToRecursivePatternElement recursivePattern lst (T.RecursivePatternElement p) =
  lst ++ p
replaceToRecursivePatternElement recursivePattern lst t = lst ++ [t]

findRecursivePattern lst (T.RecursivePattern p) = lst ++ p
findRecursivePattern lst _                      = lst

cmpSubst :: T.Token -> T.Token -> Bool
cmpSubst (T.Pattern _ _) T.Comma = True
cmpSubst a b                     = a == b

replaceToRecursivePattern :: [[T.Token]] -> [T.Token] -> [[T.Token]]
replaceToRecursivePattern lst subSeq =
  if length subSeq > 1 &&
     (head $ tail subSeq) == T.Comma && head subSeq == T.Pattern "" False
    then lst ++ [[T.RecursivePattern subSeq]]
    else lst ++ [subSeq]

-- | Handle non recursive patterns
handleNonRecursivePattern from to patterns tokens =
  let splitted = split (onSublist (filter Tokenizer.spaces to)) tokens
      splittedReplaced = foldl (replace from to patterns) [] splitted
  in concat splittedReplaced

isRecursivePattern :: [T.Token] -> Bool
isRecursivePattern tokens = T.RecursivePattern [] `elem` tokens

-- Preform the actual replacement of a pattern
replace ::
     [T.Token]
  -> [T.Token]
  -> [T.Token]
  -> [[T.Token]]
  -> [T.Token]
  -> [[T.Token]]
replace from to patterns lst chunk =
  if comparePattern to chunk patterns
    then let patternMatch =
               zip
                 (filter Tokenizer.notAllPatterns to)
                 (filter Tokenizer.notAllPatterns chunk)
             from' =
               foldl
                 updateValue
                 from
                 (patternMatch ++
                  [(T.RecursivePatternElement [], T.RecursivePatternElement [])])
         in lst ++ [from']
    else lst ++ [chunk]

-- | Replace elements in the token list according to the pattern match, make
--   sure that each element is replaced at most one time, in order to avoid
--   collisions
replaceElement (T.Pattern p1 b1) (T.Pattern p2 b2) (T.Pattern x b3) =
  if p1 == x && not b3
    then T.Pattern p2 True
    else T.Pattern x b3
replaceElement (T.RecursivePattern p1) (T.RecursivePattern p2) (T.RecursivePattern x) =
  T.RecursivePattern p2
replaceElement (T.RecursivePatternElement p1) (T.RecursivePatternElement p2) (T.RecursivePatternElement x) =
  T.RecursivePatternElement x
replaceElement p1 p2 x = x

updateValue :: [T.Token] -> (T.Token, T.Token) -> [T.Token]
updateValue from patternMatch = map (uncurry replaceElement patternMatch) from

-- | Compare 2 patterns
comparePattern :: [T.Token] -> [T.Token] -> [T.Token] -> Bool
comparePattern to chunk patterns =
  let chunk' = (filter Tokenizer.newLines (filter Tokenizer.spaces chunk))
      to' = (filter Tokenizer.spaces to)
  in ((length chunk' == length to') && all compareElements (zip chunk' to'))

compareElements :: (T.Token, T.Token) -> Bool
compareElements (T.Var a, T.Pattern b _)                            = True
compareElements (T.Entitiy a, T.Pattern b _)                        = True
compareElements (T.Pattern b _, T.Entitiy a)                        = True
compareElements (T.RecursivePattern _, T.RecursivePattern _)        = True
compareElements (T.RecursivePatternElement _, T.RecursivePattern _) = True
compareElements (T.RecursivePattern _, T.RecursivePatternElement _) = True
compareElements (a, b)                                              = a == b

------------------------------ Test Driver -------------------------------------
-- | For testing: first uncomment the module definition to make this module the
-- Main module. Usage: ghc Sugarer.hs; ./Sugarer <element-file> <substance-file>
main :: IO ()
main = do
  [elementFile, substanceFile] <- getArgs
  elementIn <- readFile elementFile
  let elementRes = D.parseElement elementFile elementIn
  case elementRes of
    Right elementEnv -> do
      substanceIn <- readFile substanceFile
      putStrLn "Tokenized Sugared Substance: \n"
      -- print(sugarStmts substanceIn elementEnv)
      writeFile
        "syntacticSugarExamples/output"
        (sugarStmts substanceIn elementEnv)
      return ()
    Left e -> error $ "Element compilation error: " ++ show e
