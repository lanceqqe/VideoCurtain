import ApplicationServices
import Cocoa
import SafariServices

private let safariBundleID = "com.apple.Safari"
private let extensionBundleID = "com.local.VideoCurtain.Extension"

@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let curtain = Curtain()
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "rectangle.inset.filled", accessibilityDescription: "Video Curtain")
        let menu = NSMenu()
        menu.addItem(withTitle: "Убрать шторку", action: #selector(lowerCurtain), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Включить расширение в Safari…", action: #selector(openExtensionSettings), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Выйти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        item.menu = menu
        statusItem = item

        // Asks for the Accessibility permission on first launch.
        let prompt = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(prompt)

        curtain.restoreToolbarAfterRestart()
    }

    func applicationWillTerminate(_ notification: Notification) {
        curtain.lower()
    }

    // The extension reaches this app through videocurtain://enter and videocurtain://exit.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "videocurtain" {
            switch url.host {
            case "enter": curtain.raise()
            case "exit": curtain.lower()
            default: break
            }
        }
    }

    @objc private func lowerCurtain() {
        curtain.lower()
    }

    @objc private func openExtensionSettings() {
        SFSafariApplication.showPreferencesForExtension(withIdentifier: extensionBundleID)
    }
}

/// Hides Safari's fullscreen toolbar and covers whatever is left around the page with black.
final class Curtain {
    private var safariWindow: AXUIElement?
    private var safariApp: AXUIElement?

    // Saved to disk: if this app is killed mid-video, the next launch can still
    // put back the Safari setting it changed.
    private var weHidToolbar: Bool {
        get { UserDefaults.standard.bool(forKey: "weHidToolbar") }
        set { UserDefaults.standard.set(newValue, forKey: "weHidToolbar") }
    }
    private var strips: [NSPanel] = []
    private var timer: Timer?
    private var escapeMonitor: Any?
    private var terminationObserver: NSObjectProtocol?

    private var safariIsFrontmost: Bool {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier == safariBundleID
    }

    func raise() {
        guard safariWindow == nil, safariIsFrontmost, AXIsProcessTrusted(),
              let safari = NSWorkspace.shared.frontmostApplication else { return }

        let app = AXUIElementCreateApplication(safari.processIdentifier)
        guard let window: AXUIElement = AX.value(app, kAXFocusedWindowAttribute) else { return }
        safariWindow = window
        safariApp = app

        // Lets the page reach the top of the screen, so the video needs no black bar.
        if !weHidToolbar, let item = AX.alwaysShowToolbarItem(in: app), AX.isChecked(item),
           AXUIElementPerformAction(item, kAXPressAction as CFString) == .success {
            weHidToolbar = true
        }

        timer = Timer.scheduledTimer(timeInterval: 0.25, target: self, selector: #selector(tick), userInfo: nil, repeats: true)
        escapeMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return }
            MainActor.assumeIsolated { self?.lowerIfSafariIsFrontmost() }
        }
        terminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == safariBundleID else { return }
            MainActor.assumeIsolated { self?.lower() }
        }
        tick()
    }

    func lower() {
        timer?.invalidate()
        timer = nil
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        if let terminationObserver { NSWorkspace.shared.notificationCenter.removeObserver(terminationObserver) }
        terminationObserver = nil
        strips.forEach { $0.orderOut(nil) }
        strips = []
        safariWindow = nil
        if let safariApp { restoreToolbar(in: safariApp) }
        safariApp = nil
    }

    // One press, no re-check: the menu item's check mark lags by over half a second,
    // and pressing again on a stale reading would hide the toolbar again.
    // The flag stays set if Safari can't be reached, e.g. it has quit.
    private func restoreToolbar(in app: AXUIElement) {
        guard weHidToolbar, let item = AX.alwaysShowToolbarItem(in: app),
              AXUIElementPerformAction(item, kAXPressAction as CFString) == .success else { return }
        weHidToolbar = false
    }

    func restoreToolbarAfterRestart() {
        guard weHidToolbar else { return }
        // Waits so that a launch caused by a new video keeps the toolbar hidden instead.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
            guard safariWindow == nil,
                  let safari = NSRunningApplication.runningApplications(withBundleIdentifier: safariBundleID).first else { return }
            let app = AXUIElementCreateApplication(safari.processIdentifier)
            // Nothing has pressed it recently, so the check mark can be trusted here.
            if let item = AX.alwaysShowToolbarItem(in: app), AX.isChecked(item) {
                weHidToolbar = false
            } else {
                restoreToolbar(in: app)
            }
        }
    }

    private func lowerIfSafariIsFrontmost() {
        if safariIsFrontmost { lower() }
    }

    @objc private func tick() {
        guard let safariWindow else { return }
        // Fails once the window has been closed; nothing would ever lower the curtain otherwise.
        guard let windowFrame = AX.frame(of: safariWindow) else {
            lower()
            return
        }
        guard let webArea = AX.largestWebArea(in: safariWindow),
              let screen = screen(containing: windowFrame) else { return }
        layOut(around: AX.nsRect(from: webArea), on: screen)
    }

    private func layOut(around page: CGRect, on screen: NSScreen) {
        let full = screen.frame
        let hole = page.intersection(full).integral
        let frames = [
            CGRect(x: full.minX, y: hole.maxY, width: full.width, height: full.maxY - hole.maxY),
            CGRect(x: full.minX, y: full.minY, width: full.width, height: hole.minY - full.minY),
            CGRect(x: full.minX, y: hole.minY, width: hole.minX - full.minX, height: hole.height),
            CGRect(x: hole.maxX, y: hole.minY, width: full.maxX - hole.maxX, height: hole.height),
        ].filter { $0.width > 0 && $0.height > 0 }

        while strips.count < frames.count { strips.append(makeStrip()) }
        while strips.count > frames.count { strips.removeLast().orderOut(nil) }

        // Stays in place but invisible when another app comes up on this desktop.
        // Ordering it out instead could bring it back on the wrong desktop.
        let visible = safariIsFrontmost
        for (strip, frame) in zip(strips, frames) {
            if strip.frame != frame { strip.setFrame(frame, display: true) }
            strip.alphaValue = visible ? 1 : 0
            strip.ignoresMouseEvents = !visible
            if !strip.isVisible { strip.orderFrontRegardless() }
        }
    }

    private func makeStrip() -> NSPanel {
        // Non-activating, so a click on the black never takes focus from Safari.
        let strip = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        strip.backgroundColor = .black
        strip.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 2)
        strip.collectionBehavior = [.managed, .fullScreenAuxiliary]
        strip.hidesOnDeactivate = false
        strip.isReleasedWhenClosed = false
        strip.hasShadow = false
        return strip
    }

    private func screen(containing axFrame: CGRect) -> NSScreen? {
        let frame = AX.nsRect(from: axFrame)
        return NSScreen.screens.max { lhs, rhs in
            let left = lhs.frame.intersection(frame)
            let right = rhs.frame.intersection(frame)
            return left.width * left.height < right.width * right.height
        }
    }
}

