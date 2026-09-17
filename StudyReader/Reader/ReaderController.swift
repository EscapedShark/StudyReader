import SwiftUI
import WebKit
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct OutlineEntry: Identifiable, Decodable {
    let id: String
    let title: String
    let level: Int
}

struct ReaderPreferences {
    var fontSize: Double
    var theme: String
    var foldAnswers: Bool
    var dictionary: [String: Any] { ["fontSize": fontSize, "theme": theme, "foldAnswers": foldAnswers] }
}

final class ReaderAssets: NSObject, WKURLSchemeHandler {
    var libraryRoots: [String: URL] = [:]
    /// Attachments and the font files are read off the main thread: a 25 MB image otherwise
    /// blocks the whole interface while the article is scrolling.
    private let queue = DispatchQueue(label: "com.personal.studyreader.reader-assets", qos: .userInitiated, attributes: .concurrent)
    private var active: Set<ObjectIdentifier> = []

    private static func mimeType(for file: URL) -> String {
        switch file.pathExtension.lowercased() {
        case "js": return "application/javascript"
        case "css": return "text/css"
        case "html": return "text/html"
        case "woff2": return "font/woff2"
        case "woff": return "font/woff"
        case "ttf": return "font/ttf"
        default: return UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        }
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else { return }
        var root: URL?
        var relativePath = ""
        if url.host == "app", let bundled = Bundle.main.resourceURL?.appendingPathComponent("Reader") {
            root = bundled
            relativePath = String(url.path.dropFirst())
        } else if url.host == "library" {
            let parts = url.pathComponents.filter { $0 != "/" }
            if let id = parts.first, let libraryRoot = libraryRoots[id] {
                root = libraryRoot
                relativePath = parts.dropFirst().joined(separator: "/")
            }
        }
        guard let root else {
            urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
            return
        }
        // WebKit delivers start/stop on the main thread, so the in-flight set needs no lock.
        let token = ObjectIdentifier(urlSchemeTask)
        active.insert(token)
        let path = relativePath
        queue.async {
            let file = LibraryDisk.containedURL(root: root, relativePath: path)
            let data = file.flatMap { try? Data(contentsOf: $0, options: .mappedIfSafe) }
            let mime = file.map(Self.mimeType) ?? ""
            DispatchQueue.main.async {
                guard self.active.remove(token) != nil else { return }
                guard let data else {
                    urlSchemeTask.didFailWithError(URLError(.fileDoesNotExist))
                    return
                }
                urlSchemeTask.didReceive(URLResponse(url: url, mimeType: mime, expectedContentLength: data.count,
                                                     textEncodingName: mime.hasPrefix("text/") ? "utf-8" : nil))
                urlSchemeTask.didReceive(data)
                urlSchemeTask.didFinish()
            }
        }
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        active.remove(ObjectIdentifier(urlSchemeTask))
    }
}

@MainActor private final class ReaderMessageProxy: NSObject, WKScriptMessageHandler {
    weak var target: ReaderController?
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.receive(message)
    }
}

@MainActor final class ReaderController: NSObject, ObservableObject, WKNavigationDelegate {
    @Published var outline: [OutlineEntry] = []
    @Published var isLoading = true
    @Published var error: String?
    @Published var formula: String?
    @Published var findFailed = false
    let webView: WKWebView
    let assets: ReaderAssets
    /// Carries the article id because a save can land after the reader moved on to the next one.
    var onPosition: ((UUID, ReadingPosition, Date) -> Void)?
    private var ready = false
    private var payload: [String: Any]?
    private var latestSession: [UUID: String] = [:]
    private var activitySequence: [UUID: Int] = [:]

    override init() {
        let configuration = WKWebViewConfiguration()
        assets = ReaderAssets()
        configuration.setURLSchemeHandler(assets, forURLScheme: "reader")
        // Nothing in the article is persisted by the web layer, so skip the on-disk data store.
        configuration.websiteDataStore = .nonPersistent()
        let proxy = ReaderMessageProxy()
        configuration.userContentController.add(proxy, name: "reader")
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        proxy.target = self
        webView.navigationDelegate = self
        #if os(iOS)
        // A transparent WebView makes WebKit blend every tile it paints while the article scrolls.
        // The page fills its own background, so the view stays opaque and only the rubber-band
        // area beyond the article needs a colour that matches the paper.
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        applyPaper(for: "system")
        #endif
        #if DEBUG
        webView.isInspectable = true
        #endif
        observeAssistiveReading()
        webView.load(URLRequest(url: URL(string: "reader://app/index.html")!))
    }

