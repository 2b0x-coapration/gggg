import SwiftUI
import WebKit

let searchURL = "https://www.google.com/search?q="
let homeBase = URL(string: "https://supergo.newtab/")!

func toURL(_ s: String) -> URL? {
    let x = s.trimmingCharacters(in: .whitespacesAndNewlines)
    if x.isEmpty { return nil }
    if x.range(of: "^[a-zA-Z][a-zA-Z0-9+.-]*://", options: .regularExpression) != nil { return URL(string: x) }
    if !x.contains(" ") && (x.contains(".") || x.hasPrefix("localhost")) { return URL(string: "https://" + x) }
    return URL(string: searchURL + (x.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? x))
}

let downloadsDir: URL = {
    let u = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Downloads")
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}()
func uniqueURL(_ name: String) -> URL {
    var u = downloadsDir.appendingPathComponent(name)
    let ext = u.pathExtension, base = u.deletingPathExtension().lastPathComponent
    var n = 1
    while FileManager.default.fileExists(atPath: u.path) {
        u = downloadsDir.appendingPathComponent(ext.isEmpty ? "\(base) (\(n))" : "\(base) (\(n)).\(ext)"); n += 1
    }
    return u
}
extension URL: Identifiable { public var id: String { absoluteString } }

final class DownloadItem: NSObject, ObservableObject, Identifiable {
    let download: WKDownload
    @Published var name: String
    @Published var progress = 0.0
    @Published var state = 0   // 0 downloading, 1 done, 2 failed
    var fileURL: URL?
    var obs: NSKeyValueObservation?
    init(_ d: WKDownload, name: String) {
        download = d; self.name = name
        super.init()
        obs = d.progress.observe(\.fractionCompleted) { [weak self] p, _ in DispatchQueue.main.async { self?.progress = p.fractionCompleted } }
    }
}

final class DownloadManager: NSObject, WKDownloadDelegate {
    static let shared = DownloadManager()
    var items: [ObjectIdentifier: DownloadItem] = [:]
    var onStart: ((DownloadItem) -> Void)?
    var onEnd: ((DownloadItem) -> Void)?
    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping (URL?) -> Void) {
        let dest = uniqueURL(suggestedFilename.replacingOccurrences(of: "/", with: "_"))
        let item = DownloadItem(download, name: dest.lastPathComponent)
        item.fileURL = dest
        items[ObjectIdentifier(download)] = item
        onStart?(item)
        completionHandler(dest)
    }
    func downloadDidFinish(_ download: WKDownload) {
        guard let i = items[ObjectIdentifier(download)] else { return }
        DispatchQueue.main.async { i.progress = 1; i.state = 1; self.onEnd?(i) }
        items[ObjectIdentifier(download)] = nil
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let i = items[ObjectIdentifier(download)] else { return }
        if let f = i.fileURL { try? FileManager.default.removeItem(at: f) }
        DispatchQueue.main.async { i.state = 2; self.onEnd?(i) }
        items[ObjectIdentifier(download)] = nil
    }
}

final class Tab: NSObject, ObservableObject, WKNavigationDelegate, WKUIDelegate {
    let web: WKWebView
    let priv: Bool
    var desktop = false
    @Published var url: URL?
    @Published var title = "New Tab"
    @Published var loading = false
    @Published var progress = 0.0
    @Published var canBack = false
    @Published var canFwd = false
    var obs: [NSKeyValueObservation] = []
    var onFinish: ((Tab) -> Void)?

    init(priv: Bool, rules: [WKContentRuleList], desktop: Bool) {
        let cfg = WKWebViewConfiguration()
        if priv { cfg.websiteDataStore = .nonPersistent() }
        cfg.allowsInlineMediaPlayback = true
        rules.forEach { cfg.userContentController.add($0) }
        web = WKWebView(frame: .zero, configuration: cfg)
        self.priv = priv
        self.desktop = desktop
        super.init()
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
        web.isOpaque = false
        web.backgroundColor = .black
        web.scrollView.backgroundColor = .black
        web.scrollView.contentInset.bottom = 130
        web.scrollView.verticalScrollIndicatorInsets.bottom = 130
        func m(_ f: @escaping () -> Void) { DispatchQueue.main.async(execute: f) }
        obs = [
            web.observe(\.url) { [weak self] w, _ in m { self?.url = w.url } },
            web.observe(\.title) { [weak self] w, _ in m { if let t = w.title, !t.isEmpty { self?.title = t } } },
            web.observe(\.isLoading) { [weak self] w, _ in m { self?.loading = w.isLoading } },
            web.observe(\.estimatedProgress) { [weak self] w, _ in m { self?.progress = w.isLoading ? w.estimatedProgress : 0 } },
            web.observe(\.canGoBack) { [weak self] w, _ in m { self?.canBack = w.canGoBack } },
            web.observe(\.canGoForward) { [weak self] w, _ in m { self?.canFwd = w.canGoForward } },
        ]
    }

