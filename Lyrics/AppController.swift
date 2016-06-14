//
//  AppController.swift
//  Lyrics
//
//  Created by Eru on 15/11/10.
//  Copyright © 2015年 Eru. All rights reserved.
//

import Cocoa
import ScriptingBridge

class AppController: NSObject, NSUserNotificationCenterDelegate {
    
    //Singleton
    static let sharedController = AppController()
    
    @IBOutlet weak var statusBarMenu: NSMenu!
    @IBOutlet weak var lyricsDelayView: NSView!
    @IBOutlet weak var delayMenuItem: NSMenuItem!
    @IBOutlet weak var lyricsHeightMenuItem: NSMenuItem!
    @IBOutlet weak var presetMenuItem: NSMenuItem!
    
    var timeDly: Int = 0
    var timeDlyInFile: Int = 0
    var lockFloatingWindow: Bool = false
    
    private var isTrackingRunning: Bool = false
    private var hasDiglossiaLrc: Bool = false
    private var lyricsWindow: DesktopLyricsController!
    private var menuBarLyrics: MenuBarLyrics!
    private var statusItem: NSStatusItem!
    private var lyricsArray: [LyricsLineModel]!
    private var idTagsArray: [String]!
    private var iTunes: iTunesBridge!
    private var currentLyrics: String!
    private var defaultLyrics: String!
    private var currentSongID: String!
    private var currentSongTitle: String!
    private var currentArtist: String!
    private var lrcParser: LrcParser!
    private var songList: [SongInfos]!
    private var qianqian: QianQian!
    private var xiami: Xiami!
    private var ttpod: TTPod!
    private var geciMe: GeCiMe!
    private var qqMusic: QQMusic!
    private var lrcSourceHandleQueue: NSOperationQueue!
    private var userDefaults: NSUserDefaults!
    private var timer: NSTimer!
    
// MARK: - Init & deinit
    override private init() {
        super.init()
        iTunes = iTunesBridge()
        defaultLyrics = iTunes.defaultLyrics()
        lrcParser = LrcParser()
        lyricsArray = Array()
        idTagsArray = Array()
        songList = Array()
        qianqian = QianQian()
        xiami = Xiami()
        ttpod = TTPod()
        geciMe = GeCiMe()
        qqMusic = QQMusic()
        userDefaults = NSUserDefaults.standardUserDefaults()
        lrcSourceHandleQueue = NSOperationQueue()
        lrcSourceHandleQueue.maxConcurrentOperationCount = 1
        
        NSBundle(forClass: object_getClass(self)).loadNibNamed("StatusMenu", owner: self, topLevelObjects: nil)
        
        // init desktop lyrics and menu lyrics
        lyricsWindow = DesktopLyricsController.sharedController
        lyricsWindow.showWindow(nil)
        if userDefaults.boolForKey(LyricsMenuBarLyricsEnabled) {
            menuBarLyrics = MenuBarLyrics()
        }
        
        setupStatusItem()
        checkLrcSavingPath()
        setupShortcuts()
        addNotificationObserver()
        trackingStatusInitiation()
    }
    
    deinit {
        NSStatusBar.systemStatusBar().removeStatusItem(statusItem)
        NSNotificationCenter.defaultCenter().removeObserver(self)
        NSDistributedNotificationCenter.defaultCenter().removeObserver(self)
    }
    
    private func setupStatusItem() {
        let icon:NSImage = NSImage(named: "status_icon")!
        icon.template = true
        statusItem = NSStatusBar.systemStatusBar().statusItemWithLength(NSSquareStatusItemLength)
        statusItem.menu = statusBarMenu
        if #available(OSX 10.10, *) {
            statusItem.button?.image = icon
        } else {
            statusItem.image = icon
            statusItem.highlightMode = true
        }
    
