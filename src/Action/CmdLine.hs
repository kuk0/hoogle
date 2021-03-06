{-# LANGUAGE DeriveDataTypeable #-}
{-# OPTIONS_GHC -fno-warn-missing-fields -fno-cse #-}

module Action.CmdLine(
    CmdLine(..), Language(..), getCmdLine,
    whenLoud, whenNormal
    ) where

import System.Console.CmdArgs
import System.Directory
import System.FilePath
import Data.List.Extra
import Data.Version
import Paths_hoogle(version)

data Language = Haskell | Frege deriving (Data,Typeable,Show,Eq,Enum,Bounded)

data CmdLine
    = Search
        {color :: Maybe Bool
        ,link :: Bool
        ,numbers :: Bool
        ,info :: Bool
        ,database :: FilePath
        ,count :: Int
        ,query :: [String]
        ,repeat_ :: Int
        ,language :: Language
        }
    | Generate
        {hackage :: String
        ,download :: Maybe Bool
        ,database :: FilePath
        ,insecure :: Bool
        ,include :: [String]
        ,local :: Bool
        ,remote :: Bool
        ,debug :: Bool
        ,language :: Language
        }
    | Server
        {port :: Int
        ,database :: FilePath
        ,cdn :: String
        ,logs :: FilePath
        ,local :: Bool
        ,language :: Language
        ,host :: String
        }
    | Replay
        {logs :: FilePath
        ,database :: FilePath
        ,repeat_ :: Int
        ,language :: Language
        }
    | Test
        {deep :: Bool
        ,database :: FilePath
        ,language :: Language
        }
      deriving (Data,Typeable,Show)

getCmdLine :: IO CmdLine
getCmdLine = do
    args <- cmdArgsRun cmdLineMode
    if database args /= "" then return args else do
        dir <- getAppUserDataDirectory "hoogle"
        return $ args{database=dir </> "default-" ++ lower (show $ language args) ++ "-" ++ showVersion version ++ ".hoo"}

cmdLineMode = cmdArgsMode $ modes [search_ &= auto,generate,server,replay,test]
    &= verbosity &= program "hoogle"
    &= summary ("Hoogle " ++ showVersion version ++ ", http://hoogle.haskell.org/")

search_ = Search
    {color = def &= name "colour" &= help "Use colored output (requires ANSI terminal)"
    ,link = def &= help "Give URL's for each result"
    ,numbers = def &= help "Give counter for each result"
    ,info = def &= help "Give extended information about the first result"
    ,database = def &= typFile &= help "Name of database to use (use .hoo extension)"
    ,count = 10 &= name "n" &= help "Maximum number of results to return"
    ,query = def &= args &= typ "QUERY"
    ,repeat_ = 1 &= help "Number of times to repeat (for benchmarking)"
    ,language = enum [x &= explicit &= name (lower $ show x) &= help ("Work with " ++ show x) | x <- [minBound..maxBound]] &= groupname "Language"
    } &= help "Perform a search"

generate = Generate
    {hackage = "https://hackage.haskell.org/" &= typ "URL" &= help "Hackage instance to target"
    ,download = def &= help "Download all files from the web"
    ,insecure = def &= help "Allow insecure HTTPS connections"
    ,include = def &= args &= typ "PACKAGE"
    ,local = def &= help "Index local packages"
    ,remote = def &= help "Index remote packages"
    ,debug = def &= help "Generate debug information"
    } &= help "Generate Hoogle databases"

server = Server
    {port = 80 &= typ "INT" &= help "Port number"
    ,cdn = "" &= typ "URL" &= help "URL prefix to use"
    ,logs = "" &= opt "log.txt" &= typFile &= help "File to log requests to (defaults to stdout)"
    ,local = False &= help "Allow following file:// links, restricts to 127.0.0.1"
    ,host = "*" &= help "Set the host to bind on (e.g., an ip address; '!4' for ipv4-only; '!6' for ipv6-only; default: '*' for any host)."
    } &= help "Start a Hoogle server"

replay = Replay
    {logs = "log.txt" &= args &= typ "FILE"
    } &= help "Replay a log file"

test = Test
    {deep = False &= help "Run extra long tests"
    } &= help "Run the test suite"