    var isHome: Bool { url == nil || url?.host == "supergo.newtab" || url?.absoluteString == "about:blank" }

    func load(_ u: URL) { web.load(URLRequest(url: u)) }

    func loadHome(bookmarks: [[String]]) {
        func esc(_ s: String) -> String { s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: "'", with: "&#39;") }
        let fav = bookmarks.prefix(12).map { b -> String in
            let n = b[0].trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "?"
            return "<a href='\(esc(b[1]))'><i>\(esc(n))</i><span>\(esc(String(b[0].prefix(12))))</span></a>"
        }.joined()
        let html = """
        <meta name=viewport content='width=device-width,initial-scale=1'><style>
        body{background:#000;color:#fff;font-family:-apple-system,sans-serif;margin:0;padding:18vh 20px 160px;text-align:center}
        h1{font-size:15px;letter-spacing:6px;font-weight:600;color:#8e8e93;margin:0 0 26px}
        input{width:100%;box-sizing:border-box;padding:15px 20px;font-size:17px;border-radius:26px;border:0;outline:0;background:#1c1c1e;color:#fff}
        p{display:flex;flex-wrap:wrap;justify-content:center;gap:18px;margin-top:34px}
        a{width:72px;text-decoration:none;color:#fff;font-size:12px}
        i{display:block;width:60px;height:60px;line-height:60px;margin:0 auto 6px;border-radius:16px;background:#1c1c1e;font-style:normal;font-size:24px;color:#0a84ff}
        </style><h1>SUPERGO</h1><form action='https://www.google.com/search'><input name=q placeholder='Search Google or enter website' autocomplete=off></form>\(fav.isEmpty ? "" : "<p>\(fav)</p>")
        """
        web.loadHTMLString(html, baseURL: homeBase)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, preferences: WKWebpagePreferences, decisionHandler: @escaping (WKNavigationActionPolicy, WKWebpagePreferences) -> Void) {
        preferences.preferredContentMode = desktop ? .desktop : .mobile
        if navigationAction.shouldPerformDownload { decisionHandler(.download, preferences); return }
        if let u = navigationAction.request.url, let s = u.scheme, !["http", "https", "about", "data", "blob"].contains(s) {
            UIApplication.shared.open(u); decisionHandler(.cancel, preferences); return
        }
        decisionHandler(.allow, preferences)
    }
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse, decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if let r = navigationResponse.response as? HTTPURLResponse,
           let cd = r.value(forHTTPHeaderField: "Content-Disposition"), cd.lowercased().hasPrefix("attachment") { decisionHandler(.download); return }
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .download)
    }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = DownloadManager.shared }
    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = DownloadManager.shared }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onFinish?(self) }
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }
}

final class Browser: ObservableObject {
    @Published var tabs: [Tab] = []
    @Published var cur = 0
    @Published var adblock = UserDefaults.standard.object(forKey: "ab") as? Bool ?? true {
        didSet { UserDefaults.standard.set(adblock, forKey: "ab"); applyAdblock() }
    }
    @Published var desktop = false {
        didSet { tabs.forEach { $0.desktop = desktop }; current?.web.reload() }
    }
    @Published var bookmarks: [[String]] = UserDefaults.standard.array(forKey: "bm") as? [[String]] ?? []
    @Published var history: [[String]] = UserDefaults.standard.array(forKey: "hist") as? [[String]] ?? []
    @Published var downloads: [DownloadItem] = []
    @Published var banner: DownloadItem?
    var rules: [WKContentRuleList] = []

    var current: Tab? { tabs.indices.contains(cur) ? tabs[cur] : nil }

