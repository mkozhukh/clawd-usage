import AppKit
import ClawdCore
import SwiftUI
import Combine

@main
struct ClawdMain {
    @MainActor static func main() {
        // A Codex that closed its stdin must make the write throw, not kill the app.
        signal(SIGPIPE, SIG_IGN)
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var model: AppModel!
    private var panel: NSPanel!
    /// One menu bar item per harness; created in this order, so Codex sits left of Claude.
    private var claudeItem: NSStatusItem!
    private var codexItem: NSStatusItem!
    private var preferences: NSWindow?
    private var cancellables: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let demo = CommandLine.arguments.contains("--demo")
        let snapshot = CommandLine.arguments.contains("--snapshot")
        if !snapshot, let identifier = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: identifier).contains(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
            NSApp.terminate(nil)
            return
        }
        model = AppModel(demo: demo)
        model.snapshot = snapshot
        if demo { model.expanded = false }
        if snapshot { model.minimal = CommandLine.arguments.contains("--minimal") }
        // Developer mode from the command line, e.g. for snapshots: --sky night --weather 95.
        func argument(_ name: String) -> String? {
            CommandLine.arguments.firstIndex(of: name).flatMap { $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil }
        }
        model.forcedPhase = argument("--sky").flatMap { SkyPhase(rawValue: $0) }
        model.forcedWeather = argument("--weather").flatMap { Int($0) }
        model.forcedCodexMood = argument("--astra").flatMap { AstraMood(rawValue: $0) }
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 410),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "Clawd"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.contentView = NSHostingView(rootView: WidgetView(model: model,
            hide: { [weak self] in self?.togglePanel() }))
        panel.setFrameAutosaveName(demo ? "ClawdDemoPanel" : "ClawdPanel")
        if !panel.setFrameUsingName(demo ? "ClawdDemoPanel" : "ClawdPanel") { panel.center() }
        model.onWindowPreferences = { [weak self] in self?.applyWindowPreferences() }
        model.onUsage = { [weak self] in self?.updateStatusItems() }
        model.$contentHeight.removeDuplicates().sink { [weak self] _ in DispatchQueue.main.async { self?.resizePanel() } }.store(in: &cancellables)
        claudeItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        codexItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        for item in [claudeItem!, codexItem!] {
            item.button?.target = self
            item.button?.action = #selector(statusClicked(_:))
            item.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
            item.button?.imagePosition = .imageLeading
            item.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        }
        claudeItem.button?.image = Self.clawdIcon
        codexItem.button?.image = Self.astraIcon
        updateStatusItems()
        applyWindowPreferences()
        keepOnScreen()
        panel.orderFrontRegardless()
        model.start()
        if let index = CommandLine.arguments.firstIndex(of: "--snapshot"), CommandLine.arguments.count > index + 1 {
            let path = CommandLine.arguments[index + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + (demo ? 2 : 6)) { [self] in
                if let view = panel.contentView,
                   let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                    view.cacheDisplay(in: view.bounds, to: bitmap)
                    guard let png = bitmap.representation(using: .png, properties: [:]) else { NSApp.terminate(nil); return }
                    do { try png.write(to: URL(fileURLWithPath: path)); print("Snapshot saved: \(path)") }
                    catch { print("Snapshot failed: \(error)") }
                }
                NSApp.terminate(nil)
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    func applicationWillTerminate(_ notification: Notification) { model?.stop() }
    func windowDidChangeOcclusionState(_ notification: Notification) {
        model.visible = panel.isVisible && panel.occlusionState.contains(.visible)
    }

    private func applyWindowPreferences() {
        panel.level = model.topmost ? .floating : .normal
        panel.collectionBehavior = model.allSpaces ? [.canJoinAllSpaces, .fullScreenAuxiliary] : [.moveToActiveSpace, .fullScreenAuxiliary]
        resizePanel()
    }
    /// The panel keeps its top-left corner and takes the widget's size at the chosen zoom.
    private func resizePanel() {
        let width = 340 * model.zoom
        guard model.contentHeight > 0 else { return }
        let height = (model.contentHeight * model.zoom).rounded(.up)
        guard panel.frame.width != width || panel.frame.height != height else { return }
        let top = panel.frame.maxY
        panel.setFrame(NSRect(x: panel.frame.minX, y: top - height, width: width, height: height), display: true)
        keepOnScreen()
    }
    private func keepOnScreen() {
        let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(panel.frame) }) ?? NSScreen.main
        guard let screen else { return }
        let area = screen.visibleFrame
        var frame = panel.frame
        frame.size.height = min(frame.height, area.height)
        frame.origin.x = max(area.minX, min(frame.minX, area.maxX - frame.width))
        frame.origin.y = max(area.minY, min(frame.minY, area.maxY - frame.height))
        panel.setFrame(frame, display: true)
    }
    /// Each harness that is on for the menu bar shows its own icon and main percentage. With both
    /// off, Clawd's icon stays alone, without numbers: the only way back to the widget and Settings.
    private func updateStatusItems() {
        guard claudeItem != nil else { return }
        claudeItem.isVisible = model.claudeInMenuBar || !model.codexInMenuBar
        codexItem.isVisible = model.codexInMenuBar
        if model.claudeInMenuBar {
            let percent = model.usage?.session.percent
            claudeItem.button?.title = " " + (percent.map { "\($0)%" } ?? "—") + (model.error != nil ? " !" : "")
            claudeItem.button?.toolTip = "Claude · " + (percent.map { "Session \($0)%" } ?? "Waiting for usage")
                + (model.usage?.week.map { " · Week \($0.percent)%" } ?? "")
        } else {
            claudeItem.button?.title = ""
            claudeItem.button?.toolTip = "Clawd"
        }
        if model.codexInMenuBar {
            let percent = model.codex?.limits.first?.limit.percent
            codexItem.button?.title = " " + (percent.map { "\($0)%" } ?? "—") + (model.codexError != nil ? " !" : "")
            codexItem.button?.toolTip = "Codex · " + (model.codex.map { $0.limits.map { "\($0.title.lowercased()) \($0.limit.percent)%" }.joined(separator: ", ") } ?? "Waiting for usage")
        }
    }
    /// Astra, the Codex star, in the same 1 pt pixels as Clawd's icon, eyes cut out.
    private static let astraIcon: NSImage = {
        let rows = ["........##........", ".......####.......", "......######......", "....##########....", "######.####.######",
                    "######.####.######", "....##########....", "......######......", ".......####.......", "........##........"]
        let image = NSImage(size: NSSize(width: 18, height: rows.count), flipped: true) { _ in
            NSColor.black.setFill()
            for (y, row) in rows.enumerated() { for (x, c) in row.enumerated() where c == "#" { NSRect(x: x, y: y, width: 1, height: 1).fill() } }
            return true
        }
        image.isTemplate = true
        return image
    }()
    /// Clawd standing, from the widget's sprite: 18×10 pixels of 1 pt (sharp on Retina), eyes cut out.
    /// A template image, so the menu bar tints it for light and dark appearance.
    private static let clawdIcon: NSImage = {
        let geo = ClawdSprite.geometry(ClawdFrame())
        let px = 1.0, py = 1.0, rows = 10.0   // the lower half-row is empty
        let image = NSImage(size: NSSize(width: Double(ClawdSprite.width) * px, height: rows * py), flipped: true) { _ in
            NSColor.black.setFill()
            for r in geo.body { NSRect(x: r.x * px, y: r.y * py, width: r.w * px, height: r.h * py).fill() }
            return true
        }
        image.isTemplate = true
        return image
    }()
    /// Either click opens the menu; the widget is shown or hidden from there.
    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        guard let statusItem = [claudeItem, codexItem].first(where: { $0?.button === sender }) ?? claudeItem else { return }
        let menu = NSMenu()
        menu.addItem(withTitle: panel.isVisible ? "Hide widget" : "Show widget", action: #selector(togglePanel), keyEquivalent: "")
        menu.addItem(withTitle: "Refresh usage", action: #selector(refresh), keyEquivalent: "r")
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(showPreferences), keyEquivalent: ",")
        menu.addItem(withTitle: "Quit Clawd", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }
    @objc private func togglePanel() {
        if panel.isVisible { panel.orderOut(nil); model.visible = false }
        else { keepOnScreen(); panel.orderFrontRegardless(); model.visible = true }
    }
    @objc private func refresh() { Task { await model.refresh() } }
    @objc private func woke() { refresh() }
    @objc private func screenChanged() { keepOnScreen() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func showPreferences() {
        model.refreshLaunchAtLogin()
        if preferences == nil {
            // At most the screen's visible height; the Form scrolls when the window is shorter.
            let area = NSScreen.main?.visibleFrame.height ?? 850
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 850),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "Clawd Settings"
            let host = NSHostingView(rootView: PreferencesView(model: model))
            // Only the minimum size comes from SwiftUI, so the window is not pinned to the Form's ideal height.
            host.sizingOptions = [.minSize]
            window.contentView = host
            window.contentMinSize = NSSize(width: 460, height: 360)
            window.contentMaxSize = NSSize(width: 460, height: CGFloat.greatestFiniteMagnitude)
            window.isReleasedWhenClosed = false
            let titleBar = window.frame.height - window.contentLayoutRect.height
            window.setContentSize(NSSize(width: 460, height: max(360, min(850, area - titleBar))))
            window.center()
            preferences = window
        }
        if let window = preferences, let area = (window.screen ?? NSScreen.main)?.visibleFrame, window.frame.height > area.height {
            var frame = window.frame
            frame.size.height = area.height
            frame.origin.y = area.minY
            window.setFrame(frame, display: true)
        }
        NSApp.activate(ignoringOtherApps: true)
        preferences?.makeKeyAndOrderFront(nil)
    }
}
