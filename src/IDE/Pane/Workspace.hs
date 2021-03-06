{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE TypeSynonymInstances #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE OverloadedStrings #-}
-----------------------------------------------------------------------------
--
-- Module      :  IDE.Pane.Workspace
-- Copyright   :  2007-2011 Juergen Nicklisch-Franken, Hamish Mackenzie
-- License     :  GPL
--
-- Maintainer  :  maintainer@leksah.org
-- Stability   :  provisional
-- Portability :
--
-- | The pane of the IDE that shows the cabal packages in the workspace
--   and their build targets
--
-----------------------------------------------------------------------------

module IDE.Pane.Workspace (
    WorkspaceState(..)
,   IDEWorkspace
,   updateWorkspace
,   getWorkspace
,   showWorkspace
) where

import Graphics.UI.Gtk hiding (get)
import Graphics.UI.Gtk.Gdk.EventM
import Data.Maybe
import Data.Typeable
import IDE.Core.State
import IDE.Workspaces
import qualified Data.Map as Map (empty)
import Data.List (sortBy)
import IDE.Pane.Files (refreshFiles)
import Control.Monad (when)
import Control.Monad.IO.Class (MonadIO(..))
import IDE.Utils.GUIUtils (treeViewContextMenu, __)
import System.Glib.Properties (newAttrFromMaybeStringProperty)
import Data.Tree (Tree(..))
import System.Log.Logger (debugM)
import qualified Data.Function as F (on)
import System.FilePath (takeDirectory, takeBaseName, takeFileName)
import Data.Text (Text)
import qualified Data.Text as T (pack)

-- | Workspace pane state
--

-- | The data in a row displays a package or an
--   executable of that package (in the first case
--   the path to the package is also stored)
type WorkspaceRecord = (IDEPackage, Maybe Text)


-- | The representation of the workspace pane
data IDEWorkspace   =   IDEWorkspace {
    scrolledView        ::   ScrolledWindow
,   treeViewC           ::   TreeView
,   workspaceStore      ::   TreeStore (Bool, WorkspaceRecord)
,   topBox              ::   VBox
} deriving Typeable

instance Pane IDEWorkspace IDEM
    where
    primPaneName _  =   __ "Workspace"
    getAddedIndex _ =   0
    getTopWidget    =   castToWidget . topBox
    paneId b        =   "*Workspace"

-- | The additional state used when recovering the pane
--   (none, the packages and their targets come from the IDE state)
data WorkspaceState           =   WorkspaceState
    deriving(Eq,Ord,Read,Show,Typeable)

instance RecoverablePane IDEWorkspace WorkspaceState IDEM where
    saveState p     =   return (Just WorkspaceState)
    recoverState pp WorkspaceState =   do
        nb      <-  getNotebook pp
        buildPane pp nb builder
    buildPane pp nb builder  =   do
        res <- buildThisPane pp nb builder
        when (isJust res) $ updateWorkspace True False
        return res
    builder pp nb windows = reifyIDE $ \ideR -> do
        treeStore   <-  treeStoreNew []
        treeView    <-  treeViewNew
        treeViewSetModel treeView treeStore

        renderer0    <- cellRendererPixbufNew
        set renderer0 [ newAttrFromMaybeStringProperty "stock-id"  := (Nothing :: Maybe Text) ]

        renderer1   <- cellRendererTextNew
        col1        <- treeViewColumnNew
        treeViewColumnSetTitle col1 (__ "Package")
        treeViewColumnSetSizing col1 TreeViewColumnAutosize
        treeViewColumnSetResizable col1 True
        treeViewColumnSetReorderable col1 True
        treeViewAppendColumn treeView col1
        cellLayoutPackStart col1 renderer0 False
        cellLayoutPackStart col1 renderer1 True
        cellLayoutSetAttributes col1 renderer0 treeStore
            $ \row -> [newAttrFromMaybeStringProperty "stock-id" :=
                        if fst row
                            then Just stockYes
                            else Nothing]
        cellLayoutSetAttributes col1 renderer1 treeStore
            $ \row -> [ cellText := name row ]

        renderer2   <- cellRendererTextNew
        col2        <- treeViewColumnNew
        treeViewColumnSetTitle col2 (__ "File path")
        treeViewColumnSetSizing col2 TreeViewColumnAutosize
        treeViewColumnSetResizable col2 True
        treeViewColumnSetReorderable col2 True
        treeViewAppendColumn treeView col2
        cellLayoutPackStart col2 renderer2 True
        cellLayoutSetAttributes col2 renderer2 treeStore
            $ \row -> [ cellText := T.pack $ file row ]

        treeViewSetHeadersVisible treeView True
        sel <- treeViewGetSelection treeView
        treeSelectionSetMode sel SelectionSingle

        sw <- scrolledWindowNew Nothing Nothing
        scrolledWindowSetShadowType sw ShadowIn
        containerAdd sw treeView
        scrolledWindowSetPolicy sw PolicyAutomatic PolicyAutomatic
        box             <-  vBoxNew False 2
        boxPackEnd box sw PackGrow 0
        let workspacePane = IDEWorkspace sw treeView treeStore box
        widgetShowAll box
        cid1 <- treeView `after` focusInEvent $ do
            liftIO $ reflectIDE (makeActive workspacePane) ideR
            return True
        (cid2, cid3) <- treeViewContextMenu treeView $ workspaceContextMenu ideR workspacePane
        cid4 <- treeView `on` rowActivated $ workspaceSelect ideR workspacePane
        return (Just workspacePane, map ConnectC [cid1, cid2, cid3, cid4])
      where
        name (_, (_, Just exe)) = exe
        name (_, (pack, Nothing)) = packageIdentifierToString $ ipdPackageId pack
        file (_, (_, Just _)) = ""
        file (_, (pack, _)) = ipdCabalFile pack

-- | Get the workspace pane
getWorkspace :: Maybe PanePath -> IDEM IDEWorkspace
getWorkspace Nothing = forceGetPane (Right "*Workspace")
getWorkspace (Just pp)  = forceGetPane (Left pp)

-- | Show the workspace pane
showWorkspace :: IDEAction
showWorkspace = do
    l <- getWorkspace Nothing
    displayPane l False

-- | Try to get the current selected record and whether
--   it is selected
getSelectionTree ::  TreeView
    -> TreeStore (Bool, WorkspaceRecord)
    -> IO (Maybe (Bool, IDEPackage, Maybe Text))
getSelectionTree treeView treeStore = do
    liftIO $ debugM "leksah" "getSelectionTree"
    treeSelection <- treeViewGetSelection treeView
    rows          <- treeSelectionGetSelectedRows treeSelection
    case rows of
        [path]  ->  do
            val     <-  treeStoreGetValue treeStore path
            case val of
                (active, (p, exe)) -> return $ Just (active, p, exe)
        _       ->  return Nothing


-- | Construct the context menu for the pane
workspaceContextMenu :: IDERef
                     -> IDEWorkspace
                     -> Menu
                     -> IO ()
workspaceContextMenu ideR workspacePane theMenu = do
    item1 <- menuItemNewWithLabel (__ "Activate Package")
    item2 <- menuItemNewWithLabel (__ "Add Package")
    item3 <- menuItemNewWithLabel (__ "Remove Package")
    item1 `on` menuItemActivate $ do
        sel <- getSelectionTree (treeViewC workspacePane)
                                (workspaceStore workspacePane)
        case sel of
            Just (_, ideP,mbExe) -> reflectIDE (workspaceTry $ workspaceActivatePackage ideP mbExe) ideR
            otherwise     -> return ()
    item2 `on` menuItemActivate $ reflectIDE (workspaceTry workspaceAddPackage) ideR
    item3 `on` menuItemActivate $ do
        sel <- getSelectionTree (treeViewC workspacePane)
                                (workspaceStore workspacePane)
        case sel of
            Just (_,ideP,_) -> reflectIDE (workspaceTry $ workspaceRemovePackage ideP) ideR
            otherwise     -> return ()
    menuShellAppend theMenu item1
    menuShellAppend theMenu item2
    menuShellAppend theMenu item3


-- | Try to activate the package pointed to by the given 'TreePath'
--   by modifying the given IDE state
workspaceSelect :: IDERef
                -> IDEWorkspace
                -> TreePath
                -> TreeViewColumn
                -> IO ()
workspaceSelect ideR workspacePane path _ = do
    liftIO $ debugM "leksah" "workspaceSelect"
    (_,(ideP,mbExe)) <- treeStoreGetValue (workspaceStore workspacePane) path
    reflectIDE (workspaceTry $ workspaceActivatePackage ideP mbExe) ideR


-- | Repopulates the workspace pane with the current packages
--   (if the pane is open)
updateWorkspace :: Bool -- ^ Show the pane if it is open and a workspace is loaded
                -> Bool -- ^ Empty the 'bufferProjCache'
                -> IDEAction
updateWorkspace showPane updateFileCache = do
    liftIO $ debugM "leksah" "updateWorkspace"
    mbWs <- readIDE workspace
    when updateFileCache $ modifyIDE_ (\ide -> ide{bufferProjCache = Map.empty})
    mbMod <- getPane
    case mbWs of
        Nothing -> do
            case mbMod of
                Nothing -> return ()
                Just (p :: IDEWorkspace) -> do
                    liftIO $ treeStoreClear (workspaceStore p)
                    when showPane $ displayPane p False
            refreshFiles
        Just ws -> do
            case mbMod of
                Nothing -> return ()
                Just (p :: IDEWorkspace) -> do
                    liftIO $ do
                        treeStoreClear (workspaceStore p)
                        treeStoreInsertForest (workspaceStore p) [] 0 (buildForest ws)
                    when showPane $ displayPane p False
            refreshFiles
    where
        -- | Given a workspace, constructs the forest of
        --   packages and their targets
        buildForest ws =
            let sorted = sortBy (compare `F.on` ipdPackageId) $ wsPackages ws
            in  map (buildPackageTree ws) sorted

        -- | Given an ide package, constructs the tree with the
        --   package as root node, and its targets as children
        buildPackageTree ws ideP =
            let isActive = Just (ipdCabalFile ideP) == wsActivePackFile ws
                sandboxChildren = map (\pack -> Node (False, (pack, Nothing)) [])
                                      (ipdSandboxSources ideP)
                targetsChildren = map (\test -> Node (
                                           Just (ipdCabalFile ideP) == wsActivePackFile ws &&
                                           Just test == wsActiveExe ws, (ideP, Just test)) [])
                                      (ipdExes ideP ++ ipdTests ideP ++ ipdBenchmarks ideP)
            in  Node (isActive, (ideP, Nothing))
                     (sandboxChildren ++ targetsChildren)