        delayMenuItem.view = lyricsDelayView
        lyricsDelayView.autoresizingMask = [.ViewWidthSizable]
    }
    
    private func checkLrcSavingPath() {
        if !userDefaults.boolForKey(LyricsDisableAllAlert) {
            let savingPath: String
            if userDefaults.integerForKey(LyricsSavingPathPopUpIndex) == 0 {
                savingPath = NSSearchPathForDirectoriesInDomains(.MusicDirectory, [.UserDomainMask], true).first! + "/LyricsX"
            } else {
                savingPath = userDefaults.stringForKey(LyricsUserSavingPath)!
            }
            
            let fm: NSFileManager = NSFileManager.defaultManager()
            var isDir: ObjCBool = true
            if fm.fileExistsAtPath(savingPath, isDirectory: &isDir) {
                //歌词保存路径是非文件夹，弹出警示
                if !isDir {
                    userDefaults.removeObjectForKey(LyricsUserSavingPath)
                    userDefaults.removeObjectForKey(LyricsSavingPathPopUpIndex)
                    let alert: NSAlert = NSAlert()
                    alert.messageText = NSLocalizedString("ERROR_OCCUR", comment: "")
                    alert.informativeText = NSLocalizedString("PATH_IS_NOT_DIR", comment: "")
                    alert.addButtonWithTitle(NSLocalizedString("OPEN_PREFS", comment: ""))
                    let response: NSModalResponse = alert.runModal()
                    if response == NSAlertFirstButtonReturn {
                        dispatch_async(dispatch_get_main_queue(), {
                            self.showPreferences(nil)
                        })
                    }
                }
            } else {
                //歌词保存路径没有文件夹，创建一个
                do {
                    try fm.createDirectoryAtPath(savingPath, withIntermediateDirectories: true, attributes: nil)
                } catch let theError as NSError{
                    NSLog("%@", theError.localizedDescription)
                }
            }
        }
    }
    
    private func addNotificationObserver() {
        let nc = NSNotificationCenter.defaultCenter()
        nc.addObserver(self, selector: #selector(lrcLoadingCompleted(_:)), name: LrcLoadedNotification, object: nil)
        nc.addObserver(self, selector: #selector(handleUserEditLyrics(_:)), name: LyricsUserEditLyricsNotification, object: nil)
        nc.addObserver(self, selector: #selector(handlePresetDidChanged), name: LyricsPresetDidChangedNotification, object: nil)
        
        let ndc = NSDistributedNotificationCenter.defaultCenter()
        ndc.addObserver(self, selector: #selector(iTunesPlayerInfoChanged(_:)), name: "com.apple.iTunes.playerInfo", object: nil)
        ndc.addObserver(self, selector: #selector(handleExtenalLyricsEvent(_:)), name: "ExtenalLyricsEvent", object: nil)
    }
    
    private func trackingStatusInitiation() {
        currentLyrics = "LyricsX"
        if iTunes.running() && iTunes.playing() {
            currentSongID = iTunes.currentPersistentID()
            currentSongTitle = iTunes.currentTitle()
            currentArtist = iTunes.currentArtist()
            defaultLyrics = iTunes.defaultLyrics()
            if currentSongID == "" {
                // If iTunes is playing Apple Music, nothing can get from API,
                // so, we should pause and then play to force iTunes send
                // distributed notification.
                iTunes.pause()
                iTunes.play()
            }
            else {
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0)) { () -> Void in
                    self.handleSongChange()
                }
                
                NSLog("Create new iTunesTrackingThead")
                isTrackingRunning = true
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0)) { () -> Void in
                    self.iTunesTrackingThread()
                }
            }
        }
        else {
            currentSongID = ""
            currentSongTitle = ""
            currentArtist = ""
        }
    }
    
// MARK: - Shortcut Events
    
    private func setupShortcuts() {
        // Default shortcuts
        let offsetIncr: MASShortcut = MASShortcut(keyCode: UInt(kVK_ANSI_Equal), modifierFlags: NSEventModifierFlags.CommandKeyMask.rawValue | NSEventModifierFlags.AlternateKeyMask.rawValue)
        let offsetDecr: MASShortcut = MASShortcut(keyCode: UInt(kVK_ANSI_Minus), modifierFlags: NSEventModifierFlags.CommandKeyMask.rawValue | NSEventModifierFlags.AlternateKeyMask.rawValue)
        let defaultShortcuts = [ShortcutOffsetIncr : offsetIncr,
                                ShortcutOffsetDecr : offsetDecr]
        MASShortcutBinder.sharedBinder().registerDefaultShortcuts(defaultShortcuts)
        
        //Bind actions to User Default keys
        MASShortcutBinder.sharedBinder().bindShortcutWithDefaultsKey(ShortcutOffsetIncr) {
            self.increaseTimeDly()
        }
        MASShortcutBinder.sharedBinder().bindShortcutWithDefaultsKey(ShortcutOffsetDecr) {
            self.decreaseTimeDly()
        }
        MASShortcutBinder.sharedBinder().bindShortcutWithDefaultsKey(ShortcutLyricsModeSwitch) { () -> Void in
            let userDefaults = NSUserDefaults.standardUserDefaults()
            userDefaults.setBool(!userDefaults.boolForKey(LyricsIsVerticalLyrics), forKey: LyricsIsVerticalLyrics)
            dispatch_async(dispatch_get_main_queue(), { () -> Void in
                DesktopLyricsController.sharedController.reflash()
            })
        }
        MASShortcutBinder.sharedBinder().bindShortcutWithDefaultsKey(ShortcutDesktopMenubarSwitch) { () -> Void in
            self.switchDesktopMenuBarMode()
        }
        MASShortcutBinder.sharedBinder().bindShortcutWithDefaultsKey(ShortcutOpenLrcSeeker) { () -> Void in
            self.searchLyricsAndArtworks(nil)
        }
        MASShortcutBinder.sharedBinder().bindShortcutWithDefaultsKey(ShortcutCopyLrcToPb) { () -> Void in
            self.copyLyricsToPb(nil)
        }
        MASShortcutBinder.sharedBinder().bindShortcutWithDefaultsKey(ShortcutEditLrc) { () -> Void in
            self.editLyrics(nil)
        }
        MASShortcutBinder.sharedBinder().bindShortcutWithDefaultsKey(ShortcutMakeLrc) { () -> Void in
            self.makeLrc(nil)
        }
        MASShortcutBinder.sharedBinder().bindShortcutWithDefaultsKey(ShortcutWriteLrcToiTunes) { () -> Void in
            self.writeLyricsToiTunes(nil)
        }
    }
    
    private func increaseTimeDly() {
        self.willChangeValueForKey("timeDly")
        timeDly += 100
        if timeDly > 10000 {
            timeDly = 10000
        }
        self.didChangeValueForKey("timeDly")
        let message: String = String(format: NSLocalizedString("OFFSET", comment: ""), timeDly)
        MessageWindowController.sharedMsgWindow.displayMessage(message)
    }
    
    private func decreaseTimeDly() {
        self.willChangeValueForKey("timeDly")
        timeDly -= 100
        if timeDly < -10000 {
            timeDly = -10000
        }
        self.didChangeValueForKey("timeDly")
        let message: String = String(format: NSLocalizedString("OFFSET", comment: ""), timeDly)
        MessageWindowController.sharedMsgWindow.displayMessage(message)
    }
    
    private func switchDesktopMenuBarMode() {
        let isDesktopLyricsOn = userDefaults.boolForKey(LyricsDesktopLyricsEnabled)
        let isMenuBarLyricsOn = userDefaults.boolForKey(LyricsMenuBarLyricsEnabled)
        if isDesktopLyricsOn && isMenuBarLyricsOn {
            userDefaults.setBool(false, forKey: LyricsMenuBarLyricsEnabled)
            MessageWindowController.sharedMsgWindow.displayMessage(NSLocalizedString("DESKTOP_ON", comment: ""))
            menuBarLyrics = nil
        }
        else if isDesktopLyricsOn && !isMenuBarLyricsOn {
            userDefaults.setBool(false, forKey: LyricsDesktopLyricsEnabled)
            userDefaults.setBool(true, forKey: LyricsMenuBarLyricsEnabled)
            MessageWindowController.sharedMsgWindow.displayMessage(NSLocalizedString("MENU_BAR_ON", comment: ""))
            menuBarLyrics = MenuBarLyrics()
            dispatch_async(dispatch_get_main_queue(), {
                self.lyricsWindow.displayLyrics(nil, secondLyrics: nil)
                self.menuBarLyrics.displayLyrics(self.currentLyrics)
            })
        }
        else {
            userDefaults.setBool(true, forKey: LyricsDesktopLyricsEnabled)
            MessageWindowController.sharedMsgWindow.displayMessage(NSLocalizedString("BOTH_ON", comment: ""))
            // Force update both
            currentLyrics = nil
        }
    }
    
// MARK: - Interface Methods
    
    @IBAction func handleWorkSpaceChange(sender:AnyObject?) {
        //before finding the way to detect full screen, user should adjust lyrics by self
        lyricsWindow.isFullScreen = !lyricsWindow.isFullScreen
        if lyricsWindow.isFullScreen {
            lyricsHeightMenuItem.title = NSLocalizedString("HIGHER_LYRICS", comment: "")
        } else {
            lyricsHeightMenuItem.title = NSLocalizedString("LOWER_LYRICS", comment: "")
        }
        dispatch_async(dispatch_get_main_queue()) { () -> Void in
            self.lyricsWindow.reflash()
        }
    }
    
    @IBAction func enableDesktopLyrics(sender:AnyObject?) {
        if (sender as! NSMenuItem).state == NSOnState {
            dispatch_async(dispatch_get_main_queue(), { () -> Void in
                self.lyricsWindow.displayLyrics(nil, secondLyrics: nil)
            })
        } else {
            //Force lyrics to show(handlePositionChange method will update it if lyrics changed.)
            currentLyrics = nil
        }
    }
    
    @IBAction func enableMenuBarLyrics(sender:AnyObject?) {
        if (sender as! NSMenuItem).state == NSOnState {
            menuBarLyrics = nil
        } else {
            menuBarLyrics = MenuBarLyrics()
            dispatch_async(dispatch_get_main_queue(), { 
                self.menuBarLyrics.displayLyrics(self.currentLyrics)
            })
        }
    }
    
    @IBAction func changeLyricsMode(sender:AnyObject?) {
        dispatch_async(dispatch_get_main_queue()) { () -> Void in
            self.lyricsWindow.reflash()
        }
    }
    
    @IBAction func showAboutWindow(sender: AnyObject?) {
        AboutWindowController.sharedController.showWindow(nil)
    }
    
    @IBAction func showDonate(sender: AnyObject?) {
        let windowController = AboutWindowController.sharedController
        windowController.showWindow(nil)
        windowController.showDonate(nil)
    }
    
    @IBAction func showPreferences(sender:AnyObject?) {
        let prefs = AppPrefsWindowController.sharedPrefsWindowController
        if !(prefs.window?.visible)! {
            prefs.showWindow(nil)
        }
        prefs.window?.makeKeyAndOrderFront(nil)
        NSApp.activateIgnoringOtherApps(true)
    }
    
    @IBAction func checkForUpdate(sender: AnyObject) {
        NSWorkspace.sharedWorkspace().openURL(NSURL(string: "https://github.com/MichaelRow/Lyrics/releases")!)
    }
    
    @IBAction func exportArtwork(sender: AnyObject) {
        let artworkData: NSData? = iTunes.artwork()
        if artworkData == nil {
            MessageWindowController.sharedMsgWindow.displayMessage(NSLocalizedString("NO_ARTWORK", comment: ""))
            return
        }
        let panel = NSSavePanel()
        panel.allowedFileTypes = ["png",  "jpg", "jpf", "bmp", "gif", "tiff"]
        panel.nameFieldStringValue = currentSongTitle + " - " + currentArtist
        panel.extensionHidden = true
        if panel.runModal() == NSFileHandlingPanelOKButton {
            artworkData!.writeToURL(panel.URL!, atomically: false)
        }
    }
    
    @IBAction func searchLyricsAndArtworks(sender: AnyObject?) {
        let appPath = NSBundle.mainBundle().bundlePath + "/Contents/Library/LrcSeeker.app"
        NSWorkspace.sharedWorkspace().launchApplication(appPath)
    }
    
    @IBAction func copyLyricsToPb(sender: AnyObject?) {
        if lyricsArray.count == 0 {
            MessageWindowController.sharedMsgWindow.displayMessage(NSLocalizedString("OPERATION_FAILED", comment: ""))
            return
        }
        var theLyrics: String = String()
        var hasSpace: Bool = false
        for lrc in lyricsArray {
            if lrc.lyricsSentence.stringByReplacingOccurrencesOfString(" ", withString: "") == "" {
                if hasSpace {
                    continue
                }
                else {
                    hasSpace = true
                }
            }
            else if hasSpace {
                hasSpace = false
            }
            if lrc.enabled {
                theLyrics.appendContentsOf(lrc.lyricsSentence + "\n")
            }
        }
        let pb = NSPasteboard.generalPasteboard()
        pb.clearContents()
        pb.writeObjects([theLyrics])
        MessageWindowController.sharedMsgWindow.displayMessage(NSLocalizedString("COPYED_TO_PB", comment: ""))
    }
    
    @IBAction func copyLyricsWithTagsToPb(sender: AnyObject) {
        let lrcContents = readLocalLyrics(currentSongTitle, theArtist: currentArtist)
        if lrcContents != nil && lrcContents != "" {
            let pb = NSPasteboard.generalPasteboard()
            pb.clearContents()
            pb.writeObjects([lrcContents!])
            MessageWindowController.sharedMsgWindow.displayMessage(NSLocalizedString("COPYED_TO_PB", comment: ""))
        } else {
            MessageWindowController.sharedMsgWindow.displayMessage(NSLocalizedString("OPERATION_FAILED", comment: ""))
        }
    }
    
    @IBAction func makeLrc(sender: AnyObject?) {
        let appPath = NSBundle.mainBundle().bundlePath + "/Contents/Library/LrcMaker.app"
        NSWorkspace.sharedWorkspace().launchApplication(appPath)
    }
    
    @IBAction func mergeLrc(sender: AnyObject) {
        let appPath = NSBundle.mainBundle().bundlePath + "/Contents/Library/LrcMerger.app"
        NSWorkspace.sharedWorkspace().launchApplication(appPath)
    }
    
    @IBAction func editLyrics(sender: AnyObject?) {
        var lrcContents = readLocalLyrics(currentSongTitle, theArtist: currentArtist)
        if lrcContents == nil {
            lrcContents = ""
        }
        let windowController = LyricsEditWindowController.sharedController
        windowController.setLyricsContents(lrcContents!, songID: currentSongID, songTitle: currentSongTitle, andArtist: currentArtist)
        if !windowController.window!.visible {
            windowController.showWindow(nil)
        }
        windowController.window!.makeKeyAndOrderFront(nil)
        NSApp.activateIgnoringOtherApps(true)
    }
    
    @IBAction func importLrcFile(sender: AnyObject) {
        let songTitle: String = currentSongTitle
        let artist: String = currentArtist
        let songID: String = currentSongID
        let panel: NSOpenPanel = NSOpenPanel()
        panel.allowedFileTypes = ["lrc", "txt"]
        panel.extensionHidden = false
        if panel.runModal() == NSFileHandlingPanelOKButton {
            let lrcContents: String!
            do {
                lrcContents = try String(contentsOfURL: panel.URL!, encoding: NSUTF8StringEncoding)

            } catch let theError as NSError {
                lrcContents = nil
                NSLog("%@", theError.localizedDescription)
                
                // Error must be the text encoding thing.
                if !userDefaults.boolForKey(LyricsDisableAllAlert) {
                    let alert: NSAlert = NSAlert()
                    alert.messageText = NSLocalizedString("UNSUPPORTED_ENCODING", comment: "")
                    alert.informativeText = NSLocalizedString("ONLY_UTF8", comment: "")
                    alert.addButtonWithTitle(NSLocalizedString("OK", comment: ""))
                    alert.runModal()
                }
                return
            }
            if lrcContents != nil && lrcParser.testLrc(lrcContents) {
                lrcSourceHandleQueue.cancelAllOperations()
                lrcSourceHandleQueue.addOperationWithBlock({ () -> Void in
                    //make the current lrc the better one so that it can't be replaced.
                    if songID == self.currentSongID {
                        self.parseCurrentLrc(lrcContents)
                        self.hasDiglossiaLrc = true
                    }
                    self.saveLrcToLocal(lrcContents, songTitle: songTitle, artist: artist)
                })
            }
        }
    }
    
    @IBAction func exportLrcFile(sender: AnyObject) {
        let savingPath: String
        if userDefaults.integerForKey(LyricsSavingPathPopUpIndex) == 0 {
            savingPath = NSSearchPathForDirectoriesInDomains(.MusicDirectory, [.UserDomainMask], true).first! + "/LyricsX"
        } else {
            savingPath = userDefaults.stringForKey(LyricsUserSavingPath)!
        }
        let songTitle:String = currentSongTitle.stringByReplacingOccurrencesOfString("/", withString: "&")
        let artist:String = currentArtist.stringByReplacingOccurrencesOfString("/", withString: "&")
        let lrcFilePath = (savingPath as NSString).stringByAppendingPathComponent("\(songTitle) - \(artist).lrc")
        
        let panel: NSSavePanel = NSSavePanel()
        panel.allowedFileTypes = ["lrc","txt"]
        panel.nameFieldStringValue = (lrcFilePath as NSString).lastPathComponent
        panel.extensionHidden = false
        
        if panel.runModal() == NSFileHandlingPanelOKButton {
            let fm = NSFileManager.defaultManager()
            if fm.fileExistsAtPath(panel.URL!.path!) {
                do {
                    try fm.removeItemAtURL(panel.URL!)
                } catch let theError as NSError {
                    NSLog("%@", theError.localizedDescription)
                }
            }
            do {
                try fm.copyItemAtPath(lrcFilePath, toPath: panel.URL!.path!)
            } catch let theError as NSError {
                NSLog("%@", theError.localizedDescription)
            }
        }
    }
    
    @IBAction func writeLyricsToiTunes(sender: AnyObject?) {
        if lyricsArray.count == 0 {
            MessageWindowController.sharedMsgWindow.displayMessage(NSLocalizedString("OPERATION_FAILED", comment: ""))
            return
        } else {
            var theLyrics: String = String()
            for lrc in lyricsArray {
                theLyrics.appendContentsOf(lrc.lyricsSentence + "\n")
            }
            iTunes.setLyrics(theLyrics)
            MessageWindowController.sharedMsgWindow.displayMessage(NSLocalizedString("WROTE_TO_ITUNES", comment: ""))
        }
    }
    
    @IBAction func writeAllLyricsToiTunes(sender: AnyObject?) {
        let skip: Bool
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("OVERRIDE_OR_SKIP", comment: "")
        alert.informativeText = NSLocalizedString("OVERRIDE_OR_SKIP_INTRO", comment: "")
        alert.addButtonWithTitle(NSLocalizedString("SKIP", comment: ""))
        alert.addButtonWithTitle(NSLocalizedString("OVERRIDE", comment: ""))
        alert.addButtonWithTitle(NSLocalizedString("CANCEL", comment: ""))
        switch alert.runModal() {
        case NSAlertFirstButtonReturn:
            skip = true
        case NSAlertSecondButtonReturn:
            skip = false
        default:
            return
        }
        
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_LOW, 0)) { () -> Void in
            if self.iTunes.setAllLyrics(skip) {
                dispatch_async(dispatch_get_main_queue(), { () -> Void in
                    MessageWindowController.sharedMsgWindow.displayMessage(NSLocalizedString("WROTE_TO_ITUNES", comment: ""))
                })
            }
            else {
                dispatch_async(dispatch_get_main_queue(), { () -> Void in
                    MessageWindowController.sharedMsgWindow.displayMessage(NSLocalizedString("OPERATION_FAILED", comment: ""))
                })
            }
        }
    }
    
    @IBAction func wrongLyrics(sender: AnyObject) {
        let songID = currentSongID
        let songTitle = currentSongTitle
        let artist = currentArtist
        if !userDefaults.boolForKey(LyricsDisableAllAlert) {
            let alert: NSAlert = NSAlert()
            alert.messageText = NSLocalizedString("CONFIRM_MARK_WRONG", comment: "")
            alert.informativeText = NSLocalizedString("CANT_UNDONE", comment: "")
            alert.addButtonWithTitle(NSLocalizedString("CANCEL", comment: ""))
            alert.addButtonWithTitle(NSLocalizedString("MARK", comment: ""))
            let response: NSModalResponse = alert.runModal()
            if response == NSAlertFirstButtonReturn {
                return
            }
        }
        let wrongLyricsTag: String = NSLocalizedString("WRONG_LYRICS", comment: "")
        if songID == currentSongID {
            lyricsArray.removeAll()
            currentLyrics = nil
            dispatch_async(dispatch_get_main_queue()) { () -> Void in
                self.lyricsWindow.displayLyrics(nil, secondLyrics: nil)
            }
        }
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0)) { 
            self.saveLrcToLocal(wrongLyricsTag, songTitle: songTitle, artist: artist)
        }
    }

    @IBAction func setAutoLayout(sender: AnyObject?) {
        //Action triggers before NSUserDefaults, so, delay 0.1s 
        if !userDefaults.boolForKey(LyricsUseAutoLayout) {
            lyricsWindow.storeWindowSize()
        }
        lyricsWindow.performSelector(#selector(DesktopLyricsController.checkAutoLayout), withObject: nil, afterDelay: 0.1)
    }
    
    @IBAction func lockLyricsFloatingWindow(sender: AnyObject?) {
        lockFloatingWindow = !lockFloatingWindow
        lyricsWindow.window?.ignoresMouseEvents = lockFloatingWindow
    }
    
    func setPresetByMenu(sender: AnyObject?) {
        if sender is NSMenuItem {
            let index: Int = presetMenuItem.submenu!.indexOfItem(sender as! NSMenuItem)
            if index == -1 {
                return
            }
            let prefs = AppPrefsWindowController.sharedPrefsWindowController
            prefs.presetListView.selectRowIndexes(NSIndexSet(index: index), byExtendingSelection: false)
            prefs.applyPreset(nil)
        }
    }
    
// MARK: - iTunes Events
    
    private func iTunesTrackingThread() {
        // side node: iTunes update playerPosition once per second.
        var iTunesPosition: Int = 0
        var currentPosition: Int = 0
        //No need to track iTunes PlayerPosition when it's paused, just end the thread.
        while iTunes.playing() {
            if lyricsArray.count != 0 {
                iTunesPosition = iTunes.playerPosition()
                if (currentPosition < iTunesPosition) || ((currentPosition / 1000) != (iTunesPosition / 1000) && currentPosition % 1000 < 850) {
                    currentPosition = iTunesPosition
                }
                dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), { () -> Void in
                    self.handlePositionChange(iTunesPosition)
                })
            }
            NSThread.sleepForTimeInterval(0.15)
            currentPosition += 150
        }
        if userDefaults.boolForKey(LyricsDisabledWhenPaused) {
            self.currentLyrics = nil
            dispatch_async(dispatch_get_main_queue(), { () -> Void in
                self.lyricsWindow.displayLyrics(nil, secondLyrics: nil)
                if self.menuBarLyrics != nil {
                    self.menuBarLyrics.displayLyrics(nil)
                }
            })
        }
        NSLog("iTunesTrackingThread Ended")
        isTrackingRunning=false
    }
    
    
    func iTunesPlayerInfoChanged (n:NSNotification) {
        let userInfo = n.userInfo
        if userInfo == nil {
            return
        }
        else {
            if userInfo!["Player State"] as! String == "Paused" {
                NSLog("iTunes Paused")
                if userDefaults.boolForKey(LyricsQuitWithITunes) {
                    // iTunes would paused before it quitted, so we should check whether iTunes is running
                    // seconds later when playing or paused.
                    if timer != nil {
                        timer.invalidate()
                    }
                    timer = NSTimer.scheduledTimerWithTimeInterval(2, target: self, selector: #selector(terminate), userInfo: nil, repeats: false)
                }
                return
            }
            else if userInfo!["Player State"] as! String == "Playing" {
                //iTunes is playing now, we should create the tracking thread if not exists.
                if !isTrackingRunning {
                    NSLog("Create new iTunesTrackingThead")
                    isTrackingRunning = true
                    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0)) { () -> Void in
                        self.iTunesTrackingThread()
                    }
                }
                NSLog("iTunes Playing")
            }
            else if userInfo!["Player State"] as! String == "Stopped" {
                // iTunes send this player state when quit in some case.
                currentSongID = ""
                currentSongTitle = ""
                currentArtist = ""
                if timer != nil {
                    timer.invalidate()
                }
                timer = NSTimer.scheduledTimerWithTimeInterval(2, target: self, selector: #selector(terminate), userInfo: nil, repeats: false)
                return
            }
            
            // Get infos from userinfo if can't get them from API.
            var songID: String = iTunes.currentPersistentID()
            var songTitle: String = iTunes.currentTitle()
            var artist: String = iTunes.currentArtist()
            if songID == "" {
                let aSongID = userInfo!["PersistentID"]
                if aSongID != nil {
                    songID = (aSongID as! NSNumber).stringValue
                }
            }
            if songTitle == "" {
                let aSongTitle = userInfo!["Name"]
                if aSongTitle != nil {
                    songTitle = aSongTitle as! String
                }
            }
            if artist == "" {
                let aArtist = userInfo!["Artist"]
                if aArtist != nil {
                    artist = aArtist as! String
                }
            }
            
            // Check whether song is changed.
            if currentSongID == songID {
                return
            } else {
                //if time-Delay for the previous song is changed, we should save the change to lrc file.
                //Save time-Delay laziely for better I/O performance.
                if timeDly != timeDlyInFile {
                    self.handleLrcDelayChange()
                }
                
                lyricsArray.removeAll()
                idTagsArray.removeAll()
                self.setValue(0, forKey: "timeDly")
                timeDlyInFile = 0
                currentLyrics = nil
                lyricsWindow.displayLyrics(nil, secondLyrics: nil)
                currentSongID = songID
                currentSongTitle = songTitle
                currentArtist = artist
                if currentSongID != "" {
                    defaultLyrics = iTunes.defaultLyrics()
                    NSLog("Song Changed to: %@",currentSongTitle)
                    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), { () -> Void in
                        self.handleSongChange()
                    })
                    //print("%@",defaultLyrics);
                } else {
                    NSLog("iTunes Stopped")
                }
            }
        }
    }

