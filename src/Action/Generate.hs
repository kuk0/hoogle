{-# LANGUAGE ViewPatterns, TupleSections, RecordWildCards, ScopedTypeVariables #-}

module Action.Generate(actionGenerate) where

import Data.List.Extra
import System.FilePath
import System.Directory.Extra
import System.Time.Extra
import Data.Tuple.Extra
import Control.Exception.Extra
import Data.IORef
import Data.Maybe
import qualified Data.Set as Set
import qualified Data.Map as Map
import qualified Data.Text as T
import Control.Monad.Extra
import Numeric.Extra
import System.Console.CmdArgs.Verbosity
import Prelude

import Output.Items
import Output.Tags
import Output.Names
import Output.Types
import Input.Cabal
import Input.Haddock
import Input.Download
import Input.Reorder
import Input.Set
import Input.Item
import General.Util
import General.Store
import General.Str
import System.Mem
import System.IO
import GHC.Stats
import Action.CmdLine
import General.Conduit

{-


data GenList
    = GenList_Package String -- a literally named package
    | GenList_GhcPkg String -- command to run, or "" for @ghc-pkg list@
    | GenList_Stackage String -- URL of stackage file, defaults to @http://www.stackage.org/lts/cabal.config@
    | GenList_Dependencies String -- dependencies in a named .cabal file
    | GenList_Sort String -- URL of file to sort by, defaults to @http://packdeps.haskellers.com/reverse@

data GenTags
    = GenTags_GhcPkg String -- command to run, or "" for @ghc-pkg dump@
    | GenTags_Diff FilePath -- a diff to apply to previous metadata
    | GenTags_Tarball String -- tarball of Cabal files, defaults to http://hackage.haskell.org/packages/index.tar.gz
    | GetTags_Cabal FilePath -- tarball to get tag information from

data GenData
    = GenData_File FilePath -- a file containing package data
    | GenData_Tarball String -- URL where a tarball of data files resides


* `hoogle generate` - generate for all things in Stackage based on Hackage information.
* `hoogle generate --source=file1.txt --source=local --source=stackage --source=hackage --source=tarball.tar.gz`

Which files you want to index. Currently the list on stackage, could be those locally installed, those in a .cabal file etc. A `--list` flag, defaults to `stackage=url`. Can also be `ghc-pkg`, `ghc-pkg=user` `ghc-pkg=global`. `name=p1`.

Extra metadata you want to apply. Could be a file. `+shake author:Neil-Mitchell`, `-shake author:Neil-Mitchel`. Can be sucked out of .cabal files. A `--tags` flag, defaults to `tarball=url` and `diff=renamings.txt`.

Where the haddock files are. Defaults to `tarball=hackage-url`. Can also be `file=p1.txt`. Use `--data` flag.

Defaults to: `hoogle generate --list=ghc-pkg --list=constrain=stackage-url`.

Three pieces of data:

* Which packages to index, in order.
* Metadata.


generate :: Maybe Int -> [GenList] -> [GenTags] -> [GenData] -> IO ()
-- how often to redownload, where to put the files



generate :: FilePath -> [(String, [(String, String)])] -> [(String, LBS.ByteString)] -> IO ()
generate output metadata  = undefined
-}


-- -- generate all
-- @tagsoup -- generate tagsoup
-- @tagsoup filter -- search the tagsoup package
-- filter -- search all

data Timing = Timing (Maybe (IORef [(String, Double)]))

withTiming :: Maybe FilePath -> (Timing -> IO a) -> IO a
withTiming file f = do
    offset <- offsetTime
    ref <- newIORef []
    res <- f $ Timing $ if isJust file then Just ref else Nothing
    end <- offset
    whenJust file $ \file -> do
        ref <- readIORef ref
        -- Expecting unrecorded of ~2s
        -- Most of that comes from the pipeline - we get occasional 0.01 between items as one flushes
        -- Then at the end there is ~0.5 while the final item flushes
        ref <- return $ reverse $ sortOn snd $ ("Unrecorded",end - sum (map snd ref)) : ref
        writeFile file $ unlines [showDP 2 b ++ "\t" ++ a | (a,b) <- ("Total",end) : ref]
    putStrLn $ "Took " ++ showDuration end
    return res


timed :: MonadIO m => Timing -> String -> m a -> m a
timed (Timing ref) msg act = do
    liftIO $ putStr (msg ++ "... ") >> hFlush stdout
    time <- liftIO offsetTime
    res <- act
    time <- liftIO time
    stats <- liftIO getGCStatsEnabled
    s <- if not stats then return "" else do GCStats{..} <- liftIO getGCStats; return $ " (" ++ show peakMegabytesAllocated ++ "Mb)"
    liftIO $ putStrLn $ showDuration time ++ s
    case ref of -- don't use whenJust, induces Appliative pre-AMP
        Nothing -> return ()
        Just ref -> liftIO $ modifyIORef ref ((msg,time):)
    return res


readRemote :: CmdLine -> Timing -> IO (Map.Map String Package, Set.Set String, Source IO (String, URL, LStr))
readRemote Generate{..} timing = do
    downloadInputs (timed timing) insecure download language $ takeDirectory database

    -- peakMegabytesAllocated = 2
    let input x = takeDirectory database </> "input-" ++ lower (show language) ++ "-" ++ x

    if language == Haskell then do

        setStackage <- setStackage $ input "stackage.txt"
        setPlatform <- setPlatform $ input "platform.txt"
        setGHC <- setGHC $ input "platform.txt"

        cbl <- timed timing "Reading Cabal" $ parseCabalTarball $ input "cabal.tar.gz"
        let want = Set.insert "ghc" $ Set.unions [setStackage, setPlatform, setGHC]
        cbl <- return $ flip Map.mapWithKey cbl $ \name p ->
            p{packageTags =
                [(T.pack "set",T.pack "included-with-ghc") | name `Set.member` setGHC] ++
                [(T.pack "set",T.pack "haskell-platform") | name `Set.member` setPlatform] ++
                [(T.pack "set",T.pack "stackage") | name `Set.member` setStackage] ++
                packageTags p}

        let source = do
                tar <- liftIO $ tarballReadFiles $ input "hoogle.tar.gz"
                forM_ tar $ \(takeBaseName -> name, src) ->
                    yield (name, "https://hackage.haskell.org/package/" ++ name, src)
                src <- liftIO $ strReadFile $ input "ghc.txt"
                let url = "http://downloads.haskell.org/~ghc/7.10.3/docs/html/libraries/ghc-7.10.3/"
                yield ("ghc", url, lstrFromChunks [src])
        return (cbl, want, source)

     else if language == Frege then do
        let source = do
                src <- liftIO $ strReadFile $ input "frege.txt"
                yield ("frege", "http://google.com/", lstrFromChunks [src])
        return (Map.empty, Set.singleton "frege", source)

     else
        fail $ "Unknown language, " ++ show language


readLocal :: CmdLine -> Timing -> IO (Map.Map String Package, Set.Set String, Source IO (String, URL, LStr))
readLocal Generate{..} timing = do
    when (language /= Haskell) $ fail "Can only generate local database for Haskell"

    cbl <- timed timing "Reading ghc-pkg" readGhcPkg
    let source =
            forM_ (Map.toList cbl) $ \(name,Package{..}) -> whenJust packageDocs $ \docs -> do
                let file = docs </> name <.> "txt"
                whenM (liftIO $ doesFileExist file) $ do
                    src <- liftIO $ strReadFile file
                    docs <- liftIO $ canonicalizePath docs
                    let url = "file://" ++ ['/' | not $ all isPathSeparator $ take 1 docs] ++
                              replace "\\" "/" (addTrailingPathSeparator docs)
                    yield (name, url, lstrFromChunks [src])
    cbl <- return $ let ts = map (both T.pack) [("set","stackage"),("set","installed")]
                    in Map.map (\p -> p{packageTags = ts ++ packageTags p}) cbl
    return (cbl, Map.keysSet cbl, source)


actionGenerate :: CmdLine -> IO ()
actionGenerate g@Generate{..} = withTiming (if debug then Just $ replaceExtension database "timing" else Nothing) $ \timing -> do
    putStrLn "Starting generate"
    createDirectoryIfMissing True $ takeDirectory database
    (remote,local) <- return $ if not remote && not local then (True,True) else (remote,local)
    gcStats <- getGCStatsEnabled

    -- fix up people using Hoogle 4 instructions
    args <- if "all" `notElem` include then return include else do
        putStrLn "Warning: 'all' argument is no longer required, and has been ignored."
        return $ delete "all" include

    (cbl, want, source) <-
        if remote then readRemote g timing else readLocal g timing
    let (cblErrs, popularity) = packagePopularity cbl
    want <- return $ if args /= [] then Set.fromList args else want

    (stats, _) <- storeWriteFile database $ \store -> do
        xs <- withBinaryFile (database `replaceExtension` "warn") WriteMode $ \warnings -> do
            hSetEncoding warnings utf8
            hPutStr warnings $ unlines cblErrs
            nCblErrs <- evaluate $ length cblErrs

            itemWarn <- newIORef 0
            let warning msg = do modifyIORef itemWarn succ; hPutStrLn warnings msg

            let consume :: Conduit (Int, (String, URL, LStr)) IO (Maybe Target, Item)
                consume = awaitForever $ \(i, (pkg, url, body)) -> do
                    timed timing ("[" ++ show i ++ "/" ++ show (Set.size want) ++ "] " ++ pkg) $
                        parseHoogle warning pkg url body

            writeItems store $ \items -> do
                let packages = [ fakePackage name $ "Not in Stackage, so not searched.\n" ++ T.unpack packageSynopsis
                               | (name,Package{..}) <- Map.toList cbl, name `Set.notMember` want]

                (seen, xs) <- runConduit $
                    source =$=
                    filterC (flip Set.member want . fst3) =$=
                        ((fmap Set.fromList $ mapC fst3 =$= sinkList) |$|
                        (((zipFromC 1 =$= consume) >> when (null args) (sourceList packages))
                            =$= pipelineC 10 (items =$= sinkList)))

                let missing = [x | x <- Set.toList $ want `Set.difference` seen
                                 , fmap packageLibrary (Map.lookup x cbl) /= Just False]
                whenNormal $ when (missing /= []) $ do
                    putStrLn $ ("Packages not found: " ++) $ unwords $ sortOn lower missing
                when (Set.null seen) $
                    exitFail "No packages were found, aborting (use no arguments to index all of Stackage)"

                itemWarn <- readIORef itemWarn
                when (itemWarn > 0) $
                    putStrLn $ "Found " ++ show itemWarn ++ " warnings when processing items"
                return xs

        itemsMb <- if not gcStats then return 0 else do performGC; GCStats{..} <- getGCStats; return $ currentBytesUsed `div` (1024*1024)
        xs <- timed timing "Reodering items" $ reorderItems (\s -> maybe 1 negate $ Map.lookup s popularity) xs
        timed timing "Writing tags" $ writeTags store (`Set.member` want) (\x -> maybe [] (map (both T.unpack) . packageTags) $ Map.lookup x cbl) xs
        timed timing "Writing names" $ writeNames store xs
        timed timing "Writing types" $ writeTypes store (if debug then Just $ dropExtension database else Nothing) xs

        when gcStats $ do
            stats@GCStats{..} <- getGCStats
            x <- getVerbosity
            when (x >= Loud) $
                print stats
            when (x >= Normal) $ do
                putStrLn $ "Peak of " ++ show peakMegabytesAllocated ++ "Mb, " ++ show itemsMb ++ "Mb for items"

    when debug $
        writeFile (database `replaceExtension` "store") $ unlines stats
