-----------------------------------------------------------------------------
-- |
-- Module      :  Main
-- Copyright   :  (c) David Himmelstrup 2005
-- License     :  BSD-like
--
-- Maintainer  :  lemmih@gmail.com
-- Stability   :  provisional
-- Portability :  portable
--
-- Entry point to the default cabal-install front-end.
-----------------------------------------------------------------------------

module Main where

import Hackage.Setup
import Distribution.Simple.Setup (Flag(..), fromFlag, fromFlagOrDefault,
                                  flagToMaybe,SDistFlags,sdistCommand)
import qualified Distribution.Simple.Setup as Cabal
import Distribution.Simple.Program (defaultProgramConfiguration)
import Distribution.Simple.Command
import Distribution.Simple.SetupWrapper (setupWrapper)
import Distribution.Simple.Configure (configCompilerAux)
import Distribution.Simple.Utils (cabalVersion, die, intercalate)
import Distribution.Text
         ( display )

import Hackage.Config           (SavedConfig(..), savedConfigToConfigFlags,
                                 defaultConfigFile, loadConfig, configRepos,
                                 configPackageDB)
import Hackage.List             (list)
import Hackage.Install          (install)
import Hackage.Update           (update)
import Hackage.Upgrade          (upgrade)
import Hackage.Fetch            (fetch)
import Hackage.Check as Check   (check)
--import Hackage.Clean            (clean)
import Hackage.Upload as Upload (upload, check)
import Hackage.SrcDist(sdist)

import Distribution.Verbosity   (Verbosity, normal)
import qualified Paths_cabal_install (version)

import System.Environment       (getArgs, getProgName)
import System.Exit              (exitFailure)
import System.FilePath          (splitExtension, takeExtension)
import System.Directory         (doesFileExist)
import Data.List                (intersperse)
import Data.Monoid              (Monoid(..))
import Control.Monad            (unless)

-- | Entry point
--
main :: IO ()
main = getArgs >>= mainWorker

mainWorker :: [String] -> IO ()
mainWorker args = 
  case commandsRun globalCommand commands args of
    CommandHelp   help                 -> printHelp help
    CommandList   opts                 -> printOptionsList opts
    CommandErrors errs                 -> printErrors errs
    CommandReadyToGo (flags, commandParse)  ->
      case commandParse of
        _ | fromFlag (globalVersion flags)        -> printVersion
          | fromFlag (globalNumericVersion flags) -> printNumericVersion
        CommandHelp     help           -> printHelp help
        CommandList     opts           -> printOptionsList opts
        CommandErrors   errs           -> printErrors errs
        CommandReadyToGo action        -> action

  where
    printHelp help = getProgName >>= putStr . help
    printOptionsList = putStr . unlines
    printErrors errs = do
      putStr (concat (intersperse "\n" errs))
      exitFailure
    printNumericVersion = putStrLn $ display Paths_cabal_install.version
    printVersion        = putStrLn $ "cabal-install version "
                                  ++ display Paths_cabal_install.version
                                  ++ "\nusing version "
                                  ++ display cabalVersion
                                  ++ " of the Cabal library "

    commands =
      [configureCommand       `commandAddAction` configureAction
      ,installCommand         `commandAddAction` installAction
      ,listCommand            `commandAddAction` listAction
      ,updateCommand          `commandAddAction` updateAction
      ,upgradeCommand         `commandAddAction` upgradeAction
      ,fetchCommand           `commandAddAction` fetchAction
      ,uploadCommand          `commandAddAction` uploadAction
      ,checkCommand           `commandAddAction` checkAction
      ,sdistCommand           `commandAddAction` sdistAction
      ,wrapperAction (Cabal.buildCommand     defaultProgramConfiguration)
      ,wrapperAction Cabal.copyCommand
      ,wrapperAction Cabal.haddockCommand
      ,wrapperAction Cabal.cleanCommand
--      ,wrapperAction Cabal.sdistCommand
      ,wrapperAction Cabal.hscolourCommand
      ,wrapperAction Cabal.registerCommand
--      ,wrapperAction unregisterCommand
      ,wrapperAction Cabal.testCommand
--      ,wrapperAction programaticaCommand
--      ,wrapperAction makefileCommand
      ]

wrapperAction :: Monoid flags => CommandUI flags -> Command (IO ())
wrapperAction command =
  commandAddAction command $ \flags extraArgs ->
  let args = commandName command : commandShowOptions command flags ++ extraArgs
   in setupWrapper args Nothing

configureAction :: Cabal.ConfigFlags -> [String] -> IO ()
configureAction flags extraArgs = do
  configFile <- defaultConfigFile --FIXME
  let verbosity = fromFlagOrDefault normal (Cabal.configVerbosity flags)
  config <- loadConfig verbosity configFile
  let flags' = savedConfigToConfigFlags (Cabal.configUserInstall flags) config
               `mappend` flags
      args = commandName configureCommand
           : commandShowOptions configureCommand flags' ++ extraArgs
  setupWrapper args Nothing

