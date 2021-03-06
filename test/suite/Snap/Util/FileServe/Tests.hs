{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Snap.Util.FileServe.Tests
  ( tests ) where

import           Control.Monad
import           Data.ByteString (ByteString)
import qualified Data.ByteString.Char8 as S
import qualified Data.ByteString.Lazy.Char8 as L
import           Data.IORef
import qualified Data.Map as Map
import           Data.Maybe
import           Prelude hiding (take)
import           Test.Framework
import           Test.Framework.Providers.HUnit
import           Test.HUnit hiding (Test, path)

import           Snap.Internal.Http.Types
import           Snap.Internal.Types
import           Snap.Util.FileServe
import           Snap.Iteratee

tests :: [Test]
tests = [ testFs
        , testFsSingle
        , testRangeOK
        , testRangeBad
        , testMultiRange
        , testIfRange ]


expect404 :: IO Response -> IO ()
expect404 m = do
    r <- m
    assertBool "expected 404" (rspStatus r == 404)


getBody :: Response -> IO L.ByteString
getBody r = do
    let benum = rspBodyToEnum $ rspBody r
    liftM L.fromChunks (runIteratee consume >>= run_ . benum)


go :: Snap a -> ByteString -> IO Response
go m s = do
    rq <- mkRequest s
    liftM snd (run_ $ runSnap m (const $ return ()) rq)


goIfModifiedSince :: Snap a -> ByteString -> ByteString -> IO Response
goIfModifiedSince m s lm = do
    rq <- mkRequest s
    let r = setHeader "if-modified-since" lm rq
    liftM snd (run_ $ runSnap m (const $ return ()) r)


goIfRange :: Snap a -> ByteString -> (Int,Int) -> ByteString -> IO Response
goIfRange m s (start,end) lm = do
    rq <- mkRequest s
    let r = setHeader "if-range" lm $
            setHeader "Range"
                       (S.pack $ "bytes=" ++ show start ++ "-" ++ show end)
                       rq
    liftM snd (run_ $ runSnap m (const $ return ()) r)


goRange :: Snap a -> ByteString -> (Int,Int) -> IO Response
goRange m s (start,end) = do
    rq' <- mkRequest s
    let rq = setHeader "Range"
                       (S.pack $ "bytes=" ++ show start ++ "-" ++ show end)
                       rq'
    liftM snd (run_ $ runSnap m (const $ return ()) rq)


goMultiRange :: Snap a -> ByteString -> (Int,Int) -> (Int,Int) -> IO Response
goMultiRange m s (start,end) (start2,end2) = do
    rq' <- mkRequest s
    let rq = setHeader "Range"
                       (S.pack $ "bytes=" ++ show start ++ "-" ++ show end
                                 ++ "," ++ show start2 ++ "-" ++ show end2)
                       rq'
    liftM snd (run_ $ runSnap m (const $ return ()) rq)


goRangePrefix :: Snap a -> ByteString -> Int -> IO Response
goRangePrefix m s start = do
    rq' <- mkRequest s
    let rq = setHeader "Range"
                       (S.pack $ "bytes=" ++ show start ++ "-")
                       rq'
    liftM snd (run_ $ runSnap m (const $ return ()) rq)


goRangeSuffix :: Snap a -> ByteString -> Int -> IO Response
goRangeSuffix m s end = do
    rq' <- mkRequest s
    let rq = setHeader "Range"
                       (S.pack $ "bytes=-" ++ show end)
                       rq'
    liftM snd (run_ $ runSnap m (const $ return ()) rq)


mkRequest :: ByteString -> IO Request
mkRequest uri = do
    enum <- newIORef $ SomeEnumerator returnI
    return $ Request "foo" 80 "foo" 999 "foo" 1000 "foo" False Map.empty
                     enum Nothing GET (1,1) [] "" uri "/"
                     (S.concat ["/",uri]) "" Map.empty

fs :: Snap ()
fs = do
    x <- fileServe "data/fileServe"
    return $! x `seq` ()

fsSingle :: Snap ()
fsSingle = do
    x <- fileServeSingle "data/fileServe/foo.html"
    return $! x `seq` ()


testFs :: Test
testFs = testCase "fileServe/multi" $ do
    r1 <- go fs "foo.bin"
    b1 <- getBody r1

    assertEqual "foo.bin" "FOO\n" b1
    assertEqual "foo.bin content-type"
                (Just "application/octet-stream")
                (getHeader "content-type" r1)

    assertEqual "foo.bin size" (Just 4) (rspContentLength r1)

    assertBool "last-modified header" (isJust $ getHeader "last-modified" r1)
    assertEqual "accept-ranges header" (Just "bytes")
                                       (getHeader "accept-ranges" r1)

    let !lm = fromJust $ getHeader "last-modified" r1

    -- check last modified stuff
    r2 <- goIfModifiedSince fs "foo.bin" lm
    assertEqual "foo.bin 304" 304 $ rspStatus r2

    r3 <- goIfModifiedSince fs "foo.bin" "Wed, 15 Nov 1995 04:58:08 GMT"
    assertEqual "foo.bin 200" 200 $ rspStatus r3
    b3 <- getBody r3
    assertEqual "foo.bin 2" "FOO\n" b3

    r4 <- go fs "foo.txt"
    b4 <- getBody r4

    assertEqual "foo.txt" "FOO\n" b4
    assertEqual "foo.txt content-type"
                (Just "text/plain")
                (getHeader "content-type" r4)
    
    r5 <- go fs "foo.html"
    b5 <- getBody r5

    assertEqual "foo.html" "FOO\n" b5
    assertEqual "foo.html content-type"
                (Just "text/html")
                (getHeader "content-type" r5)
    
    r6 <- go fs "foo.bin.bin.bin"
    b6 <- getBody r6

    assertEqual "foo.bin.bin.bin" "FOO\n" b6
    assertEqual "foo.bin.bin.bin content-type"
                (Just "application/octet-stream")
                (getHeader "content-type" r6)

    expect404 $ go fs "jfldksjflksd"
    expect404 $ go fs "dummy/../foo.txt"
    expect404 $ go fs "/etc/password"

    coverMimeMap


testFsSingle :: Test
testFsSingle = testCase "fileServe/Single" $ do
    r1 <- go fsSingle "foo.html"
    b1 <- getBody r1

    assertEqual "foo.html" "FOO\n" b1
    assertEqual "foo.html content-type"
                (Just "text/html")
                (getHeader "content-type" r1)

    assertEqual "foo.html size" (Just 4) (rspContentLength r1)


testRangeOK :: Test
testRangeOK = testCase "fileServe/range/ok" $ do
    r1 <- goRange fsSingle "foo.html" (1,2)
    assertEqual "foo.html 206" 206 $ rspStatus r1
    b1 <- getBody r1

    assertEqual "foo.html partial" "OO" b1
    assertEqual "foo.html partial size" (Just 2) (rspContentLength r1)
    assertEqual "foo.html content-range"
                (Just "bytes 1-2/4")
                (getHeader "Content-Range" r1)

    r2 <- goRangeSuffix fsSingle "foo.html" 3
    assertEqual "foo.html 206" 206 $ rspStatus r2
    b2 <- getBody r2
    assertEqual "foo.html partial suffix" "OO\n" b2

    r3 <- goRangePrefix fsSingle "foo.html" 2
    assertEqual "foo.html 206" 206 $ rspStatus r3
    b3 <- getBody r3
    assertEqual "foo.html partial prefix" "O\n" b3


testMultiRange :: Test
testMultiRange = testCase "fileServe/range/multi" $ do
    r1 <- goMultiRange fsSingle "foo.html" (1,2) (3,3)

    -- we don't support multiple ranges so it's ok for us to return 200 here;
    -- test this behaviour
    assertEqual "foo.html 200" 200 $ rspStatus r1
    b1 <- getBody r1

    assertEqual "foo.html" "FOO\n" b1


testRangeBad :: Test
testRangeBad = testCase "fileServe/range/bad" $ do
    r1 <- goRange fsSingle "foo.html" (1,17)
    assertEqual "bad range" 416 (rspStatus r1)
    assertEqual "bad range content-range"
                (Just "bytes */4")
                (getHeader "Content-Range" r1)
    assertEqual "bad range content-length" (Just 0) (rspContentLength r1)
    b1 <- getBody r1
    assertEqual "bad range empty body" "" b1

    r2 <- goRangeSuffix fsSingle "foo.html" 4893
    assertEqual "bad suffix range" 416 $ rspStatus r2


coverMimeMap :: (Monad m) => m ()
coverMimeMap = Prelude.mapM_ f $ Map.toList defaultMimeTypes
  where
    f (!k,!v) = return $ case k `seq` v `seq` () of () -> ()


testIfRange :: Test
testIfRange = testCase "fileServe/range/if-range" $ do
    r <- goIfRange fs "foo.bin" (1,2) "Wed, 15 Nov 1995 04:58:08 GMT"
    assertEqual "foo.bin 200" 200 $ rspStatus r
    b <- getBody r
    assertEqual "foo.bin" "FOO\n" b

    r2 <- goIfRange fs "foo.bin" (1,2) "Tue, 01 Oct 2030 04:58:08 GMT"
    assertEqual "foo.bin 206" 206 $ rspStatus r2
    b2 <- getBody r2
    assertEqual "foo.bin partial" "OO" b2

    r3 <- goIfRange fs "foo.bin" (1,24324) "Tue, 01 Oct 2030 04:58:08 GMT"
    assertEqual "foo.bin 200" 200 $ rspStatus r3
    b3 <- getBody r3
    assertEqual "foo.bin" "FOO\n" b3