/// Accessibility API helpers. AX rects have a top-left origin on the primary
/// screen; AppKit's have a bottom-left one.
enum AX {
    static func value<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &raw) == .success else { return nil }
        return raw as? T
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        var position = CGPoint.zero
        var size = CGSize.zero
        var rawPosition: CFTypeRef?
        var rawSize: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &rawPosition) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &rawSize) == .success,
              let rawPosition, let rawSize,
              AXValueGetValue(rawPosition as! AXValue, .cgPoint, &position),
              AXValueGetValue(rawSize as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    /// View > Always Show Toolbar in Full Screen, matched by title in English or Russian.
    static func alwaysShowToolbarItem(in app: AXUIElement) -> AXUIElement? {
        guard let bar: AXUIElement = value(app, kAXMenuBarAttribute),
              let menus: [AXUIElement] = value(bar, kAXChildrenAttribute) else { return nil }
        for menu in menus {
            guard let submenus: [AXUIElement] = value(menu, kAXChildrenAttribute),
                  let submenu = submenus.first,
                  let items: [AXUIElement] = value(submenu, kAXChildrenAttribute) else { continue }
            for item in items {
                guard let title: String = value(item, kAXTitleAttribute) else { continue }
                if (title.contains("Toolbar") && title.contains("Full Screen"))
                    || (title.contains("панель инструментов") && title.contains("полноэкранн")) {
                    return item
                }
            }
        }
        return nil
    }

    static func isChecked(_ item: AXUIElement) -> Bool {
        let mark: String? = value(item, kAXMenuItemMarkCharAttribute)
        return !(mark ?? "").isEmpty
    }

    /// Safari keeps hidden web areas around, so the biggest one is the visible page.
    static func largestWebArea(in element: AXUIElement, depth: Int = 0) -> CGRect? {
        if let role: String = value(element, kAXRoleAttribute), role == "AXWebArea" {
            return frame(of: element)
        }
        guard depth < 12, let children: [AXUIElement] = value(element, kAXChildrenAttribute) else { return nil }
        return children
            .compactMap { largestWebArea(in: $0, depth: depth + 1) }
            .max { $0.width * $0.height < $1.width * $1.height }
    }

    private static var primaryHeight: CGFloat {
        NSScreen.screens.first?.frame.height ?? 0
    }

    static func nsRect(from ax: CGRect) -> CGRect {
        CGRect(x: ax.minX, y: primaryHeight - ax.maxY, width: ax.width, height: ax.height)
    }
}
