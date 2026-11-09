import AppKit
import Carbon
import Combine
import Quartz
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private lazy var line = Line()
    private let phoneCamera = PhoneCameraCapture()
    private var pendingCameraLaunch = false
    private var panel: LinePanel!
    private var statusItem: NSStatusItem!
    private var watcher: ScreenshotWatcher!
    /// In inbox mode, a second watcher on the Desktop. If a macOS version
    /// ignores the screenshot settings (macOS 27 renamed one), captures keep
    /// landing on the Desktop, and they still hang on the line.
    private var safetyWatcher: ScreenshotWatcher?
    /// Folders chosen in "Also watch folders", like the one another
    /// screenshot app saves to.
    private var folderWatchers: [ScreenshotWatcher] = []
    private var clipboardWatcher: ClipboardWatcher!
    private var signalSources: [DispatchSourceSignal] = []
    private var hotKey: HotKey?
    private var cancellables = Set<AnyCancellable>()
    private var mouseTimer: Timer?

    /// Whether the panel is ordered in. It can be in and still tucked away
    /// above the top edge, like an auto-hiding Dock.
    private var isPresent = false
    /// Whether the line has slid down into view.
    private var isRevealed = false
    /// Opened on purpose with the shortcut or the menu: it stays down until
    /// the cursor has visited it and left, or the shortcut is pressed again.
    private var pinned = false
    /// A newly received remote image shows itself briefly, then tucks away.
    private var peekUntil = Date.distantPast
    private var hotZoneSince: Date?
    /// After a click in the menu bar the line stays hidden until the pointer
    /// leaves the central reveal zone, so it does not come back over a menu.
    private var menuBarSuppressed = false
    private var clickMonitors: [Any] = []
    private var awaySince: Date?
    /// Whether the line should be up, if nothing prevents it. A full screen
    /// app on that screen does: the line waits until you leave full screen.
    private var wanted = false
    /// Set when you open the line on purpose, so it stays up while empty.
    private var keepOpen = false

    // Hover and remote-image arrival can reveal the board. Other imports stay
    // hidden; explicit menu, shortcut and camera actions still work normally.

    /// Resting the pointer at the centre of the menu bar. Off, only the shortcut and the
    /// menu open it.
    static var opensFromMenuBar: Bool {
        get { !UserDefaults.standard.bool(forKey: "menuBarRevealOff") }
        set { UserDefaults.standard.set(!newValue, forKey: "menuBarRevealOff") }
    }

    /// Only images received through Universal Clipboard may reveal the board.
    static var peeksAtRemoteImages: Bool {
        get { !UserDefaults.standard.bool(forKey: "remoteImageRevealOff") }
        set { UserDefaults.standard.set(!newValue, forKey: "remoteImageRevealOff") }
    }

    /// The preview is a background utility, so starting with the user's Mac
    /// is the useful default. An explicit menu opt-out is remembered.
    private static let launchAtLoginDisabledKey = "launchAtLoginDisabled"
    private static let legacyDefaultsDomain = "local.feltboard.preview"
    private static let defaultsMigrationKey = "tackShelfDefaultsMigrationV1"

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.migrateLegacyDefaultsIfNeeded()
        panel = LinePanel(content: makeBoardHost())
        phoneCamera.onPhoto = { [weak self] url in
            guard let self else { return }
            self.hangCapture(url)
            self.reveal(pinned: true)
        }
        phoneCamera.$statusText.dropFirst().sink { [weak self] message in
            if message != nil { self?.reveal(peekFor: 6) }
        }.store(in: &cancellables)
        panel.placeOnScreen()
        updateCapacity()

        if Inbox.isEnabled { Inbox.apply() }
        restoreSettingsOnTermination()
        startWatcher()
        clipboardWatcher = ClipboardWatcher(onContent: { [weak self] content in
            self?.hangCapture(content.url, automaticallyReveal: content.shouldAutomaticallyReveal)
        })
        if ClipboardWatcher.isEnabled {
            clipboardWatcher.start()
            // Recover any copy that arrived while the app was closed, without
            // replaying an arrival animation during startup.
            clipboardWatcher.requestImport(allowAutomaticReveal: false)
        }

        registerShortcut()

        setUpStatusItem()
        ensureLaunchAtLogin()
        watchMenuBarClicks()

        Markup.shared.onSaved = { [weak self] url in self?.line.reloadThumbnail(for: url) }
        Trim.shared.onSaved = { [weak self] url in self?.line.reloadThumbnail(for: url) }
        panel.onScroll = { [weak self] event in
            // Scroll down through older rows; sideways trackpad gestures also work.
            let delta = abs(event.scrollingDeltaX) >= abs(event.scrollingDeltaY)
                ? event.scrollingDeltaX : event.scrollingDeltaY
            self?.line.scroll(by: event.hasPreciseScrollingDeltas ? -delta : -delta * 12)
        }
        line.onFall = { [weak self] item in self?.fall(item) }

        line.$items
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.itemsChanged() }
            .store(in: &cancellables)
        // Restored history waits behind the top edge. Keep hover available
        // even on an empty board, where the camera button is still useful.
        prepareForHover(on: panel.screen)

        // Entering or leaving full screen switches Space. Check again once the
        // switch animation has settled.
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.activeSpaceDidChangeNotification, NSWorkspace.didActivateApplicationNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refresh()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.refresh() }
                }
            }
        }
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated {
                // SwiftUI Canvas textures can occasionally become the system's
                // magenta error surface after the GPU is recreated on wake.
                // Replacing the host releases those stale render resources;
                // the Line model and its persisted history stay untouched.
                self?.rebuildBoardRendererAfterWake()
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.panel.placeOnScreen()
                self?.updateCapacity()
            }
        }

        if !Inbox.wasOffered {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in self?.offerInbox() }
        }

        if pendingCameraLaunch {
            pendingCameraLaunch = false
            startPhoneCamera()
        }
    }

    private func makeBoardHost() -> NSHostingView<LineView> {
        let host = NSHostingView(rootView: LineView(line: line, camera: phoneCamera))
        host.sizingOptions = []
        return host
    }

    private func rebuildBoardRendererAfterWake() {
        guard let panel else { return }
        let host = makeBoardHost()
        host.frame = panel.contentView?.bounds ?? CGRect(origin: .zero, size: panel.frame.size)
        panel.contentView = host
        panel.displayIfNeeded()
        log.notice("Rebuilt board renderer after system wake")
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard urls.contains(where: PhoneCameraCapture.isLaunchURL) else { return }
        // Launch Services may deliver a URL before the shelf has been set up.
        guard panel != nil else {
            pendingCameraLaunch = true
            return
        }
        startPhoneCamera()
    }

    private func startPhoneCamera() {
        keepOpen = true
        wanted = true
        panel.placeOnScreen()
        updateCapacity()
        refresh()
        reveal(pinned: true)
        phoneCamera.takePhoto()
    }

    func applicationWillTerminate(_ notification: Notification) {
        phoneCamera.cancelCapture()
        if Inbox.isEnabled { Inbox.restore() }
    }

    // MARK: Inbox mode

    private func startWatcher() {
        watcher?.stop()
        safetyWatcher?.stop()
        safetyWatcher = nil
        watcher = ScreenshotWatcher(
            onNew: { [weak self] url in self?.hangCapture(url) },
            onChange: { [weak self] in self?.line.prune() })
        watcher.start()
        if Inbox.isEnabled, watcher.folder.standardizedFileURL != ScreenshotWatcher.desktop.standardizedFileURL {
            let safety = ScreenshotWatcher(
                folder: ScreenshotWatcher.desktop,
                onNew: { [weak self] url in
                    log.notice("Screenshot landed on the Desktop despite inbox mode: \(url.lastPathComponent, privacy: .public)")
                    self?.hangCapture(url)
                },
                onChange: { [weak self] in self?.line.prune() })
            safety.start()
            safetyWatcher = safety
        }
        folderWatchers.forEach { $0.stop() }
        folderWatchers = []
        // A folder may also be watched for screenshots, like the Desktop; an
        // image both report hangs once.
        for folder in Self.extraFolders {
            let extra = ScreenshotWatcher(
                folder: folder, anyImage: true,
                onNew: { [weak self] url in self?.hangCapture(url) },
                onChange: { [weak self] in self?.line.prune() })
            extra.start()
            folderWatchers.append(extra)
        }
    }

    /// Up to three folders: enough for another screenshot app or an export
    /// folder, few enough that screenshots still have room on the line.
    static let maxExtraFolders = 3

    /// The folders from "Also watch folders" that still exist. New images in
    /// them hang like screenshots; taking one down leaves the file there.
    static var extraFolders: [URL] {
        get {
            let paths = UserDefaults.standard.stringArray(forKey: "extraFolders") ?? []
            return paths.compactMap { path in
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
                return URL(fileURLWithPath: path, isDirectory: true)
            }
        }
        set { UserDefaults.standard.set(newValue.map(\.path), forKey: "extraFolders") }
    }

    private func chooseExtraFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("Watch")
        panel.message = L("New images saved to this folder will hang on the line.")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url, Self.extraFolders.count < Self.maxExtraFolders,
              !Self.extraFolders.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) else { return }
        Self.extraFolders.append(url)
        startWatcher()
    }

    private func setInbox(_ on: Bool) {
        Inbox.isEnabled = on
        if on { Inbox.apply() } else { Inbox.restore() }
        startWatcher()
    }

    /// Asked once. Changing system settings is the user's call, never ours.
    private func offerInbox() {
        Inbox.wasOffered = true
        let alert = NSAlert()
        alert.messageText = L("Let TackShelf handle your screenshots?")
        alert.informativeText = L(
            "Screenshots appear on TackShelf the instant you take them, without the floating thumbnail, and will not pile up on your Desktop. Drag one to a folder to keep it, or discard it with the cross. You can turn this off from the menu bar, and your settings come back when TackShelf quits.")
        alert.addButton(withTitle: L("Turn on"))
        alert.addButton(withTitle: L("Not now"))
        alert.icon = NSApp.applicationIconImage
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { setInbox(true) }
    }

    /// Watching the clipboard is opt in, from the menu bar only.
    private func setClipboard(_ on: Bool) {
        ClipboardWatcher.isEnabled = on
        if on { clipboardWatcher.start() } else { clipboardWatcher.stop() }
        updateStatusIcon()
    }

    /// Quitting from the menu or logging out runs applicationWillTerminate.
    /// A plain kill does not, so settings are also restored on those signals.
    private func restoreSettingsOnTermination() {
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                self?.phoneCamera.cancelCapture()
                if Inbox.isEnabled { Inbox.restore() }
                exit(0)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: Showing and hiding

    /// An empty line goes away, unless it was opened on purpose.
    private func itemsChanged() {
        guard line.liveCount == 0, !keepOpen, !phoneCamera.isCapturing else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + CrumpleDiscard.cleanupDelay + 0.05) { [weak self] in
            guard let self, self.line.liveCount == 0, !self.keepOpen, !self.phoneCamera.isCapturing else { return }
            self.setRevealed(false)
            self.refresh()
        }
    }

    /// Make the board available for hover without ordering its window in.
    private func prepareForHover(on screen: NSScreen?) {
        panel.placeOnScreen(screen)
        updateCapacity()
        wanted = true
        refresh()
    }

    // MARK: The capture flying to the line

    /// All imports are stored. Only a new remote image can request a peek.
    private func hangCapture(_ url: URL, automaticallyReveal: Bool = false) {
        let shouldPeek = automaticallyReveal && Self.peeksAtRemoteImages
        let from = (isRevealed || shouldPeek) && url.pathExtension != ClipboardContent.extensionName
            ? captureRect(of: url) : nil
        let screen = from.flatMap { from in
            NSScreen.screens.first { NSMouseInRect(CGPoint(x: from.midX, y: from.midY), $0.frame, false) }
        }
        // A silent import must not move an already open board between screens.
        prepareForHover(on: shouldPeek ? screen : panel.screen)
        guard let id = line.hang(url, flying: from != nil) else {
            // The folder watcher may have hung this same saved image first.
            // Its silent callback must not swallow the clipboard arrival peek.
            if shouldPeek, line.items.contains(where: { $0.url == url && !$0.falling }) {
                reveal(peekFor: 2.5)
            }
            itemsChanged()
            return
        }
        if shouldPeek { reveal(peekFor: 2.5) }
        guard let from else { return }
        // Let the line come down and lay out before measuring the landing spot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
            self?.fly(id, from: from)
        }
    }

    private func fly(_ id: UUID, from: CGRect) {
        guard isPresent, isRevealed, CaptureFlight.flightsInProgress < 2, let screen = panel.screen,
              let to = cardFrame(for: id),
              let item = line.items.first(where: { $0.id == id }) else {
            line.land(id)
            return
        }
        // Sharp enough while it starts out at the captured size, which a
        // full Retina screen would otherwise take at full resolution.
        let pixels = Int(max(from.width, from.height) * screen.backingScaleFactor)
        guard let image = makeThumbnail(item.url, maxPixels: min(1500, max(400, pixels)))?
            .cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            line.land(id)
            return
        }
        CaptureFlight.fly(image: image, from: from, to: to, tilt: CGFloat(item.tilt),
                          buttonColourIndex: ButtonPalette.index(for: item.url), on: screen) { [weak self] in
            self?.line.land(id)
        }
    }

    /// A discarded card keeps its real material while folding into a paper ball.
    private func fall(_ item: Pegged) {
        guard isPresent, isRevealed, !item.flying, let screen = panel.screen,
              let card = cardFrame(for: item.id),
              let paper = PeggedView.paperImage(for: item, scale: screen.backingScaleFactor) else { return }
        CrumpleDiscard.play(paper: paper, card: card, tilt: CGFloat(item.tilt),
                            buttonColourIndex: ButtonPalette.index(for: item.url), on: screen)
    }

    /// Where a card will hang, in screen coordinates, using the same layout
    /// as the line view.
    private func cardFrame(for id: UUID) -> CGRect? {
        guard let card = Layout.frame(for: id, items: line.items, width: panel.frame.width,
                                      height: panel.frame.height, scroll: line.scroll),
              Layout.cardViewport(for: panel.frame.size).intersects(card) else { return nil }
        return CGRect(x: panel.frame.minX + card.minX,
                      y: panel.frame.maxY - card.maxY,
                      width: card.width, height: card.height)
    }

    /// Decides whether the panel is ordered in at all: something to show,
    /// and no full screen app on that screen.
    private func refresh() {
        let blocked = panel.screen.map(FullScreen.blocksLine(on:))
            ?? LinePanel.screenUnderPointer().map(FullScreen.blocksLine(on:)) ?? false
        if wanted && !blocked {
            present()
        } else {
            dismiss()
        }
        // The cursor is watched while there is a line, even tucked away,
        // to notice it pushing against the top edge.
        if wanted { startMouseTracking() } else { stopMouseTracking() }
    }

    private func present() {
        guard !isPresent else { return }
        isPresent = true
        panel.alphaValue = 1
        // The window itself only comes in while the line is down; see setRevealed.
        if isRevealed { panel.orderFrontRegardless() }
    }

    private func dismiss() {
        guard isPresent else { return }
        isPresent = false
        setRevealed(false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
            guard let self, !self.isPresent else { return }
            self.panel.orderOut(nil)
        }
    }

    private func reveal(pinned: Bool = false, peekFor seconds: TimeInterval = 0) {
        guard isPresent else { return }
        if pinned { self.pinned = true }
        if seconds > 0 { peekUntil = Date().addingTimeInterval(seconds) }
        awaySince = nil
        setRevealed(true)
    }

    private func setRevealed(_ on: Bool) {
        guard on != isRevealed else { return }
        isRevealed = on
        line.revealed = on
        // It always comes down showing the newest.
        if on { line.scroll = 0 }
        // Tucked away, the line leaves no window behind: an invisible strip
        // over the top of the screen would still sit above other apps for
        // anything that checks what is on top, like screen automation.
        if on {
            if isPresent { panel.orderFrontRegardless() }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, !self.isRevealed else { return }
                self.panel.orderOut(nil)
            }
        }
        if !on {
            pinned = false
            peekUntil = .distantPast
            panel.ignoresMouseEvents = true
        }
    }

    @objc private func toggle() {
        if isRevealed {
            setRevealed(false)
            if line.liveCount == 0 {
                keepOpen = false
                wanted = true
                refresh()
            }
        } else {
            keepOpen = true
            wanted = true
            panel.placeOnScreen()
            updateCapacity()
            refresh()
            reveal(pinned: true)
        }
    }

    private func startMouseTracking() {
        guard mouseTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        mouseTimer = timer
    }

    private func stopMouseTracking() {
        mouseTimer?.invalidate()
        mouseTimer = nil
        panel.ignoresMouseEvents = true
    }

    /// How long the cursor rests against the top edge before the line comes
    /// down. Short enough to feel instant, long enough that a quick trip to
    /// the menu bar does not trigger it.
    private static let revealDelay: TimeInterval = 0.25

    /// The menu bar strip at the top of a screen. With an auto-hiding menu
    /// bar the visible frame reaches the top, so the system thickness is used.
    static func menuBarBand(of screen: NSScreen) -> NSRect {
        var h = screen.frame.maxY - screen.visibleFrame.maxY
        if h < 1 { h = max(NSStatusBar.system.thickness, screen.safeAreaInsets.top) }
        return NSRect(x: screen.frame.minX, y: screen.frame.maxY - h, width: screen.frame.width, height: h)
    }

    /// Only the small central segment opens the board; the rest of the menu
    /// bar remains available without triggering it.
    static func hoverRevealBand(in menuBarBand: NSRect) -> NSRect {
        let width = min(280, menuBarBand.width)
        return NSRect(x: menuBarBand.midX - width / 2, y: menuBarBand.minY,
                      width: width, height: menuBarBand.height)
    }

    /// A click anywhere in the top bar of any screen, a menu or an icon, puts the line away.
    private func watchMenuBarClicks() {
        let handler: (NSEvent?) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let p = NSEvent.mouseLocation
                guard NSScreen.screens.contains(where: { NSMouseInRect(p, Self.menuBarBand(of: $0), false) }) else { return }
                self.menuBarSuppressed = true
                self.hotZoneSince = nil
                if self.isRevealed {
                    self.pinned = false
                    self.setRevealed(false)
                }
            }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: handler) {
            clickMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { e in handler(e); return e }) {
            clickMonitors.append(local)
        }
    }
    /// How long the cursor is away before the line tucks back up.
    private static let retractDelay: TimeInterval = 0.5

    private func tick() {
        let mouse = NSEvent.mouseLocation
        let now = Date()

        let screenUnderPointer = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
        let inRevealZone = screenUnderPointer.map {
            NSMouseInRect(mouse, Self.hoverRevealBand(in: Self.menuBarBand(of: $0)), false)
        } ?? false
        if !inRevealZone { menuBarSuppressed = false }

        guard isRevealed else {
            // Resting in the central segment brings the board down on that screen.
            // Pushing against the top edge is part of it, and it also works
            // when another display sits above and the pointer never stops.
            if Self.opensFromMenuBar, let screen = screenUnderPointer, inRevealZone, !menuBarSuppressed,
               !FullScreen.blocksLine(on: screen) {
                let since = hotZoneSince ?? now
                hotZoneSince = since
                if now.timeIntervalSince(since) >= Self.revealDelay {
                    hotZoneSince = nil
                    if panel.screen != screen {
                        panel.placeOnScreen()
                        updateCapacity()
                    }
                    refresh()
                    reveal()
                }
            } else {
                hotZoneSince = nil
            }
            return
        }

        updateMousePassThrough(mouse)

        // The line's zone runs from its lowest point up to the top of the
        // screen, menu bar included, so moving up never hides it.
        var zone = panel.frame
        if let screen = panel.screen { zone.size.height = screen.frame.maxY - zone.minY }
        let inside = NSMouseInRect(mouse, zone, false)
        if inside && pinned { pinned = false }

        let busy = pinned || GrabView.isDragging || GrabView.isShowingMenu
            || line.pressedID != nil || phoneCamera.isCapturing || now < peekUntil
        if inside || busy {
            awaySince = nil
        } else {
            let since = awaySince ?? now
            awaySince = since
            if now.timeIntervalSince(since) >= Self.retractDelay {
                awaySince = nil
                setRevealed(false)
            }
        }
    }

    /// Accept card and camera interactions, including scrolling between rows.
    private func updateMousePassThrough(_ mouse: NSPoint) {
        guard !GrabView.isDragging else { return }
        let local = panel.convertPoint(fromScreen: mouse)
        let flipped = CGPoint(x: local.x, y: panel.frame.height - local.y)
        var overPhoto = line.hitRects.values.contains { $0.insetBy(dx: -4, dy: -4).contains(flipped) }
        // Include the gaps while scrolling, without capturing the header.
        if !overPhoto, line.maximumScroll > 0 {
            overPhoto = Layout.cardViewport(for: panel.frame.size).contains(flipped)
        }
        let overCamera = line.cameraHitRect?.insetBy(dx: -4, dy: -4).contains(flipped) ?? false
        let receivesMouse = overPhoto || overCamera
        if panel.ignoresMouseEvents == receivesMouse {
            panel.ignoresMouseEvents = !receivesMouse
        }
    }

    // MARK: Shortcut

    private func registerShortcut() {
        hotKey = nil
        guard let shortcut = Shortcut.current else { return }
        hotKey = HotKey(shortcut) { [weak self] in self?.toggle() }
    }

    private func changeShortcut() {
        // Off while recording, so pressing the current one records it
        // instead of showing the line.
        hotKey = nil
        ShortcutRecorder.shared.record { [weak self] result in
            guard let self else { return }
            if let result {
                let previous = Shortcut.current
                Shortcut.current = result
                self.registerShortcut()
                // Taken by another app: keep the one that worked.
                if result != nil && self.hotKey == nil {
                    NSSound.beep()
                    Shortcut.current = previous
                }
            }
            self.registerShortcut()
        }
    }

    private func setSize(_ size: Layout.Size) {
        guard size != Layout.size else { return }
        Layout.size = size
        panel.placeOnScreen(panel.screen)
        updateCapacity()
        line.reloadThumbnails()
    }

    private func updateCapacity() {
        line.viewportWidth = panel.frame.width
        line.viewportHeight = panel.frame.height
        line.scroll = min(line.scroll, line.maximumScroll)
    }

    // MARK: Menu bar

    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateStatusIcon()
        let menu = NSMenu()
        // Items say themselves whether they can be used, like Take everything
        // down on an empty line.
        menu.autoenablesItems = false
        menu.delegate = self
        statusItem.menu = menu
    }

    /// The pin fills in while copied images are hung, so it shows at a
    /// glance that the clipboard is being watched.
    private func updateStatusIcon() {
        let on = ClipboardWatcher.isEnabled
        let description = on ? "TackShelf，正在收取剪贴板内容" : "TackShelf"
        let image = NSImage(systemSymbolName: on ? "pin.fill" : "pin", accessibilityDescription: description)
        image?.isTemplate = true
        statusItem.button?.image = image
        statusItem.button?.toolTip = description
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let toggleItem = ClosureMenuItem(isRevealed ? "收起 TackShelf" : "展开 TackShelf") { [weak self] in
            self?.toggle()
        }
        if let shortcut = Shortcut.current, shortcut.key.count == 1 {
            toggleItem.keyEquivalent = shortcut.key
            toggleItem.keyEquivalentModifierMask = shortcut.modifiers
        }
        menu.addItem(toggleItem)

        let clearItem = ClosureMenuItem(L("Take everything down")) { [weak self] in
            self?.line.clear()
        }
        clearItem.isEnabled = line.liveCount > 0
        menu.addItem(clearItem)

        let inbox = ClosureMenuItem(L("Handle screenshots")) { [weak self] in
            self?.setInbox(!Inbox.isEnabled)
        }
        inbox.state = Inbox.isEnabled ? .on : .off
        inbox.toolTip = L("Screenshots hang instantly and skip the Desktop")
        menu.addItem(inbox)

        let clipboard = ClosureMenuItem("收取剪贴板内容") { [weak self] in
            self?.setClipboard(!ClipboardWatcher.isEnabled)
        }
        clipboard.state = ClipboardWatcher.isEnabled ? .on : .off
        clipboard.toolTip = "收取图片、文字、网址和文件"
        menu.addItem(clipboard)

        menu.addItem(ClosureMenuItem("重新收取剪贴板内容", key: "v") { [weak self] in
            self?.clipboardWatcher.requestImport()
        })

        let bringDown = NSMenuItem(title: L("Bring the line down"), action: nil, keyEquivalent: "")
        let options = NSMenu()
        let hover = ClosureMenuItem("鼠标停留在顶部中央时") {
            AppDelegate.opensFromMenuBar.toggle()
        }
        hover.state = Self.opensFromMenuBar ? .on : .off
        options.addItem(hover)
        let peek = ClosureMenuItem("收到跨设备图片时") {
            AppDelegate.peeksAtRemoteImages.toggle()
        }
        peek.state = Self.peeksAtRemoteImages ? .on : .off
        options.addItem(peek)
        let fullScreen = ClosureMenuItem(L("Over full screen apps")) { [weak self] in
            FullScreen.showLineOver.toggle()
            self?.refresh()
        }
        fullScreen.state = FullScreen.showLineOver ? .on : .off
        options.addItem(fullScreen)
        bringDown.submenu = options
        menu.addItem(bringDown)

        let folderItem = NSMenuItem(title: L("Also watch folders"), action: nil, keyEquivalent: "")
        let folderMenu = NSMenu()
        folderMenu.autoenablesItems = false
        let folders = Self.extraFolders
        for folder in folders {
            let item = ClosureMenuItem(FileManager.default.displayName(atPath: folder.path)) {
                NSWorkspace.shared.open(folder)
            }
            item.state = .on
            folderMenu.addItem(item)
        }
        if !folders.isEmpty { folderMenu.addItem(.separator()) }
        let add = ClosureMenuItem(L("Add Folder…")) { [weak self] in self?.chooseExtraFolder() }
        add.isEnabled = folders.count < Self.maxExtraFolders
        folderMenu.addItem(add)
        if !folders.isEmpty {
            let stop = NSMenuItem(title: L("Stop Watching"), action: nil, keyEquivalent: "")
            let stopMenu = NSMenu()
            for folder in folders {
                stopMenu.addItem(ClosureMenuItem(FileManager.default.displayName(atPath: folder.path)) { [weak self] in
                    AppDelegate.extraFolders.removeAll { $0.standardizedFileURL == folder.standardizedFileURL }
                    self?.startWatcher()
                })
            }
            stop.submenu = stopMenu
            folderMenu.addItem(stop)
        }
        folderItem.submenu = folderMenu
        menu.addItem(folderItem)

        let keepItem = NSMenuItem(title: "最多保留 \(Line.historyLimit) 条", action: nil, keyEquivalent: "")
        keepItem.isEnabled = false
        menu.addItem(keepItem)

        let sizeItem = NSMenuItem(title: L("Size"), action: nil, keyEquivalent: "")
        let sizes = NSMenu()
        for (size, title) in [(Layout.Size.small, L("Small")), (.medium, L("Medium")), (.large, L("Large"))] {
            let item = ClosureMenuItem(title) { [weak self] in self?.setSize(size) }
            item.state = Layout.size == size ? .on : .off
            sizes.addItem(item)
        }
        sizeItem.submenu = sizes
        menu.addItem(sizeItem)

        let shortcutItem = NSMenuItem(title: L("Shortcut"), action: nil, keyEquivalent: "")
        let shortcuts = NSMenu()
        let current = NSMenuItem(title: Shortcut.current?.display ?? L("None"), action: nil, keyEquivalent: "")
        current.isEnabled = false
        shortcuts.addItem(current)
        shortcuts.addItem(ClosureMenuItem(L("Change Shortcut…")) { [weak self] in self?.changeShortcut() })
        shortcutItem.submenu = shortcuts
        menu.addItem(shortcutItem)

        menu.addItem(ClosureMenuItem(L("Open screenshots folder")) { [weak self] in
            guard let self else { return }
            NSWorkspace.shared.open(self.watcher.folder)
        })

        menu.addItem(.separator())

        let sound = ClosureMenuItem(L("Sounds")) { [weak self] in
            guard let self else { return }
            self.line.soundOn.toggle()
        }
        sound.state = line.soundOn ? .on : .off
        menu.addItem(sound)

        let login = ClosureMenuItem(L("Open at login")) {
            AppDelegate.toggleLaunchAtLogin()
        }
        let loginStatus = SMAppService.mainApp.status
        login.state = loginStatus == .enabled ? .on : (loginStatus == .requiresApproval ? .mixed : .off)
        menu.addItem(login)

        menu.addItem(.separator())
        menu.addItem(ClosureMenuItem("退出 TackShelf", key: "q") {
            NSApp.terminate(nil)
        })
    }

    private func ensureLaunchAtLogin() {
        guard !UserDefaults.standard.bool(forKey: Self.launchAtLoginDisabledKey) else { return }
        let service = SMAppService.mainApp
        guard service.status != .enabled, service.status != .requiresApproval else {
            Self.recordLaunchAtLoginStatus()
            return
        }
        do {
            try service.register()
            Self.recordLaunchAtLoginStatus()
            log.notice("Registered preview to open at login")
        } catch {
            Self.recordLaunchAtLoginStatus(error: error)
            log.error("Could not register preview to open at login: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func toggleLaunchAtLogin() {
        do {
            let service = SMAppService.mainApp
            if service.status == .enabled || service.status == .requiresApproval {
                try service.unregister()
                UserDefaults.standard.set(true, forKey: launchAtLoginDisabledKey)
            } else {
                try service.register()
                UserDefaults.standard.set(false, forKey: launchAtLoginDisabledKey)
            }
            recordLaunchAtLoginStatus()
        } catch {
            recordLaunchAtLoginStatus(error: error)
            let alert = NSAlert()
            alert.messageText = L("Could not change the login setting")
            alert.informativeText = L("Move TackShelf to the Applications folder and try again.")
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    private static func recordLaunchAtLoginStatus(error: Error? = nil) {
        let defaults = UserDefaults.standard
        defaults.set(String(describing: SMAppService.mainApp.status), forKey: "launchAtLoginStatus")
        if let error {
            defaults.set(error.localizedDescription, forKey: "launchAtLoginError")
        } else {
            defaults.removeObject(forKey: "launchAtLoginError")
        }
    }

    /// Preserve the user's history and preferences when the public app name
    /// moves from the preview bundle identity to TackShelf.
    private static func migrateLegacyDefaultsIfNeeded() {
        let current = UserDefaults.standard
        guard !current.bool(forKey: defaultsMigrationKey) else { return }
        if let legacy = UserDefaults(suiteName: legacyDefaultsDomain),
           let values = legacy.persistentDomain(forName: legacyDefaultsDomain) {
            for (key, value) in values where current.object(forKey: key) == nil {
                current.set(value, forKey: key)
            }
        }
        current.set(true, forKey: defaultsMigrationKey)
    }

    // MARK: Quick Look

    /// With no window of ours in front, Quick Look finds its controller here.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        QuickLook.shared.take(panel)
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        QuickLook.shared.release(panel)
    }

}