installAction :: (Cabal.ConfigFlags, InstallFlags) -> [String] -> IO ()
installAction (_,iflags) _
  | Cabal.fromFlag (installOnly iflags) = setupWrapper ["install"] Nothing

installAction (cflags,iflags) extraArgs = do
  pkgs <- either die return (parsePackageArgs extraArgs)
  configFile <- defaultConfigFile --FIXME
  let verbosity = fromFlagOrDefault normal (Cabal.configVerbosity cflags)
  config <- loadConfig verbosity configFile
  let cflags' = savedConfigToConfigFlags (Cabal.configUserInstall cflags) config
               `mappend` cflags
  (comp, conf) <- configCompilerAux cflags'
  install verbosity
          (configPackageDB cflags') (configRepos config)
          comp conf cflags' iflags pkgs

listAction :: ListFlags -> [String] -> IO ()
listAction listFlags extraArgs = do
  configFile <- defaultConfigFile --FIXME
  let verbosity = fromFlag (listVerbosity listFlags)
  config <- loadConfig verbosity configFile
  let flags = savedConfigToConfigFlags NoFlag config
  (comp, conf) <- configCompilerAux flags
  list verbosity
       (configPackageDB flags)
       (configRepos config)
       comp
       conf
       listFlags
       extraArgs

updateAction :: Flag Verbosity -> [String] -> IO ()
updateAction verbosityFlag _extraArgs = do
  configFile <- defaultConfigFile --FIXME
  let verbosity = fromFlag verbosityFlag
  config <- loadConfig verbosity configFile
  update verbosity (configRepos config)

upgradeAction :: (Cabal.ConfigFlags, InstallFlags) -> [String] -> IO ()
upgradeAction (cflags,iflags) _extraArgs = do
  configFile <- defaultConfigFile --FIXME
  let verbosity = fromFlagOrDefault normal (Cabal.configVerbosity cflags)
  config <- loadConfig verbosity configFile
  let cflags' = savedConfigToConfigFlags (Cabal.configUserInstall cflags) config
               `mappend` cflags
  (comp, conf) <- configCompilerAux cflags'
  upgrade verbosity
          (configPackageDB cflags') (configRepos config)
          comp conf cflags' iflags

fetchAction :: Flag Verbosity -> [String] -> IO ()
fetchAction verbosityFlag extraArgs = do
  pkgs <- either die return (parsePackageArgs extraArgs)
  configFile <- defaultConfigFile --FIXME
  let verbosity = fromFlag verbosityFlag
  config <- loadConfig verbosity configFile
  let flags = savedConfigToConfigFlags NoFlag config
  (comp, conf) <- configCompilerAux flags
  fetch verbosity
        (configPackageDB flags) (configRepos config)
        comp conf pkgs

uploadAction :: UploadFlags -> [String] -> IO ()
uploadAction flags extraArgs = do
  configFile <- defaultConfigFile --FIXME
  let verbosity = fromFlag (uploadVerbosity flags)
  config <- loadConfig verbosity configFile
  -- FIXME: check that the .tar.gz files exist and report friendly error message if not
  let tarfiles = extraArgs
  checkTarFiles tarfiles
  if fromFlag (uploadCheck flags)
    then Upload.check  verbosity tarfiles
    else upload verbosity 
                (flagToMaybe $ configUploadUsername config
                     `mappend` uploadUsername flags)
                (flagToMaybe $ configUploadPassword config
                     `mappend` uploadPassword flags)
                tarfiles
  where
    checkTarFiles tarfiles
      | null tarfiles
      = die "the 'upload' command expects one or more .tar.gz packages."
      | not (null otherFiles)
      = die $ "the 'upload' command expects only .tar.gz packages: "
           ++ intercalate ", " otherFiles
      | otherwise = sequence_
                      [ do exists <- doesFileExist tarfile
                           unless exists $ die $ "file not found: " ++ tarfile
                      | tarfile <- tarfiles ]

      where otherFiles = filter (not . isTarGzFile) tarfiles
            isTarGzFile file = case splitExtension file of
              (file', ".gz") -> takeExtension file' == ".tar"
              _              -> False

checkAction :: Flag Verbosity -> [String] -> IO ()
checkAction verbosityFlag extraArgs = do
  unless (null extraArgs) $ do
    die $ "'check' doesn't take any extra arguments: " ++ unwords extraArgs
  allOk <- Check.check (fromFlag verbosityFlag)
  unless allOk exitFailure


sdistAction :: SDistFlags -> [String] -> IO ()
sdistAction sflags extraArgs = do
  unless (null extraArgs) $ do
    die $ "'sdist' doesn't take any extra arguments: " ++ unwords extraArgs
  sdist sflags