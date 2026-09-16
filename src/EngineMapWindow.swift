// =============================================================================
//  EngineMapWindow.swift — engine-selection map viewer
//  Shows the engine-selection map (docs/engine-map.html) in a native
//  WKWebView window.
//
//  Where the map comes from, in order:
//    1. The app bundle's Resources/engine-map.html — what a DMG install has.
//    2. ~/AI/tools/lm-switcher-engine-map.html — dev installs (install.sh
//       deploys it there so the diagram can be refreshed without a rebuild).
//
//  Why not a file:// Link: a file link goes through LaunchServices to
//  whatever app owns .html (Safari on this Mac). That cold-starts the
//  browser — it can take seconds, open in another Space, or silently
//  fail to surface, which reads as "clicking does nothing". An in-app
//  window is instant and deterministic, and the map is fully
//  self-contained (inline CSS/SVG, no network).
// =============================================================================

import AppKit
import WebKit

final class EngineMapWindow: NSObject, NSWindowDelegate {

    static let shared = EngineMapWindow()

    /// Deployed copy (dev installs; refreshed by scripts/install.sh).
    static var deployedPath: String {
        NSHomeDirectory() + "/AI/tools/lm-switcher-engine-map.html"
    }

    /// Best available source for the map: the bundled resource first (that
    /// is what a DMG install ships), then the deployed dev copy.
    static func resolveMapURL() -> URL? {
        if let bundled = Bundle.main.url(forResource: "engine-map", withExtension: "html") {
            return bundled
        }
        let deployed = URL(fileURLWithPath: deployedPath)
        if FileManager.default.fileExists(atPath: deployed.path) { return deployed }
        return nil
    }

    private var window: NSWindow?

    /// Bring the map window up; reuses the window when it is already open.
    func show() {
        if let w = window {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let rect = NSRect(x: 0, y: 0, width: 1100, height: 820)
        let w = NSWindow(contentRect: rect,
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered,
                         defer: false)
        w.title = "Which engine runs your model?"
        w.isReleasedWhenClosed = false
        w.delegate = self

        let web = WKWebView(frame: rect)
        if let url = Self.resolveMapURL() {
            // For a bundle resource the read access covers the whole bundle;
            // for the deployed copy, its own directory is enough.
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            // Actionable fallback instead of a dead click.
            web.loadHTMLString("""
            <html><body style="font:15px -apple-system;padding:40px;color:#1d1d1f">
            <h2>Engine map not found</h2>
            <p>Looked for <code>Contents/Resources/engine-map.html</code> in the app bundle
            and <code>\(Self.deployedPath)</code>.</p>
            <p>Reinstall the app from the release DMG, or run <code>bash scripts/install.sh</code>
            from the lm-switcher repo and reopen this window.</p>
            </body></html>
            """, baseURL: nil)
        }
        w.contentView = web
        w.center()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
        window = w
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
    }
}