// MARK: - Lrc Methods
    
    private func parseCurrentLrc(lrcContents: String) {
        lyricsArray.removeAll()
        idTagsArray.removeAll()
        let lrcToParse: String
        
        // whether convert Chinese type
        if userDefaults.boolForKey(LyricsAutoConvertChinese) {
            switch userDefaults.integerForKey(LyricsChineseTypeIndex) {
            case 0:
                lrcToParse = convertToSC(lrcContents)
            case 1:
                lrcToParse = convertToTC(lrcContents)
            case 2:
                lrcToParse = convertToTC_TW(lrcContents)
            case 3:
                lrcToParse = convertToTC_HK(lrcContents)
            default:
                lrcToParse = lrcContents
                break
            }
        } else {
            //lrcToParse = lrcContents
            if(defaultLyrics.characters.count>30)
            {
                print("loading defaut Lyrics from MP3 file:")
                //print(defaultLyrics)
                lrcToParse = defaultLyrics
            }else{
                print("no default Lyrics found!")
                lrcToParse = lrcContents
            }
        }
        
        if userDefaults.boolForKey(LyricsEnableFilter) {
            lrcParser.parseWithFilter(lrcToParse, iTunesTitle: currentSongTitle, iTunesAlbum: iTunes.currentAlbum())
        }
        else {
            lrcParser.regularParse(lrcToParse)
        }
        lyricsArray = lrcParser.lyrics
        idTagsArray = lrcParser.idTags
        self.setValue(lrcParser.timeDly, forKey: "timeDly")
        timeDlyInFile = timeDly
        lrcParser.cleanCache()
    }

    private func saveLrcToLocal (lyricsContents: String, songTitle: String, artist: String) {
        let savingPath: String
        if userDefaults.integerForKey(LyricsSavingPathPopUpIndex) == 0 {
            savingPath = NSSearchPathForDirectoriesInDomains(.MusicDirectory, [.UserDomainMask], true).first! + "/LyricsX"
        } else {
            savingPath = userDefaults.stringForKey(LyricsUserSavingPath)!
        }
        let fm: NSFileManager = NSFileManager.defaultManager()
        
        var isDir: ObjCBool = false
        if fm.fileExistsAtPath(savingPath, isDirectory: &isDir) {
            if !isDir {
                return
            }
        } else {
            do {
                try fm.createDirectoryAtPath(savingPath, withIntermediateDirectories: true, attributes: nil)
            } catch let theError as NSError{
                NSLog("%@", theError.localizedDescription)
                return
            }
        }
        
        let titleForSaving = songTitle.stringByReplacingOccurrencesOfString("/", withString: "&")
        let artistForSaving = artist.stringByReplacingOccurrencesOfString("/", withString: "&")
        let lrcFilePath = (savingPath as NSString).stringByAppendingPathComponent("\(titleForSaving) - \(artistForSaving).lrc")
        
        if fm.fileExistsAtPath(lrcFilePath) {
            do {
                try fm.removeItemAtPath(lrcFilePath)
            } catch let theError as NSError {
                NSLog("%@", theError.localizedDescription)
                return
            }
        }
        do {
            try lyricsContents.writeToFile(lrcFilePath, atomically: false, encoding: NSUTF8StringEncoding)
        } catch let theError as NSError {
            NSLog("%@", theError.localizedDescription)
        }
    }
    
    func readLocalLyrics(theTitle: String, theArtist: String) -> String? {
        let savingPath: String
        if userDefaults.integerForKey(LyricsSavingPathPopUpIndex) == 0 {
            savingPath = NSSearchPathForDirectoriesInDomains(.MusicDirectory, [.UserDomainMask], true).first! + "/LyricsX"
        } else {
            savingPath = userDefaults.stringForKey(LyricsUserSavingPath)!
        }
        let songTitle: String = theTitle.stringByReplacingOccurrencesOfString("/", withString: "&")
        let artist: String = theArtist.stringByReplacingOccurrencesOfString("/", withString: "&")
        let lrcFilePath = (savingPath as NSString).stringByAppendingPathComponent("\(songTitle) - \(artist).lrc")
        if  NSFileManager.defaultManager().fileExistsAtPath(lrcFilePath) {
            let lrcContents: String?
            do {
                lrcContents = try String(contentsOfFile: lrcFilePath, encoding: NSUTF8StringEncoding)
            } catch {
                lrcContents = nil
                NSLog("Failed to load lrc")
            }
            return lrcContents
        } else {
            return nil
        }
    }