    init() {
        DownloadManager.shared.onStart = { [weak self] item in DispatchQueue.main.async { self?.downloads.insert(item, at: 0); self?.banner = item } }
        DownloadManager.shared.onEnd = { [weak self] item in
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { if self?.banner === item { self?.banner = nil } }
        }
        let files = (Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? []).filter { $0.lastPathComponent.hasPrefix("blocklist") }
        let group = DispatchGroup()
        for (i, f) in files.enumerated() {
            guard let json = try? String(contentsOf: f) else { continue }
            group.enter()
            WKContentRuleListStore.default().compileContentRuleList(forIdentifier: "sg\(i)", encodedContentRuleList: json) { list, _ in
                if let l = list { self.rules.append(l) }
                group.leave()
            }
        }
        group.notify(queue: .main) { self.newTab() }
    }

    func newTab(priv: Bool = false, url: URL? = nil) {
        let t = Tab(priv: priv, rules: adblock ? rules : [], desktop: desktop)
        t.onFinish = { [weak self] tab in
            guard let self = self, !tab.priv, let u = tab.url, u.scheme?.hasPrefix("http") == true, u.host != "supergo.newtab" else { return }
            self.history.removeAll { $0[1] == u.absoluteString }
            self.history.insert([tab.title, u.absoluteString], at: 0)
            self.history = Array(self.history.prefix(200))
            UserDefaults.standard.set(self.history, forKey: "hist")
        }
        tabs.append(t); cur = tabs.count - 1
        if let u = url { t.load(u) } else { t.loadHome(bookmarks: bookmarks) }
    }
    func close(_ i: Int) {
        tabs.remove(at: i)
        if tabs.isEmpty { newTab() } else { cur = min(cur, tabs.count - 1) }
    }
    func applyAdblock() {
        for t in tabs {
            t.web.configuration.userContentController.removeAllContentRuleLists()
            if adblock { rules.forEach { t.web.configuration.userContentController.add($0) } }
        }
        current?.web.reload()
    }
    func addBookmark() {
        guard let t = current, let u = t.url, !t.isHome else { return }
        bookmarks.removeAll { $0[1] == u.absoluteString }
        bookmarks.insert([t.title, u.absoluteString], at: 0)
        UserDefaults.standard.set(bookmarks, forKey: "bm")
    }
    func clearData() {
        WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {}
        history = []; UserDefaults.standard.removeObject(forKey: "hist")
    }
}

struct WebHost: UIViewRepresentable {
    let web: WKWebView
    func makeUIView(context: Context) -> WKWebView { web }
    func updateUIView(_ v: WKWebView, context: Context) {}
}
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ c: UIActivityViewController, context: Context) {}
}

enum Sheet: Int, Identifiable { case tabs, bookmarks, history, share, edit, downloads; var id: Int { rawValue } }

struct ContentView: View {
    @StateObject var b = Browser()
    @State var sheet: Sheet?
    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.ignoresSafeArea()
            if let t = b.current {
                WebHost(web: t.web).id(ObjectIdentifier(t)).ignoresSafeArea(.container, edges: .bottom)
                ProgressLine(t: t)
                VStack(spacing: 8) {
                    Spacer()
                    if let d = b.banner { DownloadBanner(item: d) { sheet = .downloads } }
                    Bar(b: b, t: t, sheet: $sheet)
                }
            }
        }
        .preferredColorScheme(.dark)
        .sheet(item: $sheet) { s in
            switch s {
            case .tabs: TabsView(b: b, sheet: $sheet)
            case .bookmarks: ListView(title: "Bookmarks", items: b.bookmarks, b: b, sheet: $sheet) { b.bookmarks = []; UserDefaults.standard.removeObject(forKey: "bm") }
            case .history: ListView(title: "History", items: b.history, b: b, sheet: $sheet) { b.clearData() }
            case .share: ShareSheet(items: [b.current?.url as Any])
            case .edit: EditView(b: b, sheet: $sheet)
            case .downloads: DownloadsView(b: b, sheet: $sheet)
            }
        }
    }
}

struct ProgressLine: View {
    @ObservedObject var t: Tab
    var body: some View {
        VStack { Rectangle().fill(Color(red: 0.04, green: 0.52, blue: 1)).frame(height: 2)
            .scaleEffect(x: CGFloat(t.progress), anchor: .leading).animation(.easeOut(duration: 0.15), value: t.progress)
            Spacer() }.allowsHitTesting(false)
    }
}

