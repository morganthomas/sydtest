{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE UndecidableInstances #-}

module Test.Syd where

import Control.Exception
import Control.Monad.Reader
import Data.ByteString (ByteString)
import qualified Data.ByteString as SB
import qualified Data.ByteString.Char8 as SB8
import Data.IORef
import Data.List
import Data.Maybe
import qualified Data.Text as T
import Data.Text (Text)
import GHC.Stack
import Rainbow
import Safe
import System.Exit
import Test.QuickCheck.IO ()
import Test.Syd.Run
import Text.Printf

sydTest :: Spec -> IO ()
sydTest spec = do
  ((), specForest) <- runTestDefM spec
  resultForest <- runSpecForest specForest
  printOutputSpecForest resultForest
  when (shouldExitFail resultForest) (exitWith (ExitFailure 1))

type Spec = TestDefM ()

data TestDefEnv
  = TestDefEnv
      { testDefEnvForest :: IORef TestForest
      }

newtype TestDefM a = TestDefM {unTestDefM :: ReaderT TestDefEnv IO a}
  deriving (Functor, Applicative, Monad, MonadIO, MonadReader TestDefEnv)

runTestDefM :: TestDefM a -> IO (a, TestForest)
runTestDefM defFunc = do
  forestVar <- newIORef []
  let env = TestDefEnv {testDefEnvForest = forestVar}
  let func = unTestDefM defFunc
  a <- runReaderT func env
  sf <- readIORef forestVar
  pure (a, sf)

describe :: String -> TestDefM a -> TestDefM a
describe s func = do
  (a, sf) <- liftIO $ runTestDefM func
  var <- asks testDefEnvForest
  liftIO $ modifyIORef var $ (++ [DescribeNode (T.pack s) sf]) -- FIXME this can probably be slow because of ++
  pure a

it :: (HasCallStack, IsTest test) => String -> test -> TestDefM ()
it s t = do
  var <- asks testDefEnvForest
  let testDef = TestDef {testDefVal = runTest t, testDefCallStack = callStack}
  liftIO $ modifyIORef var $ (++ [SpecifyNode (T.pack s) testDef]) -- FIXME this can probably be slow because of ++

type SpecForest a = [SpecTree a]

data SpecTree a
  = DescribeNode Text (SpecForest a) -- A description
  | SpecifyNode Text a -- A test with its description
  deriving (Show, Functor)

instance Foldable SpecTree where
  foldMap f = \case
    DescribeNode _ sts -> foldMap (foldMap f) sts
    SpecifyNode _ a -> f a

instance Traversable SpecTree where
  traverse func = \case
    DescribeNode s sts -> DescribeNode s <$> traverse (traverse func) sts
    SpecifyNode s a -> SpecifyNode s <$> func a

data TestDef a = TestDef {testDefVal :: a, testDefCallStack :: CallStack}
  deriving (Functor)

type TestForest = SpecForest (TestDef (IO TestRunResult))

type ResultForest = SpecForest (TestDef TestRunResult)

type ResultTree = SpecTree (TestDef TestRunResult)

runSpecForest :: TestForest -> IO ResultForest
runSpecForest = traverse $ traverse $ \td -> do
  let runFunc = testDefVal td
  result <- runFunc
  pure $ td {testDefVal = result}

printOutputSpecForest :: ResultForest -> IO ()
printOutputSpecForest results = do
  byteStringMaker <- byteStringMakerFromEnvironment
  let bytestrings = map (chunksToByteStrings byteStringMaker) (outputResultReport results) :: [[ByteString]]
  forM_ bytestrings $ \bs -> do
    mapM_ SB.putStr bs
    SB8.putStrLn ""

outputResultReport :: ResultForest -> [[Chunk]]
outputResultReport rf =
  concat
    [ [ [fore blue $ chunk "Tests:"],
        [chunk ""]
      ],
      outputSpecForest rf,
      [ [chunk ""],
        [chunk ""],
        [fore blue $ chunk "Failures:"],
        [chunk ""]
      ],
      outputFailures rf
    ]

outputSpecForest :: ResultForest -> [[Chunk]]
outputSpecForest = concatMap outputSpecTree

outputSpecTree :: ResultTree -> [[Chunk]]
outputSpecTree = \case
  DescribeNode t sf -> [fore yellow $ chunk t] : map (chunk "  " :) (outputSpecForest sf)
  SpecifyNode t (TestDef (TestRunResult {..}) _) ->
    map (map (fore (statusColour testRunResultStatus))) $
      filter
        (not . null)
        [ [ chunk (statusCheckMark testRunResultStatus),
            chunk t
          ],
          concat
            [ -- [chunk (T.pack (printf "%10.2f ms " (testRunResultExecutionTime * 1000)))],
              [chunk (T.pack (printf "  (passed for all of %d inputs)" w)) | w <- maybeToList testRunResultNumTests, testRunResultStatus == TestPassed]
            ]
        ]

outputFailures :: ResultForest -> [[Chunk]]
outputFailures rf =
  let failures = filter ((== TestFailed) . testRunResultStatus . testDefVal . snd) $ flattenSpecForest rf
      nbDigitsInFailureCount :: Int
      nbDigitsInFailureCount = ceiling (logBase 10 (genericLength failures) :: Double)
      pad = (chunk (T.replicate (nbDigitsInFailureCount + 3) " ") :)
   in map (chunk "  " :) $ filter (not . null) $ concat $ indexed failures $ \w (ts, TestDef (TestRunResult {..}) cs) ->
        concat
          [ [ [ (fore cyan) $ chunk $ T.pack $
                  case headMay $ getCallStack cs of
                    Nothing -> "Unknown location"
                    Just (_, SrcLoc {..}) ->
                      concat
                        [ srcLocFile,
                          ":",
                          show srcLocStartLine
                        ]
              ],
              map
                (fore (statusColour testRunResultStatus))
                [ chunk $ statusCheckMark testRunResultStatus,
                  chunk $ T.pack (printf ("%" ++ show nbDigitsInFailureCount ++ "d ") w),
                  chunk $ T.intercalate "." ts
                ]
            ],
            map (pad . (: []) . chunk . T.pack) $
              case (testRunResultNumTests, testRunResultNumShrinks) of
                (Nothing, _) -> []
                (Just numTests, Nothing) -> [printf "Failled after %d tests" numTests]
                (Just numTests, Just numShrinks) -> [printf "Failed after %d tests and %d shrinks" numTests numShrinks],
            map pad $ case testRunResultException of
              Nothing -> []
              Just (Left s) ->
                let ls = lines s
                 in map ((: []) . chunk . T.pack) ls
              Just (Right a) -> case a of
                Equality actual expected ->
                  [ [chunk "Expected these values to be equal: "],
                    [chunk "Actual:   ", chunk (T.pack actual)],
                    [chunk "Expected: ", chunk (T.pack expected)]
                  ],
            [[chunk ""]]
          ]

indexed :: [a] -> (Word -> a -> b) -> [b]
indexed ls func = zipWith func [1 ..] ls

flattenSpecForest :: SpecForest a -> [([Text], a)]
flattenSpecForest = concatMap flattenSpecTree

flattenSpecTree :: SpecTree a -> [([Text], a)]
flattenSpecTree = \case
  DescribeNode t sf -> map (\(ts, a) -> (t : ts, a)) $ flattenSpecForest sf
  SpecifyNode t a -> [([t], a)]

outputFailure :: TestRunResult -> Maybe [[Chunk]]
outputFailure TestRunResult {..} = case testRunResultStatus of
  TestPassed -> Nothing
  TestFailed -> Just [[chunk "Failure"]]

statusColour :: TestStatus -> Radiant
statusColour = \case
  TestPassed -> green
  TestFailed -> red

statusCheckMark :: TestStatus -> Text
statusCheckMark = \case
  TestPassed -> "\10003 "
  TestFailed -> "\10007 "

shouldExitFail :: ResultForest -> Bool
shouldExitFail = any (any ((== TestFailed) . testRunResultStatus . testDefVal))

shouldBe :: (Show a, Eq a) => a -> a -> IO ()
shouldBe actual expected = unless (actual == expected) $ throwIO $ Equality (show actual) (show expected)
