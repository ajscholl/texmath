{-# LANGUAGE CPP, OverloadedStrings #-}
module Main where

import Text.TeXMath
import Data.Monoid
import Data.Char (isSpace)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.IO as TIO
import Text.XML.Light
import System.IO
import System.Environment
import Control.Applicative
import System.Console.GetOpt
import Data.List (intersperse)
import System.Exit
import Data.Maybe
import Text.Pandoc.Definition
import Network.URI (unEscapeString)
import Data.List.Split (splitOn)
import Data.Aeson (encode, (.=), object)
import qualified Data.ByteString.Lazy as B
import Data.Version ( showVersion )
import Paths_texmath (version)

inHtml :: Element -> Element
inHtml e =
  add_attr (Attr (unqual "xmlns") "http://www.w3.org/1999/xhtml") $
  unode "html"
    [ unode "head" $
        add_attr (Attr (unqual "content") "application/xhtml+xml; charset=UTF-8") $
        add_attr (Attr (unqual "http-equiv") "Content-Type") $
        unode "meta" ()
    , unode "body" e ]

type Reader = Text -> Either String [Exp]
data Writer = XMLWriter (DisplayType -> [Exp] -> Element)
            | TextWriter (DisplayType -> [Exp] -> Text)
            | PandocWriter (DisplayType -> [Exp] -> Maybe [Inline])

readers :: [(String, Reader)]
readers = [
    ("tex", readTeX)
  , ("mathml", readMathML)
  , ("omml", readOMML)
  , ("native", readNative)]

readNative :: Text -> Either String [Exp]
readNative s =
  case reads (Text.unpack s) of
       ((exps, ws):_) | all isSpace ws -> Right exps
       ((_, (_:_)):_) -> Left "Could not read whole input as native Exp"
       _ -> Left "Could not read input as native Exp"

writers :: [(String, Writer)]
writers = [
    ("native", TextWriter (\_ es -> Text.pack (show es)))
  , ("tex", TextWriter (\_ -> writeTeX))
  , ("omml",  XMLWriter writeOMML)
  , ("xhtml",   XMLWriter (\dt e -> inHtml (writeMathML dt e)))
  , ("mathml",   XMLWriter writeMathML)
  , ("pandoc", PandocWriter writePandoc)]

data Options = Options {
    optDisplay :: DisplayType
  , optIn :: String
  , optOut :: String }

def :: Options
def = Options DisplayBlock "tex" "mathml"

options :: [OptDescr (Options -> IO Options)]
options =
  [ Option [] ["inline"]
      (NoArg (\opts -> return opts {optDisplay = DisplayInline}))
      "Use the inline display style"
  , Option "f" ["from"]
      (ReqArg (\s opts -> return opts {optIn = s}) "FORMAT")
      ("Input format: " ++ (concat $ intersperse ", " (map fst readers)))
  , Option "t" ["to"]
      (ReqArg (\s opts -> return opts {optOut = s}) "FORMAT")
      ("Output format: " ++ (concat $ intersperse ", " (map fst writers)))
   , Option "v" ["version"]
      (NoArg (\_ -> do
                      hPutStrLn stderr $ "Version " ++ showVersion version
                      exitWith ExitSuccess))
      "Print version"

    , Option "h" ["help"]
        (NoArg (\_ -> do
                        prg <- getProgName
                        hPutStrLn stderr (usageInfo (prg ++ " [OPTIONS] [FILE*]") options)
                        exitWith ExitSuccess))
      "Show help"
  ]

output :: DisplayType -> Writer -> [Exp] -> Text
output dt (XMLWriter w) es    = output dt (TextWriter (\dt' -> Text.pack . ppElement . w dt' )) es
output dt (TextWriter w) es = w dt es
output dt (PandocWriter w) es = Text.pack (show (fromMaybe fallback (w dt es)))
  where fallback = [Math mt (writeTeX es)]
        mt = case dt of
                  DisplayBlock  -> DisplayMath
                  DisplayInline -> InlineMath

err :: Bool -> Int -> String -> IO a
err cgi code msg = do
  if cgi
     then B.putStr $ encode $ object [Text.pack "error" .= msg]
     else hPutStrLn stderr msg
  exitWith $ ExitFailure code

ensureFinalNewline :: Text -> Text
ensureFinalNewline xs
  | Text.null xs = Text.empty
  | Text.last xs == '\n' = xs
  | otherwise = xs <> "\n"

urlUnencode :: String -> String
urlUnencode = unEscapeString . plusToSpace
  where plusToSpace ('+':xs) = "%20" ++ plusToSpace xs
        plusToSpace (x:xs)   = x : plusToSpace xs
        plusToSpace []       = []

main :: IO ()
main = do
  progname <- getProgName
  let cgi = progname == "texmath-cgi"
  if cgi
     then runCGI
     else runCommandLine

runCommandLine :: IO ()
runCommandLine = do
  args <- getArgs
  let (actions, files, _) = getOpt RequireOrder options args
  opts <- foldl (>>=) (return def) actions
  inp <- case files of
              [] -> TIO.getContents
              _  -> Text.concat <$> mapM TIO.readFile files
  reader <- case lookup (optIn opts) readers of
                  Just r -> return r
                  Nothing -> err False 3 "Unrecognised reader"
  writer <- case lookup (optOut opts) writers of
                  Just w -> return w
                  Nothing -> err False 5 "Unrecognised writer"
  case reader inp of
        Left msg -> err False 1 msg
        Right v  -> TIO.putStr $ ensureFinalNewline
                           $ output (optDisplay opts) writer v
  exitWith ExitSuccess

runCGI :: IO ()
runCGI = do
  query <- getContents
  let topairs xs = case break (=='=') xs of
                        (ys,('=':zs)) -> (urlUnencode ys, urlUnencode zs)
                        (ys,_)        -> (urlUnencode ys, "")
  let pairs = map topairs $ splitOn "&" query
  inp <- case lookup "input" pairs of
                 Just x  -> return $ Text.pack x
                 Nothing -> err True 3 "Query missing 'input'"
  reader <- case lookup "from" pairs of
                 Just x  -> case lookup x readers of
                                 Just y  -> return y
                                 Nothing -> err True 5 "Unsupported value of 'from'"
                 Nothing -> err True 3 "Query missing 'from'"
  writer <- case lookup "to" pairs of
                 Just x  -> case lookup x writers of
                                 Just y  -> return y
                                 Nothing -> err True 7 "Unsupported value of 'to'"
                 Nothing -> err True 3 "Query missing 'to'"
  let inline = isJust $ lookup "inline" pairs
  putStr "Content-type: text/json; charset=UTF-8\n\n"
  case reader inp of
        Left msg -> err True 1 msg
        Right v  -> B.putStr $ encode $ object
                       [ Text.pack "success" .=
                       ensureFinalNewline (output
                        (if inline
                            then DisplayInline
                            else DisplayBlock) writer v) ]
  exitWith ExitSuccess