    /// KaTeX draws every formula twice: the visible spans and an invisible MathML twin that only a
    /// screen reader uses. Laying the twin out costs about a third of a long article's first
    /// layout and it occupies no space, so the page skips it while nothing is reading it.
    private var assistiveReadingActive: Bool {
        #if os(macOS)
        return NSWorkspace.shared.isVoiceOverEnabled
        #else
        return UIAccessibility.isVoiceOverRunning || UIAccessibility.isSwitchControlRunning
        #endif
    }
    private func observeAssistiveReading() {
        #if os(iOS)
        // macOS has no such notification; it is re-read when an article opens and when the app
        // becomes active, which is soon enough for a setting that is changed by hand.
        for name in [UIAccessibility.voiceOverStatusDidChangeNotification, UIAccessibility.switchControlStatusDidChangeNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.pushAssistiveReading() }
            }
        }
        #endif
    }
    private func pushAssistiveReading() {
        guard ready, payload != nil else { return }
        call("window.Reader.assistive(active)", arguments: ["active": assistiveReadingActive])
    }

    var currentDocumentID: String? { payload?["id"] as? String }

    @discardableResult func display(_ document: LibraryDocument, markdown: String, position: ReadingPosition?, preferences: ReaderPreferences, roots: [String: URL], imageSizes: [String: [Int]] = [:], preferSavedPosition: Bool = false) -> String {
        let identifier = document.id.uuidString
        assets.libraryRoots = roots
        let session = UUID().uuidString
        latestSession[document.id] = session
        activitySequence[document.id] = 0
        var data: [String: Any] = ["id": identifier, "content": markdown,
                                   "baseURL": document.baseURL, "preferences": preferences.dictionary, "session": session,
                                   "imageSizes": imageSizes, "assistive": assistiveReadingActive,
                                   "preferSavedPosition": preferSavedPosition]
        if let position, let encoded = try? JSONEncoder().encode(position), let value = try? JSONSerialization.jsonObject(with: encoded) {
            data["position"] = value
        }
        payload = data
        error = nil
        outline = []
        #if os(iOS)
        applyPaper(for: preferences.theme)
        #endif
        if ready { render() }
        return session
    }
    private func render() {
        guard let payload else { return }
        isLoading = true
        call("window.Reader.render(payload)", arguments: ["payload": payload])
    }
    func preferences(_ preferences: ReaderPreferences) {
        payload?["preferences"] = preferences.dictionary
        #if os(iOS)
        applyPaper(for: preferences.theme)
        #endif
        if ready { call("window.Reader.preferences(preferences)", arguments: ["preferences": preferences.dictionary]) }
    }
    #if os(iOS)
    /// Mirrors `--paper` in reader.css, including the reader's own light/dark override.
    private func applyPaper(for theme: String) {
        let light = UIColor(red: 0.988, green: 0.984, blue: 0.969, alpha: 1)
        let dark = UIColor(red: 0.114, green: 0.141, blue: 0.137, alpha: 1)
        let color: UIColor
        switch theme {
        case "light": color = light
        case "dark": color = dark
        default: color = UIColor { $0.userInterfaceStyle == .dark ? dark : light }
        }
        webView.backgroundColor = color
        webView.scrollView.backgroundColor = color
    }
    #endif
    func scroll(to heading: OutlineEntry) {
        call("window.Reader.scrollToHeading(id)", arguments: ["id": heading.id])
    }
    func savePosition(for documentID: UUID? = nil, session expectedSession: String? = nil, suspend: Bool = false, cachedOnly: Bool = false,
                      completion: @escaping () -> Void = {}) {
        guard ready, let id = currentDocumentID, documentID == nil || documentID?.uuidString == id,
              let session = payload?["session"] as? String,
              expectedSession == nil || expectedSession == session else { completion(); return }
        webView.callAsyncJavaScript("return window.Reader.save(session, suspend, cachedOnly)",
                                   arguments: ["session": session, "suspend": suspend, "cachedOnly": cachedOnly], in: nil, in: .page) { [weak self] result in
            if case .success(let value) = result, let value = value as? [String: Any],
               let id = value["documentID"] as? String, let session = value["session"] as? String {
                self?.acceptPosition(value["position"], activity: value["activity"], id: id, session: session)
            }
            // The caller can now change selection or flush the actual captured position.
            completion()
        }
    }
    func prepareToLeave() async {
        await withCheckedContinuation { continuation in
            savePosition(suspend: true) { continuation.resume() }
        }
    }
    func resumeReading() {
        guard ready, let session = payload?["session"] as? String else { return }
        pushAssistiveReading()
        call("window.Reader.resume(session)", arguments: ["session": session])
    }
    private func acceptPosition(_ value: Any?, activity: Any?, id: String, session: String) {
        guard let documentID = UUID(uuidString: id), latestSession[documentID] == session,
              let value, let data = try? JSONSerialization.data(withJSONObject: value),
              (try? JSONDecoder().decode(ReadingPosition.self, from: data)) != nil else { return }
        if id == currentDocumentID { payload?["position"] = value }
        // WebKit reports the same checkpoint through both the message bridge and save callback.
        // Restoration, resize, font changes and duplicate callbacks never create a new read time.
        guard let activity = activity as? [String: Any], let sequence = activity["sequence"] as? Int,
              sequence > (activitySequence[documentID] ?? 0), let timestamp = activity["readAt"] as? Double, timestamp.isFinite,
              let position = activity["position"], let data = try? JSONSerialization.data(withJSONObject: position),
              let readingPosition = try? JSONDecoder().decode(ReadingPosition.self, from: data) else { return }
        activitySequence[documentID] = sequence
        onPosition?(documentID, readingPosition, Date(timeIntervalSince1970: timestamp / 1000))
    }
    func find(_ text: String) {
        let config = WKFindConfiguration()
        config.wraps = true
        let id = currentDocumentID, session = payload?["session"] as? String
        webView.find(text, configuration: config) { [weak self] result in
            guard self?.currentDocumentID == id, self?.payload?["session"] as? String == session else { return }
            self?.findFailed = !text.isEmpty && !result.matchFound
            if !text.isEmpty, result.matchFound { self?.call("window.Reader.navigationFinished()") }
        }
    }
    private func call(_ script: String, arguments: [String: Any] = [:]) {
        let documentID = currentDocumentID
        let session = payload?["session"] as? String
        webView.callAsyncJavaScript(script, arguments: arguments, in: nil, in: .page) { [weak self] result in
            guard self?.currentDocumentID == documentID, self?.payload?["session"] as? String == session else { return }
            if case .failure(let error) = result {
                self?.error = "阅读组件未能完成操作：\(error.localizedDescription)"
                self?.isLoading = false
            }
        }
    }
    func receive(_ message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, let body = message.body as? [String: Any],
              let id = body["documentID"] as? String, let event = body["event"] as? String,
              let session = body["session"] as? String else { return }
        let isCurrent = id == currentDocumentID && session == payload?["session"] as? String
        if event == "position" {
            acceptPosition(body["payload"], activity: body["activity"], id: id, session: session)
            return
        }
        guard isCurrent else { return }
        switch event {
        case "outline":
            if let value = body["payload"], let data = try? JSONSerialization.data(withJSONObject: value) {
                outline = (try? JSONDecoder().decode([OutlineEntry].self, from: data)) ?? []
            }
        case "ready": isLoading = false
        case "error": error = body["payload"] as? String; isLoading = false
        case "formula": formula = body["payload"] as? String
        default: break
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        ready = true
        render()
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        self.error = error.localizedDescription
        isLoading = false
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if navigationAction.navigationType == .other, url.scheme == "reader", url.host == "app", url.path == "/index.html" {
            decisionHandler(.allow)
            return
        }
        if navigationAction.navigationType == .linkActivated, ["http", "https"].contains(url.scheme ?? "") {
            #if os(macOS)
            NSWorkspace.shared.open(url)
            #else
            UIApplication.shared.open(url)
            #endif
        } else if navigationAction.navigationType == .linkActivated, let fragment = url.fragment, url.host == "app" {
            call("window.Reader.scrollToHeading(id)", arguments: ["id": fragment])
        }
        decisionHandler(.cancel)
    }
}

#if os(macOS)
struct ReaderWebView: NSViewRepresentable {
    let controller: ReaderController
    func makeNSView(context: Context) -> WKWebView { controller.webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
#else
struct ReaderWebView: UIViewRepresentable {
    let controller: ReaderController
    func makeUIView(context: Context) -> WKWebView { controller.webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
#endif
