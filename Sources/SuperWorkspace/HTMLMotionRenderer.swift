import AppKit
import CoreGraphics
import SwiftUI
import WebKit

/// Drives HTML/CSS/SVG motion graphics at exact timeline timestamps for both
/// live transparent preview and frame-accurate MP4 export.
@MainActor
enum HTMLMotionRenderer {
    static let timeBridgeScript = """
    window.__swSeek = function(t, duration) {
      try {
        var ms = Math.max(0, t * 1000);
        if (document.getAnimations) {
          var anims = document.getAnimations({ subtree: true });
          for (var i = 0; i < anims.length; i++) {
            try {
              anims[i].pause();
              anims[i].currentTime = ms;
            } catch (e) {}
          }
        }
        if (typeof window.renderAt === 'function') {
          window.renderAt(t, duration);
        }
      } catch (e) {}
      return true;
    };
    """

    /// Renders an HTML motion overlay into a sequence of per-frame `SubtitleOverlay`
    /// images for `AssemblyCompositor` so exported MP4s match live preview frame for frame.
    static func renderFrames(
        _ item: HTMLMotionOverlay,
        url: URL,
        canvas: CGSize,
        fps: Double = 30
    ) async -> [SubtitleOverlay] {
        guard FileManager.default.fileExists(atPath: url.path),
              let html = try? String(contentsOf: url, encoding: .utf8),
              !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              item.end > item.start,
              canvas.width >= 2, canvas.height >= 2 else { return [] }

        let maxSide: CGFloat = 1280
        let scale = min(1.0, maxSide / max(canvas.width, canvas.height))
        let renderSize = CGSize(
            width: max(2, (canvas.width * scale).rounded()),
            height: max(2, (canvas.height * scale).rounded())
        )

        let config = WKWebViewConfiguration()
        let userContent = WKUserContentController()
        userContent.addUserScript(WKUserScript(source: timeBridgeScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        config.userContentController = userContent

        let webView = WKWebView(frame: CGRect(origin: .zero, size: renderSize), configuration: config)
        webView.setValue(false, forKey: "drawsBackground")

        let loader = NavigationWaiter()
        webView.navigationDelegate = loader
        webView.loadHTMLString(html, baseURL: url.deletingLastPathComponent())
        let loaded = await loader.wait()
        guard loaded else { return [] }

        // Allow initial layout & CSS animation registration.
        try? await Task.sleep(for: .milliseconds(80))

        let duration = item.end - item.start
        let frameStep = 1.0 / fps
        let frameCount = max(1, Int(ceil(duration * fps)))
        var overlays: [SubtitleOverlay] = []
        overlays.reserveCapacity(frameCount)

        let snapConfig = WKSnapshotConfiguration()
        snapConfig.rect = CGRect(origin: .zero, size: renderSize)
        snapConfig.snapshotWidth = NSNumber(value: Double(renderSize.width))

        for i in 0..<frameCount {
            if Task.isCancelled { return [] }
            let localTime = min(duration, Double(i) * frameStep)
            _ = try? await webView.callAsyncJavaScript(
                """
                window.__swSeek(t, dur);
                if (document.body) { void document.body.offsetHeight; }
                return await new Promise(resolve => {
                  let done = false;
                  const finish = () => { if (!done) { done = true; resolve(true); } };
                  requestAnimationFrame(() => finish());
                  setTimeout(finish, 18);
                });
                """,
                arguments: ["t": localTime, "dur": duration],
                in: nil,
                contentWorld: .page
            )
            if let nsImage = try? await webView.takeSnapshot(configuration: snapConfig),
               let cgImage = nsImage.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                let t0 = item.start + Double(i) * frameStep
                let t1 = min(item.end, t0 + frameStep + 0.001)
                overlays.append(SubtitleOverlay(
                    start: t0,
                    end: t1,
                    image: cgImage,
                    frame: CGRect(origin: .zero, size: canvas),
                    fadeDuration: 0
                ))
            }
        }
        return overlays
    }
}

@MainActor
private final class NavigationWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Bool, Never>?
    private var finished = false
    private var succeeded = false

    func wait() async -> Bool {
        if finished { return succeeded }
        return await withCheckedContinuation { cont in
            self.continuation = cont
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(8))
                self?.finish(false)
            }
        }
    }

    private func finish(_ ok: Bool) {
        guard !finished else { return }
        finished = true
        succeeded = ok
        continuation?.resume(returning: ok)
        continuation = nil
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finish(true)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finish(false)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finish(false)
    }
}

/// Live transparent WebKit overlay rendered on top of the preview player,
/// synced in real time to the timeline playhead.
struct HTMLMotionPreviewLayer: NSViewRepresentable {
    let url: URL
    let revision: Int
    let localTime: Double
    let duration: Double

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let userContent = WKUserContentController()
        userContent.addUserScript(WKUserScript(source: HTMLMotionRenderer.timeBridgeScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true))
        config.userContentController = userContent
        let webView = NonInteractiveWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = context.coordinator
        context.coordinator.load(url: url, revision: revision, into: webView, time: localTime, duration: duration)
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        if context.coordinator.loadedURL != url || context.coordinator.loadedRevision != revision {
            context.coordinator.load(url: url, revision: revision, into: nsView, time: localTime, duration: duration)
        } else {
            context.coordinator.seek(time: localTime, duration: duration, in: nsView)
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedURL: URL?
        var loadedRevision: Int = -1
        private var ready = false
        private var pendingTime: Double = 0
        private var pendingDuration: Double = 1

        func load(url: URL, revision: Int, into webView: WKWebView, time: Double, duration: Double) {
            loadedURL = url
            loadedRevision = revision
            ready = false
            pendingTime = time
            pendingDuration = duration
            if let html = try? String(contentsOf: url, encoding: .utf8) {
                webView.loadHTMLString(html, baseURL: url.deletingLastPathComponent())
            }
        }

        func seek(time: Double, duration: Double, in webView: WKWebView) {
            pendingTime = time
            pendingDuration = duration
            guard ready else { return }
            webView.evaluateJavaScript("window.__swSeek(\(time), \(duration));", completionHandler: nil)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            ready = true
            webView.evaluateJavaScript("window.__swSeek(\(pendingTime), \(pendingDuration));", completionHandler: nil)
        }
    }
}

private final class NonInteractiveWebView: WKWebView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
