{-# LANGUAGE BlockArguments #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE ViewPatterns #-}
{-# LANGUAGE DerivingVia #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE AllowAmbiguousTypes #-}
{-# LANGUAGE PolyKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE DataKinds #-}
{- |
Module: Options.Commander
Description: A set of combinators for constructing and executing command line programs
Copyright: (c) Samuel Schlesinger 2020
License: MIT
Maintainer: sgschlesinger@gmail.com
Stability: experimental
Portability: POSIX, Windows

Commander is an embedded domain specific language describing a command line
interface, along with ways to run those as real programs. An complete example
of such a command line interface is:

@
main :: IO ()
main = command_ . toplevel @"file" $
 (sub @"maybe-read" $
  arg @"filename" \filename ->
  flag @"read" \b -> raw $
    if b
      then putStrLn =<< readFile filename
      else pure ())
  \<+\>
 (sub @"maybe-write" $
  opt @"file" @"file-to-write" \mfilename -> raw $
    case mfilename of
      Just filename -> putStrLn =<< readFile filename
      Nothing -> pure ())
@

If I run this program with the argument help, it will output:

@
usage:
file maybe-read \<filename :: String\> ~read
file maybe-write -file \<file-to-write :: String\>
@

The point of this library is mainly so that you can write command line
interfaces quickly and easily, with somewhat useful help messages, and 
not have to write any boilerplate.
-}
module Options.Commander (
  -- ** Parsing Arguments and Options
  {- |
    If you want to use a Haskell type as an argument or option, you will need
    to implement the 'Unrender' class. Your type needs to be 'Typeable' for
    the sake of generating documentation.
  -}
  Unrender(unrender),
  -- ** Defining CLI Programs
  {- |
    To construct a 'ProgramT' (a specification of a CLI program), you can
    have 'arg'uments, 'opt'ions, 'raw' actions in a monad (typically IO),
    'sub'programs, 'named' programs, 'env'ironment variables, you can combine 
    programs together using '<+>', and you can generate primitive 'usage'
    information with 'usage'. There are combinators for retrieving environment
    variables as well. We also have a convenience combinator, 'toplevel',
    which lets you add a name and a help command to your program using the 'usage' combinator.
  -}
  arg, opt, optDef, raw, sub, named, flag, toplevel, (<+>), usage, env, envOpt, envOptDef,
  -- ** Run CLI Programs
  {- |
    To run a 'ProgramT' (a specification of a CLI program), you will 
    need to use 'command' or 'command_'.
  -}
  command, command_,
  {- |
    Each 'ProgramT' has a type level description, build from these type level
    combinators.
  -}
  type (&), type (+), Arg, Opt, Named, Raw, Flag, Env, Optionality(Required, Optional),
  -- ** Interpreting CLI Programs
  {- |
    The 'HasProgram' class forms the backbone of this library, defining the
    syntax for CLI programs using the 'ProgramT' data family, and defining
    the interpretation of all of the various pieces of a CLI.
  -}
  HasProgram(run, hoist, invocations),
  ProgramT(ArgProgramT, unArgProgramT,
           OptProgramT, unOptProgramT, unOptDefault,
           RawProgramT, unRawProgramT,
           SubProgramT, unSubProgramT,
           NamedProgramT, unNamedProgramT,
           FlagProgramT, unFlagProgramT,
           EnvProgramT'Optional, unEnvProgramT'Optional, unEnvDefault,
           EnvProgramT'Required, unEnvProgramT'Required,
           (:+:)
           ),
  -- ** The CommanderT Monad
  {- |
    The 'CommanderT' monad is how your CLI programs are interpreted by 'run'.
    It has the ability to backtrack and it maintains some state.
  -}
  CommanderT(Action, Defeat, Victory), runCommanderT, initialState, State(State, arguments, options, flags),
  -- ** Middleware for CommanderT
  {- |
    If you want to modify your interpreted CLI program, in its 'CommanderT'
    form, you can use the concept of 'Middleware'. A number of these are
    provided for debugging complex CLI programs, in case they aren't doing
    what you'd expect.
  -}
  Middleware, logState, transform, withActionEffects, withDefeatEffects, withVictoryEffects
) where

import Control.Applicative (Alternative(..))
import Control.Arrow (first)
import Control.Monad ((<=<))
import Control.Monad (ap, void)
import Control.Monad.Trans (MonadIO(..), MonadTrans(..))
import Data.HashMap.Strict as HashMap
import Data.HashSet as HashSet
import Data.Int
import Data.Proxy (Proxy(..))
import Data.Text (Text, pack, unpack, stripPrefix, find)
import Data.Text.Read (decimal, signed)
import Data.Word
import GHC.TypeLits (Symbol, KnownSymbol, symbolVal)
import GHC.Generics (Generic)
import Numeric.Natural
import System.Environment (getArgs, lookupEnv)
import Data.Typeable (Typeable, typeRep)
import qualified Data.ByteString as SBS
import qualified Data.ByteString.Char8 as BS8
import qualified Data.ByteString.Lazy as LBS

-- | A class for interpreting command line arguments into Haskell types.
class Typeable t => Unrender t where
  unrender :: Text -> Maybe t

instance Unrender String where
  unrender = Just . unpack

instance Unrender Text where
  unrender = Just

instance Unrender SBS.ByteString where
  unrender = Just . BS8.pack . unpack

instance Unrender LBS.ByteString where
  unrender = fmap LBS.fromStrict <$> unrender

-- | A useful default unrender for small, bounded data types.
unrenderSmall :: (Enum a, Bounded a, Show a) => Text -> Maybe a
unrenderSmall = flip Prelude.lookup [(pack $ show x, x) | x <- [minBound..maxBound]]

instance Unrender () where
  unrender = unrenderSmall

instance Unrender a => Unrender (Maybe a) where
  unrender x = justCase x <|> nothingCase x where
    justCase x' = do
      x'' <- stripPrefix "Just " x'
      return (unrender x'')
    nothingCase x' = if x' == "Nothing" then return Nothing else Nothing

instance (Unrender a, Unrender b) => Unrender (Either a b) where
  unrender x = leftCase x <|> rightCase x where
    leftCase  = fmap Left  . unrender <=< stripPrefix "Left "
    rightCase = fmap Right . unrender <=< stripPrefix "Right "

instance Unrender Bool where
  unrender = unrenderSmall

newtype WrappedIntegral i = WrappedIntegral i
  deriving newtype (Num, Real, Ord, Eq, Enum, Integral)

instance (Typeable i, Integral i) => Unrender (WrappedIntegral i) where
  unrender = either (const Nothing) h . signed decimal where
    h (n, "") = Just (fromInteger n)
    h _ = Nothing

deriving via WrappedIntegral Integer instance Unrender Integer
deriving via WrappedIntegral Int instance Unrender Int
deriving via WrappedIntegral Int8 instance Unrender Int8
deriving via WrappedIntegral Int16 instance Unrender Int16
deriving via WrappedIntegral Int32 instance Unrender Int32
deriving via WrappedIntegral Int64 instance Unrender Int64

newtype WrappedNatural i = WrappedNatural i
  deriving newtype (Num, Real, Ord, Eq, Enum, Integral)

instance (Typeable i, Integral i) => Unrender (WrappedNatural i) where
  unrender = either (const Nothing) h . decimal where
    h (n, "") = if n >= 0 then Just (fromInteger n) else Nothing
    h _ = Nothing 

deriving via WrappedNatural Natural instance Unrender Natural
deriving via WrappedNatural Word instance Unrender Word
deriving via WrappedNatural Word8 instance Unrender Word8
deriving via WrappedNatural Word16 instance Unrender Word16
deriving via WrappedNatural Word32 instance Unrender Word32
deriving via WrappedNatural Word64 instance Unrender Word64

instance Unrender Char where
  unrender = find (const True)

-- | The type level naming combinator, giving your program a name for the
-- sake of documentation.
data Named :: Symbol -> *

-- | The type level argument combinator, with a 'Symbol' designating the
-- name of that argument.
data Arg :: Symbol -> * -> *

-- | The type level option combinator, with a 'Symbol' designating the
-- option's name and another representing the metavariables name for
-- documentation purposes.
data Opt :: Symbol -> Symbol -> * -> *

-- | The type level flag combinator, taking a name as input, allowing your
-- program to take flags with the syntax @~flag@.
data Flag :: Symbol -> *

-- | The type level environment variable combinator, taking a name as
-- input, allowing your program to take environment variables as input
-- automatically.
data Env :: Optionality -> Symbol -> * -> *

-- | The type level raw monadic program combinator, allowing a command line
-- program to just do some computation.
data Raw :: *

data Optionality = Required | Optional

-- | The type level program sequencing combinator, taking two program types
-- and sequencing them one after another.
data (&) :: k -> * -> *
infixr 4 &

-- | The type level combining combinator, taking two program types as
-- input, and being interpreted as a program which attempts to run the
-- first command line program and, if parsing its flags, subprograms,
-- options or arguments fails, runs the second, otherwise failing.
data a + b
infixr 2 +

-- | A 'CommanderT' action is a metaphor for a military commander. At each
-- step, we have a new 'Action' to take, or we could have experienced
-- 'Defeat', or we can see 'Victory'. While a real life commander
-- worries about moving his troops around in order to achieve a victory in
-- battle, a 'CommanderT' worries about iteratively transforming a state 
-- to find some value. We will deal with the subset of these actions where
-- every function must decrease the size of the state, as those are the
-- actions for which this is a monad.
data CommanderT state m a
  = Action (state -> m (CommanderT state m a, state))
  | Defeat
  | Victory a
  deriving Functor

-- | We can run a 'CommanderT' action on a state and see if it has
-- a successful campaign.
runCommanderT :: Monad m 
              => CommanderT state m a 
              -> state 
              -> m (Maybe a)
runCommanderT (Action action) state = do
  (action', state') <- action state
  m <- runCommanderT action' state'
  return m
runCommanderT Defeat _ = return Nothing
runCommanderT (Victory a) _ = return (Just a)

instance (Monad m) => Applicative (CommanderT state m) where
  (<*>) = ap
  pure = Victory

instance MonadTrans (CommanderT state) where
  lift ma = Action $ \state -> do
    a <- ma
    return (pure a, state)

instance MonadIO m => MonadIO (CommanderT state m) where
  liftIO ma = Action $ \state -> do
    a <- liftIO ma
    return (pure a, state)

-- Return laws:
-- Goal: return a >>= k = k a
-- Proof: return a >>= k 
--      = Victory a >>= k 
--      = k a 
--      = k a
-- Goal: m >>= return = m
-- Proof:
--   Case 1: Defeat >>= return = Defeat
--   Case 2: Victory a >>= return 
--         = Victory a
--   Case 3: Action action >>= return
--         = Action $ \state -> do
--             (action', state') <- action state
--             return (action' >>= return, state')
--
-- Case 3 serves as an inductive proof only if action' is a strictly smaller action
-- than action!
--
--  Bind laws:
--  Goal: m >>= (\x -> k x >>= h) = (m >>= k) >>= h
--  Proof: 
--    Case 1: Defeat >>= _ = Defeat
--    Case 2: Victory a >>= (\x -> k x >>= f)
--          = k a >>= f
--          = (Victory a >>= k) >>= f
--    Case 3: Action action >>= (\x -> k x >>= h)
--          = Action $ \state -> do
--              (action', state') <- action state
--              return (action' >>= (\x -> k x >>= h), state')
--          = Action $ \state -> do
--              (action', state') <- action state
--              return ((action' >>= k) >>= h, state') -- by IH
--    On the other hand,
--            (Action action >>= k) >>= h
--          = Action (\state -> do
--              (action', state') <- action state
--              return (action' >>= k, state') >>= h
--          = Action $ \state -> do
--              (action', state') <- action state
--              return ((action' >>= k) >>= h, state')
--               
--   This completes our proof for the case when these are finite.
--   Basically, we require that the stream an action produces is strictly
--   smaller than any other streams, for all state inputs. The ways that we
--   use this monad transformer satisify this constraint. If this
--   constraint is not met, many of our functions will return bottom.
--
--   We can certainly have functions that operate on these things and
--   change them safely, without violating this constraint. All of the
--   functions that we define on CommanderT programs preserve this
--   property.
--
--   An example of a violating term might be:
--
--   violator :: CommanderT state m
--   violator = Action (\state -> return (violator, state))
--
--   The principled way to include this type would be to parameterize it by
--   a natural number and have that natural number decrease over time, but
--   to enforce that in Haskell we couldn't have the monad instance
--   anyways. This is the way to go for now, despite the type violating the
--   monad laws potentially for infinite inputs. 
instance Monad m => Monad (CommanderT state m) where
  Defeat >>= _ = Defeat
  Victory a >>= f = f a
  Action action >>= f = Action $ \state -> do
    (action', state') <- action state
    return (action' >>= f, state')

instance Monad m => Alternative (CommanderT state m) where
  empty = Defeat 
  Defeat <|> a = a 
  v@(Victory _) <|> _ = v
  Action action <|> p = Action $ \state -> do
    (action', state') <- action state 
    return (action' <|> p, state')

-- | This is the 'State' that the 'CommanderT' library uses for its role in
-- this library. It is not inlined, because that does nothing but obfuscate
-- the 'CommanderT' monad. It consists of 'arguments', 'options', and
-- 'flags'.
data State = State 
  { arguments :: [Text]
  , options :: HashMap Text Text
  , flags :: HashSet Text
  } deriving (Generic, Show, Eq, Ord)

-- | This is the workhorse of the library. Basically, it allows you to 
-- 'run' your 'ProgramT'
-- representation of your program as a 'CommanderT' and pump the 'State'
-- through it until you've processed all of the arguments, options, and
-- flags that you have specified must be used in your 'ProgramT'. You can
-- think of 'ProgramT' as a useful syntax for command line programs, but
-- 'CommanderT' as the semantics of that program. We also give the ability
-- to 'hoist' 'ProgramT' actions between monads if you can uniformly turn
-- computations in one into another. All of the different 'invocations'
-- are also stored to give a primitive form of automatically generated
-- documentation.
class HasProgram p where
  data ProgramT p (m :: * -> *) a
  run :: ProgramT p IO a -> CommanderT State IO a
  hoist :: (forall x. m x -> n x) -> ProgramT p m a -> ProgramT p n a
  invocations :: [Text]

instance (Unrender t, KnownSymbol name, HasProgram p) => HasProgram (Env 'Required name t & p) where
  newtype ProgramT (Env 'Required name t & p) m a = EnvProgramT'Required { unEnvProgramT'Required :: t -> ProgramT p m a }
  run f = Action $ \state -> do
    val <- lookupEnv (symbolVal (Proxy @name))
    case val of
      Just v ->
        case unrender (pack v) of
          Just t -> return (run (unEnvProgramT'Required f t), state)  
          Nothing -> return (Defeat, state)
      Nothing -> return (Defeat, state)
  hoist n (EnvProgramT'Required f) = EnvProgramT'Required (hoist n . f)
  invocations =
    [(("(required env: " <> pack (symbolVal (Proxy @name))
    <> " :: " <> pack (show (typeRep (Proxy @t)))
    <> "> ") <>)] <*> invocations @p

instance (Unrender t, KnownSymbol name, HasProgram p) => HasProgram (Env 'Optional name t & p) where
  data ProgramT (Env 'Optional name t & p) m a = EnvProgramT'Optional
    { unEnvProgramT'Optional :: Maybe t -> ProgramT p m a
    , unEnvDefault :: Maybe t }
  run f = Action $ \state -> do
    val <- lookupEnv (symbolVal (Proxy @name))
    case val of
      Just v ->
        case unrender (pack v) of
          Just t -> return (run (unEnvProgramT'Optional f t), state)  
          Nothing -> return (Defeat, state)
      Nothing -> return (run (unEnvProgramT'Optional f (unEnvDefault f)), state)

  hoist n (EnvProgramT'Optional f d) = EnvProgramT'Optional (hoist n . f) d
  invocations =
    [(("(optional env: " <> pack (symbolVal (Proxy @name))
    <> " :: " <> pack (show (typeRep (Proxy @t)))
    <> "> ") <>)] <*> invocations @p

instance (Unrender t, KnownSymbol name, HasProgram p) => HasProgram (Arg name t & p) where
  newtype ProgramT (Arg name t & p) m a = ArgProgramT { unArgProgramT :: t -> ProgramT p m a }
  run f = Action $ \State{..} -> do
    case arguments of
      (x : xs) -> 
        case unrender x of
          Just t -> return (run (unArgProgramT f t), State{ arguments = xs, .. })  
          Nothing -> return (Defeat, State{..})
      [] -> return (Defeat, State{..})
  hoist n (ArgProgramT f) = ArgProgramT (hoist n . f)
  invocations =
    [(("<" <> pack (symbolVal (Proxy @name))
    <> " :: " <> pack (show (typeRep (Proxy @t)))
    <> "> ") <>)] <*> invocations @p

instance (HasProgram x, HasProgram y) => HasProgram (x + y) where
  data ProgramT (x + y) m a = ProgramT x m a :+: ProgramT y m a
  run (f :+: g) = run f <|> run g
  hoist n (f :+: g) = hoist n f :+: hoist n g
  invocations = invocations @x <> invocations @y

infixr 2 :+:

instance HasProgram Raw where
  newtype ProgramT Raw m a = RawProgramT { unRawProgramT :: m a }
  run = liftIO . unRawProgramT
  hoist n (RawProgramT m) = RawProgramT (n m)
  invocations = [mempty]


instance (KnownSymbol name, KnownSymbol option, HasProgram p, Unrender t) => HasProgram (Opt option name t & p) where
  data ProgramT (Opt option name t & p) m a = OptProgramT
    { unOptProgramT :: Maybe t -> ProgramT p m a
    , unOptDefault :: Maybe t }
  run f = Action $ \State{..} -> do
    case HashMap.lookup (pack $ symbolVal (Proxy @option)) options of
      Just opt' -> 
        case unrender opt' of
          Just t -> return (run (unOptProgramT f (Just t)), State{..})
          Nothing -> return (Defeat, State{..})
      Nothing  -> return (run (unOptProgramT f (unOptDefault f)), State{..})
  hoist n (OptProgramT f d) = OptProgramT (hoist n . f) d
  invocations =
    [(("-" <> (pack $ symbolVal (Proxy @option)) 
    <> " <" <> (pack $ symbolVal (Proxy @name)) 
    <> " :: " <> (pack $ show (typeRep (Proxy @t)))
    <> "> ") <>)  ] <*> invocations @p

instance (KnownSymbol flag, HasProgram p) => HasProgram (Flag flag & p) where
  newtype ProgramT (Flag flag & p) m a = FlagProgramT { unFlagProgramT :: Bool -> ProgramT p m a }
  run f = Action $ \State{..} -> do
    let presence = HashSet.member (pack (symbolVal (Proxy @flag))) flags
    return (run (unFlagProgramT f presence), State{..})
  hoist n = FlagProgramT . fmap (hoist n) . unFlagProgramT
  invocations = [(("~" <> (pack $ symbolVal (Proxy @flag)) <> " ") <>)] <*> invocations @p

instance (KnownSymbol name, HasProgram p) => HasProgram (Named name & p) where
  newtype ProgramT (Named name &p) m a = NamedProgramT { unNamedProgramT :: ProgramT p m a }
  run = run . unNamedProgramT 
  hoist n = NamedProgramT . hoist n . unNamedProgramT
  invocations = [((pack (symbolVal (Proxy @name)) <> " ") <>)] <*> invocations @p

instance (KnownSymbol sub, HasProgram p) => HasProgram (sub & p) where
  newtype ProgramT (sub & p) m a = SubProgramT { unSubProgramT :: ProgramT p m a }
  run s = Action $ \State{..} -> do 
    case arguments of
      (x : xs) -> 
        if x == pack (symbolVal $ Proxy @sub) 
          then return (run $ unSubProgramT s, State{arguments = xs, ..})
          else return (Defeat, State{..})
      [] -> return (Defeat, State{..})
  hoist n = SubProgramT . hoist n . unSubProgramT
  invocations = [((pack $ symbolVal (Proxy @sub) <> " ") <> )] 
            <*> invocations @p

-- | A simple default for getting out the arguments, options, and flags
-- using 'getArgs'. We use the syntax ~flag for flags and ~opt
-- for options, with arguments using the typical ordered representation.
initialState :: IO State
initialState = do
  args <- getArgs
  let (opts, args', flags) = takeOptions args
  return $ State args' (HashMap.fromList opts) (HashSet.fromList flags) 
    where
      takeOptions :: [String] -> ([(Text, Text)], [Text], [Text])
      takeOptions = go [] [] [] where
        go opts args flags (('~':x') : z) = go opts args (pack x' : flags) z
        go opts args flags (('-':x) : y : z) = go ((pack x, pack y) : opts) args flags z
        go opts args flags (x : y) = go opts (pack x : args) flags y
        go opts args flags [] = (opts, reverse args, flags)

-- | This is a combinator which runs a 'ProgramT' with the options,
-- arguments, and flags that I get using the 'initialState' function,
-- ignoring the output of the program.
command_ :: HasProgram p 
         => ProgramT p IO a 
         -> IO ()
command_ prog = void $ initialState >>= runCommanderT (run prog)

-- | This is a combinator which runs a 'ProgramT' with the options,
-- arguments, and flags that I get using the 'initialState' function,
-- returning 'Just' the output of the program upon successful option and argument
-- parsing and returning 'Nothing' otherwise.
command :: HasProgram p 
        => ProgramT p IO a 
        -> IO (Maybe a)
command prog = initialState >>= runCommanderT (run prog)

-- | Required environment variable combinator
env :: KnownSymbol name
  => (x -> ProgramT p m a)
  -> ProgramT (Env 'Required name x & p) m a
env = EnvProgramT'Required

-- | Optional environment variable combinator
envOpt :: KnownSymbol name
  => (Maybe x -> ProgramT p m a)
  -> ProgramT (Env 'Optional name x & p) m a
envOpt = flip EnvProgramT'Optional Nothing

-- | Optional environment variable combinator with default
envOptDef :: KnownSymbol name
  => x
  -> (x -> ProgramT p m a)
  -> ProgramT (Env 'Optional name x & p) m a
envOptDef x f = EnvProgramT'Optional { unEnvDefault = Just x, unEnvProgramT'Optional = \case { Just x -> f x; Nothing -> error "Violated invariant of optEnvDef" } }

-- | Environment 

-- | Argument combinator
arg :: KnownSymbol name
    => (x -> ProgramT p m a) 
    -> ProgramT (Arg name x & p) m a 
arg = ArgProgramT

-- | Option combinator
opt :: (KnownSymbol option, KnownSymbol name)
    => (Maybe x -> ProgramT p m a) 
    -> ProgramT (Opt option name x & p) m a
opt = flip OptProgramT Nothing

-- | Option combinator with default
optDef :: (KnownSymbol option, KnownSymbol name)
  => x
  -> (x -> ProgramT p m a)
  -> ProgramT (Opt option name x & p) m a
optDef x f = OptProgramT { unOptDefault = Just x, unOptProgramT = \case { Just x -> f x; Nothing -> error "Violated invariant of optDef" } }

-- | Raw monadic combinator
raw :: m a 
    -> ProgramT Raw m a
raw = RawProgramT

-- | Subcommand combinator
sub :: KnownSymbol s 
    => ProgramT p m a 
    -> ProgramT (s & p) m a
sub = SubProgramT

-- | Named command combinator, useful at the top level for naming
-- a program. Typically, the name will be the name or alias of the
-- executable you expect to produce.
named :: KnownSymbol s 
      => ProgramT p m a 
      -> ProgramT (Named s & p) m a
named = NamedProgramT

-- | Boolean flag combinator
flag :: KnownSymbol f 
     => (Bool -> ProgramT p m a) 
     -> ProgramT (Flag f & p) m a
flag = FlagProgramT

-- | A convenience combinator that constructs the program I often want
-- to run out of a program I want to write.
toplevel :: forall s p m. (HasProgram p, KnownSymbol s, MonadIO m) 
         => ProgramT p m () 
         -> ProgramT (Named s & ("help" & Raw + p)) m ()
toplevel p = named (sub (usage @(Named s & ("help" & Raw + p))) <+> p)

-- | The command line program which consists of trying to enter one and
-- then trying the other.
(<+>) :: forall x y m a. ProgramT x m a -> ProgramT y m a -> ProgramT (x + y) m a
(<+>) = (:+:)

infixr 2 <+>

-- | A meta-combinator that takes a type-level description of a command 
-- line program and produces a simple usage program.
usage :: forall p m. (MonadIO m, HasProgram p) => ProgramT Raw m ()
usage = raw $ do
  liftIO $ putStrLn "usage:"
  void . traverse (liftIO . putStrLn . unpack) $ invocations @p

-- | The type of middleware, which can transform interpreted command line programs
-- by meddling with arguments, options, or flags, or by adding effects for
-- every step. You can also change the underlying monad.
type Middleware m n = forall a. CommanderT State m a -> CommanderT State n a

-- | Middleware to transform the base monad with a natural transformation.
transform :: (Monad m, Monad n) => (forall a. m a -> n a) -> Middleware m n
transform f commander = case commander of
  Action a -> Action $ \state -> do
    (commander', state') <- f (a state)
    pure (transform f commander', state')
  Defeat -> Defeat
  Victory a -> Victory a 

-- | Middleware to add monadic effects for every 'Action'. Useful for
-- debugging complex command line programs.
withActionEffects :: Monad m => m a -> Middleware m m
withActionEffects ma = transform (ma *>)

-- | Middleware to have effects whenever the program might backtrack.
withDefeatEffects :: Monad m => m a -> Middleware m m
withDefeatEffects ma commander = case commander of
  Action a -> Action $ \state -> do
    (commander', state') <- a state
    pure (withDefeatEffects ma commander', state')
  Defeat -> Action $ \state -> ma *> pure (Defeat, state)
  Victory a -> Victory a

-- | Middleware to have effects whenever the program successfully computes
-- a result.
withVictoryEffects :: Monad m => m a -> Middleware m m
withVictoryEffects ma commander = case commander of
  Action a -> Action $ \state -> do
    (commander', state') <- a state
    pure (withVictoryEffects ma commander', state')
  Defeat -> Defeat
  Victory a -> Action $ \state -> ma *> pure (Victory a, state)

-- | Middleware to log the state to standard out for every step of the
-- 'CommanderT' computation.
logState :: MonadIO m => Middleware m m
logState commander
  = case commander of
      Action a -> do
        Action $ \state -> do
          liftIO $ print state
          fmap (first logState) (a state)
      Defeat ->
        Action $ \state -> do
          liftIO $ print state
          pure (Defeat, state)
      Victory a ->
        Action $ \state -> do
          liftIO $ print state
          pure (Victory a, state)
