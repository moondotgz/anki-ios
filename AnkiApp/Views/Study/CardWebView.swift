import AVFoundation
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Serves files from the media folder to card HTML as `anki-media://media/<file>`.
@MainActor
final class MediaSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "anki-media"
    let folder: URL

    init(folder: URL) { self.folder = folder }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let name = (url.path.removingPercentEncoding ?? url.path).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let fileURL = folder.appendingPathComponent((name as NSString).lastPathComponent)
        guard let data = try? Data(contentsOf: fileURL) else {
            task.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        let mime = UTType(filenameExtension: fileURL.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": mime, "Content-Length": String(data.count),
                                                      "Access-Control-Allow-Origin": "*"])!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {}
}

/// Plays `[sound:…]` files natively, in order.
@MainActor
final class SoundPlayer: NSObject, AVAudioPlayerDelegate {
    static let shared = SoundPlayer()
    private var player: AVAudioPlayer?
    private var queue: [URL] = []

    func play(_ files: [String], folder: URL) {
        stop()
        queue = files.map { folder.appendingPathComponent($0) }
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default, options: [.duckOthers])
        try? AVAudioSession.sharedInstance().setActive(true)
        playNext()
    }

    func stop() {
        queue.removeAll()
        player?.stop()
        player = nil
    }

    private func playNext() {
        while !queue.isEmpty {
            let url = queue.removeFirst()
            if let p = try? AVAudioPlayer(contentsOf: url) {
                p.delegate = self
                player = p
                p.play()
                return
            }
        }
    }

    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.playNext() }
    }
}

struct CardWebView: UIViewRepresentable {
    let html: String
    let mediaFolder: URL
    var onMessage: (String) -> Void = { _ in }
    @Binding var webViewRef: WKWebView?

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.setURLSchemeHandler(MediaSchemeHandler(folder: mediaFolder), forURLScheme: MediaSchemeHandler.scheme)
        config.userContentController.add(context.coordinator, name: "anki")
        config.allowsInlineMediaPlayback = true
        config.mediaTypesRequiringUserActionForPlayback = []
        let web = WKWebView(frame: .zero, configuration: config)
        web.isOpaque = false
        web.backgroundColor = .clear
        web.scrollView.backgroundColor = .clear
        web.scrollView.contentInsetAdjustmentBehavior = .never
        web.navigationDelegate = context.coordinator
        DispatchQueue.main.async { webViewRef = web }
        return web
    }

    func updateUIView(_ web: WKWebView, context: Context) {
        context.coordinator.parent = self
        guard context.coordinator.loadedHTML != html else { return }
        context.coordinator.loadedHTML = html
        web.loadHTMLString(html, baseURL: URL(string: "\(MediaSchemeHandler.scheme)://media/"))
    }

    static func dismantleUIView(_ web: WKWebView, coordinator: Coordinator) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "anki")
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate {
        var parent: CardWebView
        var loadedHTML = ""

        init(_ parent: CardWebView) { self.parent = parent }

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            if let body = message.body as? String { parent.onMessage(body) }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                     decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void)
        {
            // links in cards open in Safari rather than replacing the card
            if action.navigationType == .linkActivated, let url = action.request.url,
               url.scheme == "http" || url.scheme == "https"
            {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}

enum CardHTML {
    static func page(body: String, css: String, ord: Int, nightMode: Bool, fontScale: Double = 1) -> String {
        let needsMathJax = body.contains("\\(") || body.contains("\\[")
        let mathJax = needsMathJax ? """
            <script>window.MathJax = { tex: { inlineMath: [["\\\\(", "\\\\)"]], displayMath: [["\\\\[", "\\\\]"]] }, svg: { fontCache: "global" } };</script>
            <script async src="https://cdn.jsdelivr.net/npm/mathjax@3.2.2/es5/tex-svg.js"></script>
            """ : ""
        return """
            <!doctype html>
            <html>
            <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=4">
            <style>
            html { -webkit-text-size-adjust: \(Int(fontScale * 100))%; }
            body { margin: 0; padding: 68px 18px 180px; min-height: 100vh; box-sizing: border-box;
                   overflow-wrap: break-word; -webkit-user-select: text; }
            img { max-width: 100%; height: auto; }
            .nightMode.card, .nightMode .card { color: #f2f2f7; background-color: #1c1c1e; }
            .nightMode a { color: #64a8ff; }
            .replay-button { display: inline-block; vertical-align: middle; text-decoration: none; }
            .replay-button svg { width: 36px; height: 36px; margin: 4px; }
            .replay-button svg circle { fill: #ececec; stroke: #ccc; }
            .replay-button svg path { fill: #222; }
            .nightMode .replay-button svg circle { fill: #3a3a3c; stroke: #48484a; }
            .nightMode .replay-button svg path { fill: #f2f2f7; }
            #typeans { width: 100%; box-sizing: border-box; font-size: 1.1em; padding: 10px 12px;
                       border-radius: 12px; border: 1px solid #999; font-family: inherit; }
            code#typeans { display: inline-block; text-align: left; border: none; font-family: ui-monospace, Menlo, monospace; }
            .typeGood { background: #afa; color: black; }
            .typeBad { background: #faa; color: black; }
            .typeMissed { background: #ccc; color: black; }
            hr#answer { border: none; border-top: 1px solid rgba(128,128,128,0.4); margin: 18px 0; }
            </style>
            <style>\(css)</style>
            \(mathJax)
            </head>
            <body class="card card\(ord + 1)\(nightMode ? " nightMode night_mode" : "")">
            <div id="qa">\(body)</div>
            <script>
            function ankiPlay(name) { window.webkit.messageHandlers.anki.postMessage("play:" + name); }
            function _typeAnsPress() { if (window.event && window.event.keyCode === 13) { window.webkit.messageHandlers.anki.postMessage("ans"); } }
            function _getTypedAnswer() { var e = document.getElementById("typeans"); return e ? e.value : ""; }
            function _setTypeCompare(html) { var e = document.getElementById("typeansCompare"); if (e) { e.innerHTML = html; } }
            document.addEventListener("DOMContentLoaded", function () {
              var t = document.getElementById("typeans"); if (t && t.tagName === "INPUT") { setTimeout(function () { t.focus(); }, 50); }
            });
            </script>
            </body>
            </html>
            """
    }
}
