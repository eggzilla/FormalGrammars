{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RecordWildCards #-}
{- LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

-- | We define a simple domain-specific language for context-free languages.

module FormalLanguage.Parser where

import           Control.Applicative
import           Control.Arrow
import           Control.Lens
import           Control.Monad.Identity
import           Control.Monad.State.Class
import           Control.Monad.Trans.Class
import           Control.Monad.Trans.State.Strict
import           Data.Default
import           Data.Either
import           Data.List (partition)
import qualified Data.ByteString.Char8 as B
import qualified Data.HashSet as H
import qualified Data.Map as M
import qualified Data.Set as S
import           Text.Parser.Expression
import           Text.Parser.Token.Highlight
import           Text.Parser.Token.Style
import           Text.Printf
import           Text.Trifecta
import           Text.Trifecta.Delta
import           Text.Trifecta.Result

import FormalLanguage.Grammar

data Enumerated
  = Sing
  | ZeroBased Integer
  | Enum      [String]
  deriving (Show)

-- | The 

data GrammarState = GrammarState
  { _nsys         :: M.Map String Enumerated
  , _tsys         :: S.Set String
  , _grammarNames :: S.Set String
  }
  deriving (Show)

instance Default GrammarState where
  def = GrammarState
          { _nsys = def
          , _tsys = def
          , _grammarNames = def
          }

makeLenses ''GrammarState

-- | Parse a single grammar.

grammar :: Parse Grammar
grammar = do
  reserveGI "Grammar:"
  name :: String <- identGI
  (_nsyms,_tsyms) <- ((S.fromList *** S.fromList) . partitionEithers . concat)
                  <$> some (map Left <$> nts <|> map Right <$> ts)
  _start <- startSymbol
  _rules <- (S.fromList . concat) <$> some rule
  reserveGI "//"
  grammarNames <>= S.singleton name
  return Grammar { .. }

-- | Start symbol. Only a single symbol may be given
--
-- TODO for indexed symbols make sure we actually have one index to start with.

startSymbol :: Parse Symb
startSymbol = do
  reserveGI "S:"
  name :: String <- identGI
  -- TODO go and allow indexed NTs as start symbols, with one index given
  -- return $ nsym1 name Singular
  return $ Symb [N name Singular]

-- | The non-terminal declaration "NT: ..." returns a list of non-terms as
-- indexed non-terminals are expanded.

nts :: Parse [Symb]
nts = do
  reserveGI "NT:"
  name   <- identGI
  enumed <- option Sing $ braces enumeration
  let zs = expandNT name enumed
  nsys <>= M.singleton name enumed
  return zs

-- | expand set of non-terminals based on type of enumerations

expandNT :: String -> Enumerated -> [Symb]
expandNT name = go where
  go Sing          = [Symb [N name Singular]]
  go (ZeroBased k) = [Symb [N name (IntBased   z [0..(k-1)])] | z <- [0..(k-1)]]
  go (Enum es)     = [Symb [N name (Enumerated z es        )] | z <- es        ]

-- | Figure out if we are dealing with indexed (enumerable) non-terminals

enumeration =   ZeroBased <$> natural
            <|> Enum      <$> sepBy1 identGI (string ",")

-- | Parse declared terminal symbols.

ts :: Parse [Symb]
ts = do
  reserveGI "T:"
  n <- identGI
  let z = Symb [T n]
  tsys <>= S.singleton n
  return [z]

-- | Parse a single rule. Some rules come attached with an index. In that case,
-- each rule is inflated according to its modulus (or more general the set of
-- indices indicated.
--
-- TODO add @fun@ to each PR
--
-- TODO expand NT on left-hand side with all variants based on index.

rule :: Parse [Rule]
rule = do
  lhsN <- identGI <?> "rule: lhs non-terminal"
  nsys `uses` (M.member    lhsN) >>= guard <?> (printf "undeclared NT: %s" lhsN)
  tsys `uses` (S.notMember lhsN) >>= guard <?> (printf "terminal on LHS: %s" lhsN)
  --i <- nTindex
  reserveGI "->"
  fun :: String <- identGI
  reserveGI "<<<"
  zs <- fmap sequence . runUnlined $ some (try ruleNts <|> try ruleTs) -- expand zs to all production rules
  whiteSpace
  return [Rule (Symb [N lhsN Singular]) (Fun fun) z | z <- zs]

-- | Parse non-terminal symbols in production rules. If we have an indexed
-- non-terminal, more than one result will be returned.
--
-- TODO expand with indexed version

ruleNts :: ParseU [Symb] -- (String,NtIndex)
ruleNts = do
  n <- identGI <?> "rule: nonterminal identifier"
--  i <- nTindex <?> "rule:" -- option ("",1) $ braces ((,) <$> ident gi <*> option 0 integer) <?> "rule: nonterminal index"
  lift $ nsys `uses` (M.member n   ) >>= guard <?> (printf "undeclared NT: %s" n)
  lift $ tsys `uses` (S.notMember n) >>= guard <?> (printf "used terminal in NT role: %s" n)
  return [Symb [N n Singular]] -- [nsym1 n Singular] -- (n,i)

-- | Parse terminal symbols in production rules. Returns singleton list of
-- terminal.

ruleTs :: ParseU [Symb]
ruleTs = do
  n <- identGI <?> "rule: terminal identifier"
  lift $ tsys `uses` (S.member n   ) >>= guard <?> (printf "undeclared T: %s" n)
  lift $ nsys `uses` (M.notMember n) >>= guard <?> (printf "used non-terminal in T role: %s" n)
  return [Symb [T n]] -- [TSym [n]]

-- * Monadic Parsing Machinery

-- | Parser with 'GrammarState'

newtype GrammarParser m a = GrammarP { runGrammarP :: StateT GrammarState m a }
  deriving  ( Monad
            , MonadPlus
            , Alternative
            , Applicative
            , Functor
            , MonadState GrammarState
            , TokenParsing
            , CharParsing
            , Parsing
            , MonadTrans
            )

-- | Functions that parse using the 'GrammarParser'

type Parse  a = ( Monad m
                , MonadPlus m
                , TokenParsing m
                ) => GrammarParser m a

-- | Parsing where we stop at a newline (which needs to be parsed explicitly)

type ParseU a = (Monad m
                , MonadPlus m
                , TokenParsing m
                ) => Unlined (GrammarParser m) a

-- | grammar identifiers

grammarIdentifiers = set styleReserved rs emptyIdents where
  rs = H.fromList ["Grammar:", "NT:", "T:"]

-- | partial binding of 'reserve' to idents

reserveGI = reserve grammarIdentifiers

identGI = ident grammarIdentifiers



--
-- test stuff
--

testGrammar = unlines
  [ "Grammar: Align"
  , "NT: X"
  , "T:  a"
  , "S:  X"
  , "X -> step  <<< X a"
  , "X -> stand <<< X"
  , "//"
  ]

testParsing :: Result Grammar
testParsing = parseString
                ((evalStateT . runGrammarP) grammar def)
                (Directed (B.pack "testGrammar") 0 0 0 0)
                testGrammar