// MARK: - Handle Events
    
    func handlePositionChange (playerPosition: Int) {
        let tempLyricsArray = lyricsArray
        var index: Int = 0
        //1.Find the first lyrics which time position is larger than current position, and its index is "index"
        //2.The index of first-line-lyrics which needs to display is "index - 1"
        while index < tempLyricsArray.count {
            if playerPosition < tempLyricsArray[index].msecPosition - timeDly {
                if index == 0 {
                    if currentLyrics != nil {
                        currentLyrics = nil
                        if userDefaults.boolForKey(LyricsDesktopLyricsEnabled) {
                            dispatch_async(dispatch_get_main_queue(), { () -> Void in
                                self.lyricsWindow.displayLyrics(nil, secondLyrics: nil)
                            })
                        }
                        if menuBarLyrics != nil {
                            dispatch_async(dispatch_get_main_queue(), { () -> Void in
                                self.menuBarLyrics.displayLyrics(nil)
                            })
                        }
                    }
                    return
                }
                else {
                    if !tempLyricsArray[index-1].enabled {
                        if currentLyrics != nil {
                            currentLyrics = nil
                            if userDefaults.boolForKey(LyricsDesktopLyricsEnabled) {
                                dispatch_async(dispatch_get_main_queue(), { () -> Void in
                                    self.lyricsWindow.displayLyrics(nil, secondLyrics: nil)
                                })
                            }
                            if menuBarLyrics != nil {
                                dispatch_async(dispatch_get_main_queue(), { () -> Void in
                                    self.menuBarLyrics.displayLyrics(nil)
                                })
                            }
                        }
                    }
                    else if currentLyrics != tempLyricsArray[index-1].lyricsSentence {
                        var secondLyrics: String!
                        currentLyrics = tempLyricsArray[index-1].lyricsSentence
                        if userDefaults.boolForKey(LyricsDesktopLyricsEnabled) {
                            if userDefaults.boolForKey(LyricsTwoLineMode) && userDefaults.integerForKey(LyricsTwoLineModeIndex)==0 && index < tempLyricsArray.count {
                                if tempLyricsArray[index].lyricsSentence != "" {
                                    secondLyrics = tempLyricsArray[index].lyricsSentence
                                }
                            }
                            dispatch_async(dispatch_get_main_queue(), { () -> Void in
                                self.lyricsWindow.displayLyrics(self.currentLyrics, secondLyrics: secondLyrics)
                            })
                        }
                        if menuBarLyrics != nil {
                            dispatch_async(dispatch_get_main_queue(), { 
                                self.menuBarLyrics.displayLyrics(self.currentLyrics)
                            })
                        }
                    }
                    return
                }
            }
            index += 1
        }
        if index == tempLyricsArray.count && tempLyricsArray.count>0 {
            if !tempLyricsArray[tempLyricsArray.count - 1].enabled {
                if currentLyrics != nil {
                    currentLyrics = nil
                    if userDefaults.boolForKey(LyricsDesktopLyricsEnabled) {
                        dispatch_async(dispatch_get_main_queue(), { () -> Void in
                            self.lyricsWindow.displayLyrics(nil, secondLyrics: nil)
                        })
                    }
                    if menuBarLyrics != nil {
                        dispatch_async(dispatch_get_main_queue(), { () -> Void in
                            self.menuBarLyrics.displayLyrics(nil)
                        })
                    }
                }
            }
            else if currentLyrics != tempLyricsArray[tempLyricsArray.count - 1].lyricsSentence {
                currentLyrics = tempLyricsArray[tempLyricsArray.count - 1].lyricsSentence
                if userDefaults.boolForKey(LyricsDesktopLyricsEnabled) {
                    dispatch_async(dispatch_get_main_queue(), { () -> Void in
                        self.lyricsWindow.displayLyrics(self.currentLyrics, secondLyrics: nil)
                    })
                }
                if menuBarLyrics != nil {
                    dispatch_async(dispatch_get_main_queue(), {
                        self.menuBarLyrics.displayLyrics(self.currentLyrics)
                    })
                }
            }
        }
    }
    
    func handleSongChange() {
        //load lyrics for the song which is about to play
        lrcSourceHandleQueue.cancelAllOperations()
        let lrcContents: String? = readLocalLyrics(currentSongTitle, theArtist: currentArtist)
        if lrcContents != nil {
            parseCurrentLrc(lrcContents!)
            if lyricsArray.count != 0 {
                return
            }
        }
        
        //Search in the Net if local lrc is nil or invalid
        let loadingSongID: String = currentSongID
        let loadingArtist: String = currentArtist
        let loadingTitle: String = currentSongTitle
        hasDiglossiaLrc = false
        
        let artistForSearching: String = self.delSpecificSymbol(loadingArtist)
        let titleForSearching: String = self.delSpecificSymbol(loadingTitle)
        
        //千千静听不支持繁体中文搜索，先转成简体中文。搜歌词组件参数是iTunes中显示的歌曲名
        //歌手名以及iTunes的唯一编号（防止歌曲变更造成的歌词对错歌），以及用于搜索用的歌曲
        //名与歌手名。另外，天天动听/QQ只会获取歌词文本，其他歌词源都是获取歌词URL
        qianqian.getLyricsWithTitle(loadingTitle, artist: loadingArtist, songID: loadingSongID, titleForSearching: convertToSC(titleForSearching), andArtistForSearching: convertToSC(artistForSearching))
        xiami.getLyricsWithTitle(loadingTitle, artist: loadingArtist, songID: loadingSongID, titleForSearching: titleForSearching, andArtistForSearching: artistForSearching)
        ttpod.getLyricsWithTitle(loadingTitle, artist: loadingArtist, songID: loadingSongID, titleForSearching: titleForSearching, andArtistForSearching: artistForSearching)
        geciMe.getLyricsWithTitle(loadingTitle, artist: loadingArtist, songID: loadingSongID, titleForSearching: titleForSearching, andArtistForSearching: artistForSearching)
        qqMusic.getLyricsWithTitle(loadingTitle, artist: loadingArtist, songID: loadingSongID, titleForSearching: titleForSearching, andArtistForSearching: artistForSearching)
    }
    
    func handleUserEditLyrics(n: NSNotification) {
        let userInfo: [NSObject:AnyObject] = n.userInfo!
        let lyrics: String = LyricsEditWindowController.sharedController.textView.string!
        
        if lrcParser.testLrc(lyrics) {
            //User lrc has the highest priority level
            lrcSourceHandleQueue.cancelAllOperations()
            lrcSourceHandleQueue.addOperationWithBlock { () -> Void in
                if (userInfo["SongID"] as! String) == self.currentSongID {
                    //make the current lrc the better one so that it can't be replaced.
                    self.hasDiglossiaLrc = true
                    self.parseCurrentLrc(lyrics)
                }
                self.saveLrcToLocal(lyrics, songTitle: userInfo["SongTitle"] as! String, artist: userInfo["SongArtist"] as! String)
            }
        }
    }
    
    func handleExtenalLyricsEvent (n:NSNotification) {
        let userInfo = n.userInfo
        
        //no playing track?
        if currentSongID == "" {
            let notification: NSUserNotification = NSUserNotification()
            notification.title = NSLocalizedString("NO_PLAYING_TRACK", comment: "")
            notification.informativeText = String(format: NSLocalizedString("IGNORE_LYRICS", comment: ""), userInfo!["Sender"] as! String)
            NSUserNotificationCenter.defaultUserNotificationCenter().deliverNotification(notification)
            return
        }
        MessageWindowController.sharedMsgWindow.displayMessage(String(format: NSLocalizedString("RECIEVE_LYRICS", comment: ""), userInfo!["Sender"] as! String))
        //User lrc has the highest priority level
        lrcSourceHandleQueue.cancelAllOperations()
        lrcSourceHandleQueue.addOperationWithBlock { () -> Void in
            let lyricsContents: String = userInfo!["LyricsContents"] as! String
            if self.lrcParser.testLrc(lyricsContents) {
                self.parseCurrentLrc(lyricsContents)
                //make the current lrc the better one so that it can't be replaced.
                self.hasDiglossiaLrc = true
                self.saveLrcToLocal(lyricsContents, songTitle: self.currentSongTitle, artist: self.currentArtist)
            }
        }
    }
    
    func handleLrcDelayChange () {
        //save the delay change to file.
        if lyricsArray.count == 0 {
            return
        }
        var theLyrics: String = String()
        for idtag in idTagsArray {
            theLyrics.appendContentsOf(idtag + "\n")
        }
        theLyrics.appendContentsOf("[offset:\(timeDly)]\n")
        for lrc in lyricsArray {
            theLyrics.appendContentsOf(lrc.timeTag + lrc.lyricsSentence + "\n")
        }
        if lyricsArray.count > 0 {
            theLyrics.removeAtIndex(theLyrics.endIndex.advancedBy(-1))
        }
        NSLog("Writing the time delay to file")
        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0)) { 
            self.saveLrcToLocal(theLyrics, songTitle: self.currentSongTitle, artist: self.currentArtist)
        }
    }
    
    func handlePresetDidChanged() {
        presetMenuItem.submenu?.removeAllItems()
        let prefs = AppPrefsWindowController.sharedPrefsWindowController
        if prefs.presets.count == 0 {
            presetMenuItem.submenu?.addItemWithTitle(NSLocalizedString("EMPTY", comment: ""), action: nil, keyEquivalent: "")
            return
        }
        for preset in prefs.presets {
            let item = NSMenuItem()
            item.title = preset
            item.target = self
            item.action = #selector(setPresetByMenu(_:))
            presetMenuItem.submenu?.addItem(item)
        }
    }
    