struct Bar: View {
    @ObservedObject var b: Browser
    @ObservedObject var t: Tab
    @Binding var sheet: Sheet?
    var label: String { t.isHome ? (t.priv ? "Private Browsing" : "Search or enter website") : (t.url?.host?.replacingOccurrences(of: "www.", with: "") ?? "") }
    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 0) {
                Menu { menuItems } label: { Text("aA").font(.system(size: 15)).foregroundColor(.white).frame(width: 46, height: 46) }
                Button { sheet = .edit } label: {
                    Text(label).font(.system(size: 16)).lineLimit(1).foregroundColor(t.isHome ? .gray : .white).frame(maxWidth: .infinity, minHeight: 46)
                }
                Button { t.loading ? t.web.stopLoading() : t.web.reload() } label: {
                    Image(systemName: t.loading ? "xmark" : "arrow.clockwise").font(.system(size: 15, weight: .semibold)).foregroundColor(.white).frame(width: 46, height: 46)
                }
            }
            .background(Color.white.opacity(0.12), in: Capsule())
            HStack {
                icon("chevron.left", on: t.canBack) { t.web.goBack() }
                icon("chevron.right", on: t.canFwd) { t.web.goForward() }
                icon("square.and.arrow.up", on: !t.isHome) { sheet = .share }
                icon("book", on: true) { sheet = .bookmarks }
                Button { sheet = .tabs } label: {
                    Image(systemName: "square.on.square").font(.system(size: 20)).foregroundColor(.white)
                        .overlay(Text("\(b.tabs.count)").font(.system(size: 9, weight: .bold)).foregroundColor(.white).offset(x: -2.5, y: 2.5))
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                Menu { menuItems } label: { Image(systemName: "ellipsis").font(.system(size: 20)).foregroundColor(.white).frame(maxWidth: .infinity, minHeight: 44) }
            }
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 32, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 32, style: .continuous).strokeBorder(
            LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.05), .white.opacity(0.05), .white.opacity(0.3)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
        .padding(.horizontal, 10).padding(.bottom, 2)
    }
    func icon(_ name: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: name).font(.system(size: 20)).foregroundColor(.white).frame(maxWidth: .infinity, minHeight: 44) }
            .opacity(on ? 1 : 0.3).disabled(!on)
    }
    @ViewBuilder var menuItems: some View {
        Button { b.newTab() } label: { Label("New Tab", systemImage: "plus") }
        Button { b.newTab(priv: true) } label: { Label("New Private Tab", systemImage: "hand.raised") }
        Button { b.addBookmark() } label: { Label("Add Bookmark", systemImage: "star") }
        Button { sheet = .history } label: { Label("History", systemImage: "clock") }
        Button { sheet = .downloads } label: { Label("Downloads", systemImage: "arrow.down.circle") }
        Toggle("Request Desktop Site", isOn: $b.desktop)
        Toggle("Ad Blocker", isOn: $b.adblock)
        Button(role: .destructive) { b.clearData() } label: { Label("Clear History and Data", systemImage: "trash") }
    }
}

struct EditView: View {
    @ObservedObject var b: Browser
    @Binding var sheet: Sheet?
    @State var text = ""
    @FocusState var focus: Bool
    var body: some View {
        VStack {
            TextField("Search Google or enter website", text: $text)
                .focused($focus).textInputAutocapitalization(.never).disableAutocorrection(true).keyboardType(.webSearch).submitLabel(.go)
                .padding(14).background(Color.white.opacity(0.12), in: Capsule())
                .onSubmit { if let u = toURL(text) { b.current?.load(u) }; sheet = nil }
            Spacer()
        }.padding().background(Color.black.ignoresSafeArea())
        .onAppear { if let t = b.current, !t.isHome { text = t.url?.absoluteString ?? "" }; focus = true }
    }
}

