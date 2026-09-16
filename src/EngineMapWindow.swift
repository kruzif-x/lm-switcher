// =============================================================================
//  EngineMapWindow.swift — engine-selection map viewer
//  Shows docs/engine-map.html (installed by scripts/install.sh to
//  ~/AI/tools/lm-switcher-engine-map.html) in a native WKWebView window.
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

    /// Absolute path to the deployed map. Stable, outside the app bundle,
    /// so the diagram can be updated without a rebuild (same pattern as
    /// the ds4 chat page).
    static var mapPath: String {
        NSHomeDirectory() + "/AI/tools/lm-switcher-engine-map.html"
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
        if FileManager.default.fileExists(atPath: Self.mapPath) {
            let url = URL(fileURLWithPath: Self.mapPath)
            web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        } else {
            // Actionable fallback instead of a dead click.
            web.loadHTMLString("""
            <html><body style="font:15px -apple-system;padding:40px;color:#1d1d1f">
            <h2>Engine map not installed</h2>
            <p>Expected at <code>\(Self.mapPath)</code>.</p>
            <p>Run <code>bash scripts/install.sh</code> from the lm-switcher repo, then reopen this window.</p>
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