// MARK: - Lyrics Source Loading Completion

    func lrcLoadingCompleted(n: NSNotification) {
        // we should run the handle thread one by one in the queue of maxConcurrentOperationCount =1
        let userInfo = n.userInfo
        let source: Int = userInfo!["source"]!.integerValue
        let songTitle: String = userInfo!["title"] as! String
        let artist: String = userInfo!["artist"] as! String
        let songID: String = userInfo!["songID"] as! String
        let serverLrcs: [SongInfos]
        switch source {
        case 1:
            serverLrcs = (self.qianqian.currentSongs as NSArray) as! [SongInfos]
        case 2:
            serverLrcs = (self.xiami.currentSongs as NSArray) as! [SongInfos]
        case 3:
            let info: SongInfos = self.ttpod.songInfos.copy() as! SongInfos
            if info.lyric == "" {
                return
            } else {
                serverLrcs = [info]
            }
        case 4:
            serverLrcs = (self.geciMe.currentSongs as NSArray) as! [SongInfos]
        case 5:
            serverLrcs = self.qqMusic.currentSongs
        default:
            return;
        }
        if serverLrcs.count > 0 {
            lrcSourceHandleQueue.addOperationWithBlock({ () -> Void in
                self.handleLrcURLDownloaded(serverLrcs, songTitle: songTitle, artist: artist, songID: songID)
            })
        }
    }
    
    
    private func handleLrcURLDownloaded(serverLrcs: [SongInfos], songTitle:String, artist:String, songID:String) {
        // alread has lyrics, check if user needs a better one.
        if lyricsArray.count > 0 {
            if userDefaults.boolForKey(LyricsSearchForDiglossiaLrc) {
                if hasDiglossiaLrc {
                    return
                }
            } else {
                return
            }
        }
        
        var lyricsContents: String! = nil
        for lrc in serverLrcs {
            if isDiglossiaLrc(lrc.songTitle + lrc.artist) {
                if lrc.lyric != nil {
                    lyricsContents = lrc.lyric
                }
                else if lrc.lyricURL != nil {
                    do {
                        lyricsContents = try String(contentsOfURL: NSURL(string: lrc.lyricURL)!, encoding: NSUTF8StringEncoding)
                    } catch let theError as NSError{
                        NSLog("%@", theError.localizedDescription)
                        lyricsContents = nil
                        continue
                    }
                }
                break
            }
        }
        if lyricsContents == nil && lyricsArray.count > 0 {
            return
        }
        
        var hasLrc: Bool
        if lyricsContents == nil || !lrcParser.testLrc(lyricsContents) {
            NSLog("better lrc not found or it's not lrc file,trying others")
            hasLrc = false
            lyricsContents = nil
            hasDiglossiaLrc = false
            for lrc in serverLrcs {
                if lrc.lyric != nil {
                    lyricsContents = lrc.lyric
                }
                else if lrc.lyricURL != nil {
                    do {
                        lyricsContents = try String(contentsOfURL: NSURL(string: lrc.lyricURL)!, encoding: NSUTF8StringEncoding)
                    } catch let theError as NSError{
                        NSLog("%@", theError.localizedDescription)
                        lyricsContents = nil
                        continue
                    }
                }
                if lyricsContents != nil && lrcParser.testLrc(lyricsContents) {
                    hasLrc = true
                    break
                }
            }
        } else {
            hasLrc = true
            hasDiglossiaLrc = true
        }
        if hasLrc {
            if songID == currentSongID {
                parseCurrentLrc(lyricsContents)
            }
            saveLrcToLocal(lyricsContents, songTitle: songTitle, artist: artist)
        }
    }
    
// MARK: - Other Methods
    
    func terminate() {
        if !iTunes.running() {
            NSApplication.sharedApplication().terminate(nil)
        }
    }
    
    private func isDiglossiaLrc(serverSongTitle: String) -> Bool {
        if serverSongTitle.rangeOfString("中") != nil || serverSongTitle.rangeOfString("对照") != nil || serverSongTitle.rangeOfString("双") != nil {
            return true
        }
        return false
    }
    
    private func delSpecificSymbol(input: String) -> String {
        let specificSymbol: [String] = [
            ",", ".", "'", "\"", "`", "~", "!", "@", "#", "$", "%", "^", "&", "＆", "*", "(", ")", "（", "）", "，",
            "。", "“", "”", "‘", "’", "?", "？", "！", "/", "[", "]", "{", "}", "<", ">", "=", "-", "+", "×",
            "☆", "★", "√", "～"
        ]
        var output: String = input
        for symbol in specificSymbol {
            output = output.stringByReplacingOccurrencesOfString(symbol, withString: " ")
        }
        return output
    }
    
}