struct ListView: View {
    let title: String
    let items: [[String]]
    @ObservedObject var b: Browser
    @Binding var sheet: Sheet?
    let clear: () -> Void
    var body: some View {
        NavigationView {
            List(items.indices, id: \.self) { i in
                Button { if let u = URL(string: items[i][1]) { b.current?.load(u) }; sheet = nil } label: {
                    VStack(alignment: .leading) { Text(items[i][0]).lineLimit(1); Text(items[i][1]).font(.caption).foregroundColor(.gray).lineLimit(1) }
                }
            }
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarLeading) { Button("Clear") { clear(); sheet = nil } }
                       ToolbarItem(placement: .navigationBarTrailing) { Button("Done") { sheet = nil } } }
        }
    }
}

struct TabsView: View {
    @ObservedObject var b: Browser
    @Binding var sheet: Sheet?
    var body: some View {
        NavigationView {
            List {
                ForEach(Array(b.tabs.enumerated()), id: \.offset) { i, t in
                    HStack {
                        Button { b.cur = i; sheet = nil } label: {
                            HStack { Image(systemName: i == b.cur ? "circle.fill" : "circle").font(.system(size: 8))
                                Text((t.priv ? "Private • " : "") + (t.isHome ? "Start Page" : t.title)).lineLimit(1) }
                        }
                        Spacer()
                        Button { b.close(i); if b.tabs.count == 1 && t.isHome { } } label: { Image(systemName: "xmark.circle.fill").foregroundColor(.gray) }.buttonStyle(.borderless)
                    }
                }
            }
            .navigationTitle("\(b.tabs.count) Tabs").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .navigationBarLeading) { Button { b.newTab(); sheet = nil } label: { Image(systemName: "plus") } }
                       ToolbarItem(placement: .navigationBarTrailing) { Button("Done") { sheet = nil } } }
        }
    }
}

struct DownloadBanner: View {
    @ObservedObject var item: DownloadItem
    var tap: () -> Void
    var body: some View {
        Button(action: tap) {
            HStack(spacing: 12) {
                Image(systemName: item.state == 1 ? "checkmark.circle.fill" : item.state == 2 ? "exclamationmark.circle.fill" : "arrow.down.circle")
                    .font(.system(size: 24)).foregroundColor(item.state == 1 ? .green : item.state == 2 ? .red : Color(red: 0.04, green: 0.52, blue: 1))
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name).font(.system(size: 14, weight: .medium)).lineLimit(1)
                    if item.state == 0 { ProgressView(value: item.progress) }
                    else { Text(item.state == 1 ? "Download complete \u{2022} tap to open" : "Download failed").font(.caption).foregroundColor(.gray) }
                }
                Spacer()
            }
            .foregroundColor(.white).padding(12)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(Color.white.opacity(0.18), lineWidth: 1))
        }.padding(.horizontal, 10)
    }
}

struct ActiveRow: View {
    @ObservedObject var item: DownloadItem
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(item.name).lineLimit(1)
            if item.state == 0 { ProgressView(value: item.progress) } else { Text("Failed").font(.caption).foregroundColor(.red) }
        }
    }
}

struct DownloadsView: View {
    @ObservedObject var b: Browser
    @Binding var sheet: Sheet?
    @State var files: [URL] = []
    @State var sharing: URL?
    func date(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
    func refresh() {
        files = ((try? FileManager.default.contentsOfDirectory(at: downloadsDir, includingPropertiesForKeys: nil)) ?? []).sorted { date($0) > date($1) }
    }
    var body: some View {
        NavigationView {
            List {
                let active = b.downloads.filter { $0.state != 1 }
                if !active.isEmpty { Section("In progress") { ForEach(active) { ActiveRow(item: $0) } } }
                Section(files.isEmpty ? "No downloads yet" : "Downloads") {
                    ForEach(files, id: \.self) { f in
                        Button { sharing = f } label: {
                            HStack { Image(systemName: "doc").foregroundColor(.gray); Text(f.lastPathComponent).lineLimit(1) }
                        }
                    }.onDelete { idx in idx.forEach { try? FileManager.default.removeItem(at: files[$0]) }; refresh() }
                }
            }
            .navigationTitle("Downloads").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Files") { if let u = URL(string: "shareddocuments://" + downloadsDir.path) { UIApplication.shared.open(u) } }
                }
                ToolbarItem(placement: .navigationBarTrailing) { Button("Done") { sheet = nil } }
            }
        }
        .onAppear(perform: refresh)
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in refresh() }
        .sheet(item: $sharing) { ShareSheet(items: [$0]) }
    }
}

@main struct SuperGoApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}
