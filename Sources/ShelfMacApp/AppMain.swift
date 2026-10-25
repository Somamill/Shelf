import AppKit
import CryptoKit
import ImageIO
import Foundation
import UniformTypeIdentifiers
import Security
import WebKit
import ShelfCore

private final class WeakScriptMessageHandler:NSObject, WKScriptMessageHandler {
    weak var target:WKScriptMessageHandler?
    init(_ target:WKScriptMessageHandler) { self.target=target }
    func userContentController(_ userContentController:WKUserContentController,didReceive message:WKScriptMessage) {
        target?.userContentController(userContentController,didReceive:message)
    }
}

private final class DroppableWebView:WKWebView {
    var onEPUBDrop:(([URL])->Void)?
    override init(frame:CGRect,configuration:WKWebViewConfiguration) {
        super.init(frame:frame,configuration:configuration)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder:NSCoder) { super.init(coder:coder) }
    override func draggingEntered(_ sender:NSDraggingInfo)->NSDragOperation {
        let urls=sender.draggingPasteboard.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL] ?? []
        return urls.contains(where:{$0.pathExtension.lowercased()=="epub"}) ? .copy : []
    }
    override func performDragOperation(_ sender:NSDraggingInfo)->Bool {
        let urls=sender.draggingPasteboard.readObjects(forClasses:[NSURL.self],options:[.urlReadingFileURLsOnly:true]) as? [URL] ?? []
        let epubs=urls.filter{$0.pathExtension.lowercased()=="epub"}
        guard !epubs.isEmpty else { return false }
        onEPUBDrop?(epubs)
        return true
    }
}

/// Lets EPUB text selection and page interaction pass through the transparent reader chrome.
private final class ReaderOverlayView:NSView {
    override func hitTest(_ point:NSPoint)->NSView? {
        let hit=super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// Machine-specific paths and service addresses live outside the public source tree.
private struct ShelfConfiguration {
    private var values: [String: Any]
    private let fileURL: URL

    static func load() -> ShelfConfiguration {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Shelf", isDirectory: true)
        let local = ProcessInfo.processInfo.environment["SHELF_CONFIG"].map { URL(fileURLWithPath: $0) }
            ?? support.appendingPathComponent("config.json")
        if let data = try? Data(contentsOf: local), let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return ShelfConfiguration(values: values, fileURL: local)
        }
        return ShelfConfiguration(values: [:], fileURL: local)
    }

    private init(values: [String: Any], fileURL: URL) { self.values = values; self.fileURL = fileURL }

    func value(_ dottedKey: String, fallback: String) -> String {
        let parts = dottedKey.split(separator: ".").map(String.init)
        var current: Any = values
        for part in parts {
            guard let dictionary = current as? [String: Any], let next = dictionary[part] else { return fallback }
            current = next
        }
        guard let value = current as? String, !value.isEmpty else { return fallback }
        return value
    }

    func bool(_ key: String, fallback: Bool = false) -> Bool { values[key] as? Bool ?? fallback }
    func strings(_ key: String) -> [String] { values[key] as? [String] ?? [] }

    mutating func set(_ dottedKey: String, _ value: Any) throws {
        let parts = dottedKey.split(separator: ".").map(String.init)
        guard !parts.isEmpty else { return }
        func update(_ dictionary: inout [String: Any], _ index: Int) {
            let part = parts[index]
            if index == parts.count - 1 { dictionary[part] = value; return }
            var child = dictionary[part] as? [String: Any] ?? [:]
            update(&child, index + 1)
            dictionary[part] = child
        }
        update(&values, 0)
        let data = try JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys])
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    func dictionary(_ key: String) -> [String: Any] { values[key] as? [String: Any] ?? [:] }

    func path(_ key: String, fallback: String) -> String {
        let raw = value("paths.\(key)", fallback: fallback)
        if raw == "~" { return NSHomeDirectory() }
        if raw.hasPrefix("~/") { return (NSHomeDirectory() as NSString).appendingPathComponent(String(raw.dropFirst(2))) }
        return (raw as NSString).expandingTildeInPath
    }
}

@main
final class DashboardApp: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate, NSWindowDelegate {
    private var window: NSWindow!
    private var webView: WKWebView!
    private var refreshTimer: Timer?
    private var refreshInProgress = false
    private var updateCheckInProgress=false
    private var dashboardContentView:NSView?
    private var readerContentView:NSView?
    private var readerWebView:WKWebView?
    private var readerTempDirectory:URL?
    private var readerWorkIsPersistentCache=false
    private var activeReader:[String:Any]?
    private var readerPageLabel:NSTextField?
    private var readerHighlightButton:NSButton?
    private var readerChapterMenu:NSPopUpButton?
    private var readerFontMenu:NSPopUpButton?
    private var readerThemeMenu:NSPopUpButton?
    private var readerSpacingMenu:NSPopUpButton?
    private var readerSizeLabel:NSTextField?
    private var readerProgressSlider:NSSlider?
    private var readerProgressLabel:NSTextField?
    private var readerSettingsPopover:NSPopover?
    private var readerChapters:[[String:Any]]=[]
    private var readerFontSize:Double=19
    private var readerFontChoice="sans"
    private var readerIsJapanese=false
    private var loadingLabel: NSTextField!
    private var updates: [String: Any] = ["calibreInstalled":"9.16", "calibreLatest":"Not checked", "crossPointInstalled":"1.6.0", "crossPointLatest":"Not checked", "checkedAt":NSNull()]
    private let uid = String(getuid())
    private var configuration = ShelfConfiguration.load()
    private var home: String { NSHomeDirectory() }
    private var base: String { configuration.path("booksRoot", fallback: "~/Books") }
    private var libraryPath: String { configuration.path("library", fallback: "\(base)/Calibre Library") }
    private var statePath: String { configuration.path("state", fallback: "\(base)/state") }
    private var scriptsPath: String { configuration.path("scripts", fallback: "\(base)/scripts") }
    private var logsPath: String { configuration.path("logs", fallback: "\(base)/logs") }
    private var importPath: String { configuration.path("import", fallback: "\(home)/Books/Calibre Import") }
    private var projectPath: String { configuration.path("project", fallback: "~/Shelf") }
    private var bridgeScriptPath: String { configuration.path("bridgeScript", fallback: Bundle.main.resourceURL?.appendingPathComponent("kosync_calibre_bridge.py").path ?? "\(projectPath)/kosync_calibre_bridge.py") }
    private var username: String { configuration.value("account.username", fallback: "reader") }
    private var dockerPath: String { toolPath("docker", fallback: "docker") }
    private var brewPath: String { toolPath("brew", fallback: "brew") }
    private var adbPath: String { toolPath("adb", fallback: "adb") }
    private var calibreConverter: String { configuration.value("tools.calibreApp", fallback: "/Applications/calibre.app/Contents/MacOS/ebook-convert") }

    private func service(_ key: String, fallback: String) -> String { configuration.value("services.\(key)", fallback: fallback) }
    private func agent(_ key: String, fallback: String) -> String { configuration.value("launchAgents.\(key)", fallback: fallback) }
    private func logFile(_ key: String, fallback: String) -> String {
        let configured = configuration.value("logFiles.\(key)", fallback: "")
        return configured.isEmpty ? "\(logsPath)/\(fallback)" : (configured as NSString).expandingTildeInPath
    }
    private func toolPath(_ key: String, fallback: String) -> String {
        let configured = configuration.value("tools.\(key)", fallback: "")
        if !configured.isEmpty { return configured }
        let found = Self.run("/usr/bin/which", [fallback]).output.trimmingCharacters(in: .whitespacesAndNewlines)
        return found.isEmpty ? fallback : found
    }

    private func keychainCredential(_ key: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: "app.shelf.dashboard",
                                    kSecAttrAccount as String: key,
                                    kSecReturnData as String: true,
                                    kSecMatchLimit as String: kSecMatchLimitOne]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    private func saveKeychainCredential(_ key: String, value: String) -> Bool {
        let identity: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                       kSecAttrService as String: "app.shelf.dashboard",
                                       kSecAttrAccount as String: key]
        let data = Data(value.utf8)
        let update = SecItemUpdate(identity as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return true }
        var add = identity
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
    }

    static func main() {
        let app = NSApplication.shared
        let delegate = DashboardApp()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        // NSApplication's delegate reference is weak. Keep the delegate alive for
        // the entire event loop instead of relying on the optimizer's local lifetime.
        withExtendedLifetime(delegate) {
            app.run()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("Shelf: applicationDidFinishLaunching")
        NSApp.setActivationPolicy(.regular)
        buildMenu()
        let config = WKWebViewConfiguration()
        let controller = WKUserContentController()
        controller.add(WeakScriptMessageHandler(self), name:"dashboard")
        config.userContentController = controller
        webView = DroppableWebView(frame:NSRect(x:0,y:0,width:1440,height:900),configuration:config)
        (webView as? DroppableWebView)?.onEPUBDrop = { [weak self] urls in self?.queueEPUBImports(urls) }
        webView.autoresizingMask=[.width,.height]
        webView.navigationDelegate=self
        window = NSWindow(contentRect:NSRect(x:0,y:0,width:1440,height:940),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title = "Shelf"
        window.appearance = NSAppearance(named:.aqua)
        window.minSize = NSSize(width:1050,height:700)
        window.center()
        window.isReleasedWhenClosed=false
        let container=NSView(frame:NSRect(x:0,y:0,width:1440,height:900))
        container.autoresizingMask=[.width,.height]
        webView.frame=container.bounds
        container.addSubview(webView)
        loadingLabel = NSTextField(labelWithString:"Loading your Calibre and reader services…")
        loadingLabel.font = NSFont.systemFont(ofSize:15,weight:.medium)
        loadingLabel.textColor = .secondaryLabelColor
        loadingLabel.alignment = .center
        loadingLabel.frame = NSRect(x:30,y:container.bounds.midY-20,width:container.bounds.width-60,height:40)
        loadingLabel.autoresizingMask = [.width,.minYMargin,.maxYMargin]
        container.addSubview(loadingLabel)
        window.contentView = container
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps:true)
        if let page = Bundle.main.url(forResource:"index",withExtension:"html") {
            NSLog("Shelf: loading resource %@",page.path)
            webView.loadFileURL(page,allowingReadAccessTo:page.deletingLastPathComponent())
        } else {
            loadingLabel.stringValue="Dashboard files are missing. Reinstall Shelf."
            NSLog("Shelf: index.html missing from app resources")
        }
        refresh()
        refreshTimer = Timer.scheduledTimer(withTimeInterval:60,repeats:true) { [weak self] _ in
            guard let self, self.window.isVisible, !self.window.isMiniaturized else { return }
            self.refresh()
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if webView === readerWebView {
            applyReaderPreferences()
            return
        }
        loadingLabel.isHidden=true
        NSLog("Shelf: dashboard page loaded")
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadingLabel.isHidden=false
        loadingLabel.stringValue="Could not load dashboard: \(error.localizedDescription)"
        NSLog("Shelf: page load failed: %@",error.localizedDescription)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadingLabel.isHidden=false
        loadingLabel.stringValue="Could not load dashboard: \(error.localizedDescription)"
        NSLog("Shelf: page load failed: %@",error.localizedDescription)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "reader", let body=message.body as? [String:Any] {
            switch body["type"] as? String {
            case "progress":
                syncReaderProgress(body)
            case "highlight":
                syncReaderHighlight(body)
            case "chapters":
                DispatchQueue.main.async { self.updateReaderChapters(body["chapters"] as? [[String:Any]] ?? []) }
            case "position":
                DispatchQueue.main.async { self.updateReaderPosition(body) }
            case "highlightError":
                DispatchQueue.main.async { self.notify(body["message"] as? String ?? "Select a passage first, then choose Highlight.") }
            default: break
            }
            return
        }
        guard let body=message.body as? [String:Any], let type=body["type"] as? String else { return }
        switch type {
        case "loadSetup": loadSetup()
        case "saveSetup": if let config=body["config"] as? [String:Any] { saveSetup(config) }
        case "chooseSetupFolder": chooseSetupFolder(body["role"] as? String ?? "library")
        case "refresh": refresh()
        case "checkUpdates": checkUpdates()
        case "checkAll": checkAll()
        case "fixAll": confirmFixAll()
        case "updateCalibre": confirmUpdateCalibre()
        case "updateDashboard": confirmUpdateDashboard()
        case "sendBooxSettings": sendBooxSettings()
        case "openCrossPointSettings": openCrossPointSettings()
        case "openBookPlayer": if let url=NSWorkspace.shared.urlForApplication(withBundleIdentifier:"com.tortugapower.audiobookplayer") { NSWorkspace.shared.open(url) }
        case "loadBooks": loadBooks()
        case "openBook": if let bookId=body["bookId"] as? Int { openBook(bookId) }
        case "chooseEPUBImport": chooseEPUBImports()
        case "saveProgressMatch": if let document=body["document"] as? String, let bookId=body["bookId"] as? Int { saveProgressMatch(document,bookId:bookId) }
        case "loadDiscovery": loadDiscovery(body["period"] as? String ?? "weekly")
        case "loadHardcoverShelf": loadHardcoverShelf()
        case "searchHardcover": searchHardcover(body["query"] as? String ?? "")
        case "openBookLink": if let value=body["url"] as? String { openBookLink(value) }
        case "exportDiagnostics": exportDiagnostics(body["additionalText"] as? String ?? "")
        case "action": if let id=body["id"] as? String { confirmAndRun(id) }
        case "copy": if let text=body["text"] as? String { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text,forType:.string); notify("Copied to clipboard") }
        case "openLog": if let path=body["path"] as? String { NSWorkspace.shared.open(URL(fileURLWithPath:path)) }
        default: break
        }
    }

    private func loadSetup() {
        let services=configuration.dictionary("services")
        let ip=Self.capture(#"inet (\d+\.\d+\.\d+\.\d+)"#,Self.run("/sbin/ifconfig",["en0"]).output) ?? "127.0.0.1"
        let opds=(services["readerOpds"] as? String).flatMap{$0.isEmpty ? nil : $0} ?? "http://\(ip):8080/opds"
        let sync=(services["readerSync"] as? String).flatMap{$0.isEmpty ? nil : $0} ?? "http://\(ip):17200"
        let crosspoint=(services["crosspointApi"] as? String).flatMap{$0.isEmpty ? nil : $0} ?? "http://127.0.0.1:17303"
        send("setupLoaded", [
            "setupCompleted":configuration.bool("setupCompleted"),
            "cloudProvider":configuration.value("cloudProvider",fallback:"icloud"),
            "libraryPath":libraryPath,"importPath":importPath,"username":username,
            "devices":configuration.strings("devices"),
            "connections":configuration.strings("connections"),
            "connectionsConfigured":configuration.bool("connectionsConfigured"),
            "calibreOpds":opds,
            "kosyncUrl":sync,
            "crosspointUrl":crosspoint
        ])
    }

    private func saveSetup(_ form:[String:Any]) {
        let text: (String, String) -> String = { key, fallback in
            let value=(form[key] as? String ?? "").trimmingCharacters(in:.whitespacesAndNewlines)
            return value.isEmpty ? fallback : value
        }
        let sync=text("kosyncUrl","").trimmingCharacters(in:CharacterSet(charactersIn:"/"))
        let crosspoint=text("crosspointUrl","").trimmingCharacters(in:CharacterSet(charactersIn:"/"))
        let provider=CloudFolderProvider(rawValue:text("cloudProvider","icloud")) ?? .iCloud
        let devices=Set((form["devices"] as? [String] ?? []).compactMap(ReaderDevice.init(rawValue:)))
        let connections=Set((form["connections"] as? [String] ?? []).compactMap(ConnectedService.init(rawValue:)))
        let profile=ShelfProfile(cloudProvider:provider,username:text("username","reader"),devices:devices,connections:connections)
        do {
            try configuration.set("account.username",text("username","reader"))
            try configuration.set("cloudProvider",profile.cloudProvider.rawValue)
            try configuration.set("devices",profile.devices.map(\.rawValue).sorted())
            try configuration.set("connections",profile.connections.map(\.rawValue).sorted())
            try configuration.set("connectionsConfigured",true)
            try configuration.set("services.readerOpds",text("calibreOpds",""))
            try configuration.set("services.calibreOpds",text("calibreOpds",service("calibreOpds",fallback:"http://127.0.0.1:8080/opds/")))
            try configuration.set("services.readerSync",sync)
            try configuration.set("services.kosyncHealth",sync.isEmpty ? "" : "\(sync)/healthcheck")
            try configuration.set("services.crosspointApi",crosspoint)
            try configuration.set("services.crosspointHealth",crosspoint.isEmpty ? "" : "\(crosspoint)/healthz")
            if let password=form["calibrePassword"] as? String,!password.isEmpty,!saveKeychainCredential("calibre-server-password",value:password) {
                throw NSError(domain:"ShelfSetup",code:1,userInfo:[NSLocalizedDescriptionKey:"Could not save the Calibre password to Keychain."])
            }
            if let key=form["syncApiKey"] as? String,!key.isEmpty,!saveKeychainCredential("sync-api-key",value:key) {
                throw NSError(domain:"ShelfSetup",code:2,userInfo:[NSLocalizedDescriptionKey:"Could not save the sync API key to Keychain."])
            }
            try configuration.set("setupCompleted",true)
            send("setupSaved",["ok":true])
            refresh()
        } catch {
            send("setupSaved",["ok":false,"message":error.localizedDescription])
        }
    }

    private func chooseSetupFolder(_ role:String) {
        guard role == "library" || role == "import" else { return }
        let panel=NSOpenPanel()
        panel.canChooseFiles=false; panel.canChooseDirectories=true; panel.allowsMultipleSelection=false
        panel.title=role == "library" ? "Choose your Calibre library" : "Choose your EPUB import folder"
        panel.message=role == "library" ? "Choose the folder that contains Calibre's metadata.db. A single Calibre library database should have one active writer." : "Choose a local folder or a folder kept in sync by iCloud Drive, OneDrive, or Google Drive."
        let start=URL(fileURLWithPath:role == "library" ? libraryPath : importPath,isDirectory:true)
        if FileManager.default.fileExists(atPath:start.path) { panel.directoryURL=start }
        panel.beginSheetModal(for:window) { [weak self] response in
            guard response == .OK,let self,let url=panel.url else { return }
            if role == "library" && !FileManager.default.fileExists(atPath:url.appendingPathComponent("metadata.db").path) {
                self.notify("That folder does not contain a Calibre metadata.db file."); return
            }
            do {
                let bookmark:Data
                do { bookmark=try url.bookmarkData(options:[.withSecurityScope],includingResourceValuesForKeys:nil,relativeTo:nil) }
                catch { bookmark=try url.bookmarkData(options:[],includingResourceValuesForKeys:nil,relativeTo:nil) }
                try self.configuration.set("bookmarks.\(role)",bookmark.base64EncodedString())
                try self.configuration.set("paths.\(role == "library" ? "library" : "import")",url.path)
                self.loadSetup(); self.refresh()
                self.notify(role == "library" ? "Calibre library folder saved." : "Import folder saved.")
            } catch { self.notify("Could not save folder access: \(error.localizedDescription)") }
        }
    }

    private func buildMenu() {
        let menu=NSMenu()
        let app=NSMenuItem(); menu.addItem(app)
        let appMenu=NSMenu(); app.submenu=appMenu
        appMenu.addItem(withTitle:"About Shelf",action:#selector(NSApplication.orderFrontStandardAboutPanel(_:)),keyEquivalent:"")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle:"Quit Dashboard",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        let view=NSMenuItem(); view.title="Dashboard"; menu.addItem(view)
        let viewMenu=NSMenu(); view.submenu=viewMenu
        let refreshItem=NSMenuItem(title:"Refresh status",action:#selector(menuRefresh),keyEquivalent:"r"); refreshItem.target=self; viewMenu.addItem(refreshItem)
        let updateItem=NSMenuItem(title:"Check for updates",action:#selector(menuUpdate),keyEquivalent:"u"); updateItem.target=self; updateItem.keyEquivalentModifierMask=[.command,.shift]; viewMenu.addItem(updateItem)
        NSApp.mainMenu=menu
    }

    @objc private func menuRefresh() { refresh() }
    @objc private func menuUpdate() { checkUpdates() }

    private func refresh() {
        guard !refreshInProgress else { return }
        refreshInProgress = true
        DispatchQueue.global(qos:.utility).async { [weak self] in
            guard let self else { return }
            let payload=self.readDashboard()
            DispatchQueue.main.async {
                self.refreshInProgress = false
                self.send("updateDashboard",payload)
            }
        }
    }

    private func loadBooks() {
        let script=Bundle.main.resourceURL?.appendingPathComponent("bookshelf.py").path ?? "\(home)/Shelf/bookshelf.py"
        DispatchQueue.global(qos:.utility).async { [weak self] in
            guard let self else { return }
            let result=Self.run("/usr/bin/python3",[script])
            guard result.code == 0,
                  let bytes=result.output.data(using:.utf8),
                  var payload=try? JSONSerialization.jsonObject(with:bytes) as? [String:Any] else {
                DispatchQueue.main.async { self.send("bookshelfError",["message":"Could not read the local Calibre library: \(result.output.trimmingCharacters(in:.whitespacesAndNewlines).suffix(240))"]) }
                return
            }
            let reading=(payload["reading"] as? [[String:Any]] ?? []).map { self.withCover($0) }
            let recent=(payload["recent"] as? [[String:Any]] ?? []).map { self.withCover($0) }
            let allBooks=(payload["allBooks"] as? [[String:Any]] ?? []).map { self.withCover($0) }
            payload["reading"]=reading
            payload["recent"]=recent
            payload["allBooks"]=allBooks
            DispatchQueue.main.async { self.send("bookshelfData",payload) }
        }
    }

    private func saveProgressMatch(_ document:String,bookId:Int) {
        guard document.range(of:#"^[0-9a-fA-F]{32}$"#,options:.regularExpression) != nil, bookId > 0 else {
            notify("Could not link this progress record."); return
        }
        let db="\(libraryPath)/metadata.db"
        let exists=Self.run("/usr/bin/sqlite3",["-readonly",db,"SELECT count(*) FROM books WHERE id=\(bookId);"]).output.trimmingCharacters(in:.whitespacesAndNewlines)
        guard exists == "1" else { notify("That book is no longer in the Calibre library."); return }
        let aliasesURL=URL(fileURLWithPath:"\(statePath)/kosync-calibre-aliases.json")
        var aliases=(try? JSONSerialization.jsonObject(with:Data(contentsOf:aliasesURL))) as? [String:[String:Any]] ?? [:]
        aliases[document.lowercased()]=["book_id":bookId,"reason":"Matched in dashboard"]
        guard let data=try? JSONSerialization.data(withJSONObject:aliases,options:[.prettyPrinted,.sortedKeys]) else {
            notify("Could not save the progress match."); return
        }
        do {
            try FileManager.default.createDirectory(at:aliasesURL.deletingLastPathComponent(),withIntermediateDirectories:true)
            try data.write(to:aliasesURL,options:.atomic)
            try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:aliasesURL.path)
        } catch { notify("Could not save the progress match: \(error.localizedDescription)"); return }
        let bridgeScript=bridgeScriptPath
        DispatchQueue.global(qos:.utility).async { [weak self] in
            let result=Self.run("/usr/bin/python3",[bridgeScript])
            DispatchQueue.main.async {
                guard let self else { return }
                if result.code == 0 {
                    self.notify("Progress linked to Calibre. Refreshing your cover shelf…")
                    self.loadBooks()
                } else {
                    self.notify("The link was saved, but the bridge could not finish: \(result.output.trimmingCharacters(in:.whitespacesAndNewlines).suffix(180))")
                }
            }
        }
    }

    private func openBook(_ bookId:Int) {
        guard bookId > 0 else { return }
        notify("Preparing your book…")
        let script=Bundle.main.resourceURL?.appendingPathComponent("reader_book.py").path ?? "\(home)/Shelf/reader_book.py"
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            guard let self else { return }
            let result=Self.run("/usr/bin/python3",[script,String(bookId)])
            guard result.code == 0, let bytes=result.output.data(using:.utf8),
                  let payload=try? JSONSerialization.jsonObject(with:bytes) as? [String:Any],
                  let document=payload["document"] as? String,
                  let htmlPath=payload["htmlPath"] as? String,
                  let workDir=payload["workDir"] as? String else {
                let message=(try? JSONSerialization.jsonObject(with:Data(result.output.utf8)) as? [String:Any])?["error"] as? String ?? "Could not prepare this Calibre book."
                DispatchQueue.main.async { self.notify(message) }
                return
            }
            var reader=payload
            let documents=payload["syncDocuments"] as? [String] ?? [document]
            reader["resumePercentage"]=0
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.showReader(reader,htmlURL:URL(fileURLWithPath:htmlPath),workDirectory:URL(fileURLWithPath:workDir,isDirectory:true))
                DispatchQueue.global(qos:.utility).async { [weak self] in
                    guard let self,let saved=self.fetchReaderProgress(documents) else { return }
                    DispatchQueue.main.async {
                        guard let active=self.activeReader,(active["bookId"] as? Int)==bookId else { return }
                        self.readerWebView?.evaluateJavaScript("window.readerSetResume && window.readerSetResume(\(saved));",completionHandler:nil)
                    }
                }
            }
        }
    }

    private func syncAuthKey() -> String {
        if let saved=keychainCredential("sync-api-key"),!saved.isEmpty { return saved }
        return Self.run(dockerPath,["exec","kosync","redis-cli","--raw","-n","1","GET","user:\(username):key"]).output.trimmingCharacters(in:.whitespacesAndNewlines)
    }

    private func serverPassword() -> String {
        let file=(try? String(contentsOfFile:"\(statePath)/calibre-server-password",encoding:.utf8))?.trimmingCharacters(in:.newlines) ?? ""
        return file.isEmpty ? (keychainCredential("calibre-server-password") ?? "") : file
    }

    private func fetchReaderProgress(_ documents:[String]) -> Double? {
        let key=syncAuthKey()
        guard !key.isEmpty else { return nil }
        let group=DispatchGroup(),lock=NSLock(); var saved=[(Double,Double)]()
        let docs=Set(documents.filter{$0.range(of:#"^[0-9a-fA-F]{32}$"#,options:.regularExpression) != nil})
        for document in docs {
            guard let safe=document.addingPercentEncoding(withAllowedCharacters:.alphanumerics) else { continue }
            for root in [service("kosyncHealth",fallback:"http://127.0.0.1:17200/healthcheck").replacingOccurrences(of:"/healthcheck",with:""),service("crosspointApi",fallback:"http://127.0.0.1:17303")] {
                guard let url=URL(string:"\(root)/syncs/progress/\(safe)") else { continue }
                var request=URLRequest(url:url,timeoutInterval:8)
                request.setValue(username,forHTTPHeaderField:"x-auth-user"); request.setValue(key,forHTTPHeaderField:"x-auth-key")
                request.setValue("application/vnd.koreader.v1+json",forHTTPHeaderField:"Accept")
                group.enter()
                URLSession.shared.dataTask(with:request) { data,response,_ in
                    if (response as? HTTPURLResponse)?.statusCode == 200,
                       let data,let result=try? JSONSerialization.jsonObject(with:data) as? [String:Any],
                       let number=result["percentage"] as? NSNumber {
                        let timestamp=(result["timestamp"] as? NSNumber)?.doubleValue ?? 0
                        lock.lock(); saved.append((timestamp,max(0,min(1,number.doubleValue)))); lock.unlock()
                    }
                    group.leave()
                }.resume()
            }
        }
        _=group.wait(timeout:.now()+18); lock.lock(); defer { lock.unlock() }
        return saved.max(by:{$0.0 < $1.0})?.1
    }

    private func showReader(_ payload:[String:Any],htmlURL:URL,workDirectory:URL) {
        guard let title=payload["title"] as? String else { return }
        let previous=readerTempDirectory
        let previousIsPersistentCache=readerWorkIsPersistentCache
        let content=WKUserContentController()
        content.add(WeakScriptMessageHandler(self),name:"reader")
        let config=WKWebViewConfiguration(); config.userContentController=content
        let readerData:[String:Any]=[
            "bookId":payload["bookId"] ?? 0,
            "document":payload["document"] ?? "",
            "syncDocuments":payload["syncDocuments"] ?? [payload["document"] ?? ""],
            "title":title,
            "authors":payload["authors"] ?? "",
            "filename":payload["filename"] ?? "",
            "language":payload["language"] ?? "",
            "resumePercentage":payload["resumePercentage"] ?? 0
        ]
        let language=(payload["language"] as? String ?? "").lowercased()
        let hasJapanese=title.unicodeScalars.contains { (0x3040...0x30ff).contains(Int($0.value)) || (0x3400...0x9fff).contains(Int($0.value)) }
        let japanese=language.hasPrefix("ja") || language.hasPrefix("jpn") || hasJapanese
        readerIsJapanese=japanese
        readerFontSize=UserDefaults.standard.object(forKey:"readerFontSize") == nil ? 19 : UserDefaults.standard.double(forKey:"readerFontSize")
        readerFontSize=min(32,max(12,readerFontSize))
        let fontKey=japanese ? "readerFontFamily.ja" : "readerFontFamily.en"
        let savedFont=UserDefaults.standard.string(forKey:fontKey) ?? (japanese ? "serif" : "sans")
        let font=["serif","sans","system"].contains(savedFont) ? savedFont : (japanese ? "serif" : "sans")
        readerFontChoice=font
        let savedTheme=UserDefaults.standard.string(forKey:"readerTheme") ?? "paper"
        let theme=["light","paper","night"].contains(savedTheme) ? savedTheme : "paper"
        let savedSpacing=UserDefaults.standard.string(forKey:"readerSpacing") ?? "normal"
        let spacing=["compact","normal","relaxed"].contains(savedSpacing) ? savedSpacing : "normal"
        if let json=try? JSONSerialization.data(withJSONObject:readerData,options:[.fragmentsAllowed,.sortedKeys]),
           let source=String(data:json,encoding:.utf8) {
            let bootstrap="""
            (function(){
              window.readerBook=\(source);
              const style=document.createElement('style');
              style.textContent='html,body{height:100%!important;overflow:hidden!important;background:var(--reader-paper)!important}body{margin:0!important;padding:0!important;max-width:none!important;font-family:var(--reader-font)!important;font-size:var(--reader-size)!important;line-height:var(--reader-leading)!important;color:var(--reader-ink)!important;transition:background-color .18s,color .18s}#reader-viewport{position:fixed;inset:0;overflow-x:auto;overflow-y:hidden;scroll-behavior:smooth;scroll-snap-type:x mandatory;scrollbar-width:none;background:var(--reader-paper)}#reader-viewport::-webkit-scrollbar{display:none}#reader-flow{box-sizing:border-box!important;width:100vw!important;max-width:none!important;height:100%!important;padding:88px 280px 104px;column-width:790px!important;column-gap:560px!important;column-fill:auto!important;orphans:2;widows:2;transition:font-size .18s;overflow:visible}#reader-flow>div,#reader-flow>section{break-inside:auto!important;max-width:none!important}#reader-flow p{margin:0 0 1.15em!important}#reader-flow h1,#reader-flow h2,#reader-flow h3,#reader-flow h4{line-height:1.4!important;margin:1.4em 0 .7em!important;break-after:avoid;scroll-margin-top:18px}#reader-flow img{max-width:min(56vw,560px)!important;max-height:48vh!important;width:auto!important;height:auto!important;object-fit:contain;break-inside:avoid;display:block;margin-inline:auto}#reader-flow svg{width:min(56vw,560px)!important;height:auto!important;max-height:48vh!important;break-inside:avoid;display:block;margin-inline:auto}#reader-flow blockquote{margin-inline-start:1.4em!important}#reader-flow pre{white-space:pre-wrap!important}#reader-flow table{max-width:100%;font-size:.9em}#reader-flow mark.reader-highlight{background:#ffe08a!important;color:inherit!important;border-radius:2px}';document.head.appendChild(style);
              let lastSent=-1,lastCandidate=0,lastChapter=-1,lastPositionSent=0,lastProgressAttempt=0,progressSyncPending=false,allowProgressSync=false,userHasNavigated=false,pageCount=1,currentPage=0,readerViewport=null,readerFlow=null;
              window.readerApplyPreferences=function(p){const japanese=(String(window.readerBook.language||'').toLowerCase().startsWith('ja')||/[\\u3040-\\u30ff\\u3400-\\u9fff]/.test(window.readerBook.title||''));const fonts={serif:japanese?'"Noto Serif CJK JP","Hiragino Mincho ProN",serif':'"Noto Serif","Charter",Georgia,serif',sans:japanese?'"Noto Sans CJK JP","Hiragino Sans",sans-serif':'"Noto Sans",-apple-system,BlinkMacSystemFont,sans-serif',system:'-apple-system,BlinkMacSystemFont,system-ui,sans-serif'};const themes={light:['#ffffff','#222222'],paper:['#f6f3eb','#302c24'],night:['#17191b','#e7e4dd']};const palette=themes[p.theme]||themes.paper;const leading={compact:'1.55',normal:'1.72',relaxed:'1.9'};const root=document.documentElement;root.style.setProperty('--reader-font',fonts[p.font]||fonts.sans);root.style.setProperty('--reader-size',(Number(p.size)||19)+'px');root.style.setProperty('--reader-leading',leading[p.spacing]||leading.normal);root.style.setProperty('--reader-paper',palette[0]);root.style.setProperty('--reader-ink',palette[1]);if(readerFlow)readerFlow.style.fontFamily=fonts[p.font]||fonts.sans;if(readerFlow)readerFlow.style.fontSize=(Number(p.size)||19)+'px';setTimeout(()=>{if(readerViewport){layoutPages();setPage(currentPage,false)}},80)};
              let titleKey=(window.readerBook.title||'').trim().toLocaleLowerCase();
              const chapterEntries=[],seenChapterTargets=new Set();
              const tocLinks=Array.from(document.querySelectorAll('.p-toc a, #toc a, [role="doc-toc"] a')).concat(Array.from(document.querySelectorAll('nav')).filter(n=>/(^|\\s)toc(\\s|$)/i.test(n.getAttribute('epub:type')||n.getAttributeNS('http://www.idpf.org/2007/ops','type')||'')).flatMap(n=>Array.from(n.querySelectorAll('a'))));
              for(const a of tocLinks){try{const url=new URL(a.getAttribute('href')||'',document.baseURI),id=decodeURIComponent(url.hash.slice(1)),target=id?document.getElementById(id):null;if(target&&!seenChapterTargets.has(target)){seenChapterTargets.add(target);chapterEntries.push({element:target,title:(a.innerText||a.textContent||target.innerText||target.textContent||'').trim().replace(/\\s+/g,' ').slice(0,100)})}}catch(_){}}
              if(!chapterEntries.length){for(const h of Array.from(document.querySelectorAll('h1,h2,h3,h4'))){const t=(h.innerText||h.textContent||'').trim();if(t&&t.toLocaleLowerCase()!==titleKey&&!/^(contents|table of contents|copyright|title page)$/i.test(t)){chapterEntries.push({element:h,title:t.replace(/\\s+/g,' ').slice(0,100)})}}}
              if(!chapterEntries.length)chapterEntries.push({element:document.body,title:window.readerBook.title||'Book'});
              const headings=chapterEntries.map(entry=>entry.element);headings.forEach((h,i)=>{if(!h.id)h.id='reader-section-'+i});
              window.readerChapters=chapterEntries.map((entry,i)=>({title:entry.title||('Section '+(i+1)),id:entry.element.id}));
              function step(){return readerViewport?readerViewport.clientWidth:window.innerWidth}
              function layoutPages(){if(!readerViewport||!readerFlow)return;const width=step(),column=Math.max(280,Math.min(790,width-108)),margin=Math.max(54,(width-column)/2),gap=Math.max(0,width-column);readerFlow.style.width=width+'px';readerFlow.style.paddingLeft=margin+'px';readerFlow.style.paddingRight=margin+'px';readerFlow.style.columnWidth=column+'px';readerFlow.style.columnGap=gap+'px';const extent=Math.max(width,readerFlow.scrollWidth);pageCount=Math.max(1,Math.ceil((extent-1)/width));currentPage=Math.max(0,Math.min(pageCount-1,currentPage));}
              function chapterIndex(){let result=0,scroll=readerViewport?readerViewport.scrollLeft:0,best=-Infinity;for(let n=0;n<headings.length;n++){const x=headings[n].getBoundingClientRect().left+scroll;if(x<=scroll+step()*.42&&x>best){best=x;result=n}}return result;}
              function percentage(){return pageCount<=1?0:currentPage/(pageCount-1)}
              function sendPosition(){if(!readerViewport)return;layoutPages();const c=chapterIndex();lastCandidate=percentage();window.webkit.messageHandlers.reader.postMessage({type:'position',percentage:lastCandidate,chapter:c,chapterTitle:window.readerChapters[c]?.title||'',page:currentPage+1,pages:pageCount})}
              function setPage(page,userAction){if(!readerViewport)return;layoutPages();currentPage=Math.max(0,Math.min(pageCount-1,Math.round(page)));if(userAction){allowProgressSync=true;userHasNavigated=true}readerViewport.scrollTo({left:currentPage*step(),behavior:'smooth'});window.setTimeout(sendPosition,240);if(userAction)window.setTimeout(window.syncReaderProgress,320)}
              window.readerSetResume=function(value){const p=Math.max(0,Math.min(1,Number(value)||0));window.readerBook.resumePercentage=p;if(userHasNavigated)return;lastSent=p;lastCandidate=p;if(!readerViewport)return;layoutPages();currentPage=Math.round((pageCount-1)*p);readerViewport.scrollLeft=currentPage*step();sendPosition()};
              window.readerPage=function(offset){setPage(currentPage+Number(offset||0),true)};
              window.readerGoTo=function(index){const h=headings[Math.max(0,Math.min(headings.length-1,Number(index)||0))];if(h){const x=h.getBoundingClientRect().left+readerViewport.scrollLeft;setPage(Math.round(x/step()),true)}};
              window.readerScrollTo=function(p){setPage(Math.round((pageCount-1)*Math.max(0,Math.min(1,Number(p)||0))),true)};
              window.captureReaderHighlight=function(){const selection=window.getSelection(),text=(selection?.toString()||'').trim();if(!text){window.webkit.messageHandlers.reader.postMessage({type:'highlightError',message:'Select a passage first, then choose Highlight.'});return}if(text.length>4096){window.webkit.messageHandlers.reader.postMessage({type:'highlightError',message:'That passage is too long to save as one highlight.'});return}const c=chapterIndex();window.webkit.messageHandlers.reader.postMessage({type:'highlight',text:text,chapter:window.readerChapters[c]?.title||'',page:currentPage+1,percentage:percentage()})};
              function setupPages(){readerViewport=document.createElement('main');readerViewport.id='reader-viewport';readerFlow=document.createElement('article');readerFlow.id='reader-flow';while(document.body.firstChild)readerFlow.appendChild(document.body.firstChild);readerViewport.appendChild(readerFlow);document.body.appendChild(readerViewport);const userRead=()=>{allowProgressSync=true};let touchStart=null,wheelTravel=0,lastWheelPage=0;readerViewport.addEventListener('pointerdown',userRead,{passive:true});readerViewport.addEventListener('touchstart',e=>{userRead();const t=e.changedTouches[0];touchStart={x:t.clientX,y:t.clientY,moved:false}},{passive:true});readerViewport.addEventListener('touchmove',e=>{if(!touchStart)return;const t=e.changedTouches[0],dx=t.clientX-touchStart.x,dy=t.clientY-touchStart.y;if(Math.abs(dx)>16&&Math.abs(dx)>Math.abs(dy)*1.2){touchStart.moved=true;e.preventDefault()}},{passive:false});readerViewport.addEventListener('touchend',e=>{if(!touchStart)return;const t=e.changedTouches[0],dx=t.clientX-touchStart.x,dy=t.clientY-touchStart.y,moved=touchStart.moved;touchStart=null;if(moved&&Math.abs(dx)>54&&Math.abs(dx)>Math.abs(dy)*1.35)window.readerPage(dx<0?1:-1)},{passive:true});readerViewport.addEventListener('wheel',e=>{userRead();if(Math.abs(e.deltaX)>Math.abs(e.deltaY)*1.35){e.preventDefault();wheelTravel+=e.deltaX;if(Math.abs(wheelTravel)>=72&&Date.now()-lastWheelPage>620){window.readerPage(wheelTravel>0?1:-1);wheelTravel=0;lastWheelPage=Date.now()}}else{wheelTravel=0}},{passive:false});readerViewport.addEventListener('scroll',()=>{currentPage=Math.max(0,Math.min(pageCount-1,Math.round(readerViewport.scrollLeft/step())));if(Date.now()-lastPositionSent>160){lastPositionSent=Date.now();sendPosition()}if(allowProgressSync)window.syncReaderProgress()},{passive:true});window.addEventListener('resize',()=>{const p=percentage();layoutPages();setPage(Math.round(p*(pageCount-1)),false)});}
              window.readerAckProgress=function(p){lastSent=Number(p);progressSyncPending=false;if(Math.abs(percentage()-lastSent)>=0.004)setTimeout(window.syncReaderProgress,350)};
              window.readerFailProgress=function(){progressSyncPending=false};
              window.syncReaderProgress=function(){if(!allowProgressSync||progressSyncPending)return;lastCandidate=percentage();if(lastSent>=0&&Math.abs(lastCandidate-lastSent)<0.004)return;if(Date.now()-lastProgressAttempt<1500)return;lastProgressAttempt=Date.now();progressSyncPending=true;window.webkit.messageHandlers.reader.postMessage({type:'progress',bookId:window.readerBook.bookId,document:window.readerBook.document,syncDocuments:window.readerBook.syncDocuments,percentage:lastCandidate,progress:lastCandidate.toFixed(6),metadata:{title:window.readerBook.title,authors:window.readerBook.authors,filename:window.readerBook.filename,language:window.readerBook.language}})};
              function resume(){const p=Number(window.readerBook.resumePercentage||0);layoutPages();currentPage=Math.round((pageCount-1)*p);readerViewport.scrollLeft=currentPage*step();lastSent=p;lastCandidate=p;sendPosition();window.webkit.messageHandlers.reader.postMessage({type:'chapters',chapters:window.readerChapters})}
              window.addEventListener('load',()=>{setupPages();window.readerApplyPreferences({font:'\(font)',theme:'\(theme)',spacing:'\(spacing)',size:\(readerFontSize)});setTimeout(resume,140)});
              window.addEventListener('keydown',e=>{if(['ArrowRight','PageDown',' '].includes(e.key)){e.preventDefault();window.readerPage(1)}else if(['ArrowLeft','PageUp'].includes(e.key)){e.preventDefault();window.readerPage(-1)}else if(e.key==='Home'){e.preventDefault();setPage(0,true)}else if(e.key==='End'){e.preventDefault();setPage(pageCount-1,true)}});
              window.addEventListener('pagehide',window.syncReaderProgress);window.addEventListener('beforeunload',window.syncReaderProgress);setInterval(window.syncReaderProgress,15000);
            })();
            """
            config.userContentController.addUserScript(WKUserScript(source:bootstrap,injectionTime:.atDocumentEnd,forMainFrameOnly:true))
        }
        let web=DroppableWebView(frame:.zero,configuration:config)
        web.onEPUBDrop = { [weak self] urls in self?.queueEPUBImports(urls) }
        web.navigationDelegate=self
        let container=NSView(frame:.zero)
        let toolbar=makeReaderToolbar()
        container.addSubview(web); container.addSubview(toolbar)
        for view in [toolbar,web] { view.translatesAutoresizingMaskIntoConstraints=false }
        NSLayoutConstraint.activate([
            web.topAnchor.constraint(equalTo:container.topAnchor),web.leadingAnchor.constraint(equalTo:container.leadingAnchor),web.trailingAnchor.constraint(equalTo:container.trailingAnchor),web.bottomAnchor.constraint(equalTo:container.bottomAnchor),
            toolbar.topAnchor.constraint(equalTo:container.topAnchor,constant:14),toolbar.leadingAnchor.constraint(equalTo:container.leadingAnchor,constant:18),toolbar.trailingAnchor.constraint(equalTo:container.trailingAnchor,constant:-18),toolbar.bottomAnchor.constraint(equalTo:container.bottomAnchor,constant:-14)
        ])
        if dashboardContentView == nil { dashboardContentView=window.contentView }
        readerContentView=container; readerWebView=web; activeReader=readerData; readerTempDirectory=workDirectory
        readerWorkIsPersistentCache=payload["persistentCache"] as? Bool ?? false
        readerChapters=[]
        readerProgressSlider?.doubleValue=(payload["resumePercentage"] as? Double) ?? 0
        readerProgressLabel?.stringValue="\(Int((((payload["resumePercentage"] as? Double) ?? 0)*100).rounded()))%"
        web.loadFileURL(htmlURL,allowingReadAccessTo:workDirectory)
        window.contentView=container; window.title="\(title) · Shelf"; window.minSize=NSSize(width:900,height:700)
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
        if let previous,previous != workDirectory,!previousIsPersistentCache { DispatchQueue.main.asyncAfter(deadline:.now()+2) { try? FileManager.default.removeItem(at:previous) } }
    }

    private func makeReaderToolbar()->NSView {
        let toolbar=ReaderOverlayView(frame:.zero)
        let back=NSButton(image:NSImage(systemSymbolName:"chevron.left",accessibilityDescription:"Back to library")!,target:self,action:#selector(closeReader))
        back.isBordered=false; back.toolTip="Back to library"; back.setContentHuggingPriority(.required,for:.horizontal); back.imagePosition = .imageOnly
        back.widthAnchor.constraint(equalToConstant:32).isActive=true; back.heightAnchor.constraint(equalToConstant:32).isActive=true
        let chapter=NSPopUpButton(frame:.zero,pullsDown:false); chapter.addItem(withTitle:"Contents"); chapter.target=self; chapter.action=#selector(readerSelectChapter(_:)); chapter.cell?.lineBreakMode = .byTruncatingTail; chapter.widthAnchor.constraint(equalToConstant:160).isActive=true; chapter.controlSize = .small; readerChapterMenu=chapter
        let top=NSStackView(views:[back]); top.orientation = .horizontal; top.alignment = .centerY; top.distribution = .fill; top.translatesAutoresizingMaskIntoConstraints=false

        let previous=NSButton(image:NSImage(systemSymbolName:"chevron.left",accessibilityDescription:"Previous page")!,target:self,action:#selector(readerPreviousPage))
        let next=NSButton(image:NSImage(systemSymbolName:"chevron.right",accessibilityDescription:"Next page")!,target:self,action:#selector(readerNextPage))
        [previous,next].forEach { $0.isBordered=false; $0.controlSize = .regular; $0.wantsLayer=true; $0.layer?.cornerRadius=12 }
        let slider=NSSlider(value:0,minValue:0,maxValue:1,target:self,action:#selector(readerProgressChanged(_:))); slider.isContinuous=false; slider.setContentHuggingPriority(.defaultLow,for:.horizontal); readerProgressSlider=slider
        let pages=NSTextField(labelWithString:"1 / 1"); pages.alignment = .center; pages.textColor = .secondaryLabelColor; pages.font = .monospacedDigitSystemFont(ofSize:11,weight:.regular); pages.widthAnchor.constraint(equalToConstant:62).isActive=true; readerPageLabel=pages
        let progress=NSTextField(labelWithString:"0%"); progress.alignment = .right; progress.textColor = .secondaryLabelColor; progress.font = .monospacedDigitSystemFont(ofSize:11,weight:.regular); progress.widthAnchor.constraint(equalToConstant:38).isActive=true; readerProgressLabel=progress
        let highlight=NSButton(title:"Highlight",image:NSImage(systemSymbolName:"highlighter",accessibilityDescription:"Highlight selection")!,target:self,action:#selector(readerHighlight)); highlight.bezelStyle = .rounded; highlight.controlSize = .regular; highlight.imagePosition = .imageLeading; highlight.toolTip="Save the selected passage"; readerHighlightButton=highlight
        let appearance=NSButton(title:"Text",image:NSImage(systemSymbolName:"textformat.size",accessibilityDescription:"Reading appearance")!,target:self,action:#selector(showReaderAppearance(_:))); appearance.bezelStyle = .rounded; appearance.controlSize = .regular; appearance.imagePosition = .imageLeading; appearance.toolTip="Reading appearance"
        let bottom=NSStackView(views:[previous,slider,pages,next,chapter,highlight,appearance]); bottom.orientation = .horizontal; bottom.alignment = .centerY; bottom.distribution = .fill; bottom.spacing=11; bottom.translatesAutoresizingMaskIntoConstraints=false
        bottom.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        let dock=NSVisualEffectView(frame:.zero); dock.translatesAutoresizingMaskIntoConstraints=false; dock.material = .hudWindow; dock.blendingMode = .withinWindow; dock.state = .active
        dock.wantsLayer=true; dock.layer?.cornerRadius=20; dock.layer?.masksToBounds=true; dock.layer?.borderWidth=1; dock.layer?.borderColor=NSColor.separatorColor.withAlphaComponent(0.28).cgColor
        dock.addSubview(bottom)
        let titleCapsule=NSVisualEffectView(frame:.zero); titleCapsule.translatesAutoresizingMaskIntoConstraints=false; titleCapsule.material = .hudWindow; titleCapsule.blendingMode = .withinWindow; titleCapsule.state = .active
        titleCapsule.wantsLayer=true; titleCapsule.layer?.cornerRadius=17; titleCapsule.layer?.masksToBounds=true; titleCapsule.layer?.borderWidth=1; titleCapsule.layer?.borderColor=NSColor.separatorColor.withAlphaComponent(0.28).cgColor
        toolbar.addSubview(titleCapsule); toolbar.addSubview(dock); titleCapsule.addSubview(top)
        NSLayoutConstraint.activate([
            titleCapsule.topAnchor.constraint(equalTo:toolbar.topAnchor,constant:4),titleCapsule.leadingAnchor.constraint(equalTo:toolbar.leadingAnchor,constant:8),titleCapsule.widthAnchor.constraint(equalToConstant:42),titleCapsule.heightAnchor.constraint(equalToConstant:42),
            top.leadingAnchor.constraint(equalTo:titleCapsule.leadingAnchor,constant:5),top.trailingAnchor.constraint(equalTo:titleCapsule.trailingAnchor,constant:-5),top.centerYAnchor.constraint(equalTo:titleCapsule.centerYAnchor),top.heightAnchor.constraint(equalToConstant:32),
            dock.centerXAnchor.constraint(equalTo:toolbar.centerXAnchor),dock.bottomAnchor.constraint(equalTo:toolbar.bottomAnchor,constant:-22),dock.widthAnchor.constraint(lessThanOrEqualToConstant:900),dock.leadingAnchor.constraint(greaterThanOrEqualTo:toolbar.leadingAnchor),dock.trailingAnchor.constraint(lessThanOrEqualTo:toolbar.trailingAnchor),dock.heightAnchor.constraint(equalToConstant:58),
            bottom.leadingAnchor.constraint(equalTo:dock.leadingAnchor,constant:13),bottom.trailingAnchor.constraint(equalTo:dock.trailingAnchor,constant:-13),bottom.centerYAnchor.constraint(equalTo:dock.centerYAnchor),bottom.heightAnchor.constraint(equalToConstant:38),
            dock.bottomAnchor.constraint(greaterThanOrEqualTo:toolbar.bottomAnchor,constant:-80)
        ])
        return toolbar
    }

    @objc private func showReaderAppearance(_ sender:NSButton) {
        if let shown=readerSettingsPopover,shown.isShown { shown.performClose(sender); return }
        let font=NSPopUpButton(frame:.zero,pullsDown:false); font.addItems(withTitles:["Noto Sans","Noto Serif","System"]); font.target=self; font.action=#selector(readerSelectFont(_:)); font.selectItem(at:["sans","serif","system"].firstIndex(of:readerFontChoice) ?? 0); font.widthAnchor.constraint(equalToConstant:156).isActive=true; font.controlSize = .small; readerFontMenu=font
        let theme=NSPopUpButton(frame:.zero,pullsDown:false); theme.addItems(withTitles:["Light","Paper","Night"]); theme.target=self; theme.action=#selector(readerSelectTheme(_:)); theme.selectItem(at:["light","paper","night"].firstIndex(of:UserDefaults.standard.string(forKey:"readerTheme") ?? "paper") ?? 1); theme.widthAnchor.constraint(equalToConstant:156).isActive=true; theme.controlSize = .small; readerThemeMenu=theme
        let spacing=NSPopUpButton(frame:.zero,pullsDown:false); spacing.addItems(withTitles:["Compact","Normal","Relaxed"]); spacing.target=self; spacing.action=#selector(readerSelectSpacing(_:)); spacing.selectItem(at:["compact","normal","relaxed"].firstIndex(of:UserDefaults.standard.string(forKey:"readerSpacing") ?? "normal") ?? 1); spacing.widthAnchor.constraint(equalToConstant:156).isActive=true; spacing.controlSize = .small; readerSpacingMenu=spacing
        let size=NSTextField(labelWithString:"\(Int(readerFontSize)) pt"); size.alignment = .center; size.widthAnchor.constraint(equalToConstant:46).isActive=true; readerSizeLabel=size
        let minus=NSButton(title:"−",target:self,action:#selector(readerDecreaseText)); minus.bezelStyle = .rounded; minus.controlSize = .small
        let plus=NSButton(title:"+",target:self,action:#selector(readerIncreaseText)); plus.bezelStyle = .rounded; plus.controlSize = .small
        let sizeControls=NSStackView(views:[minus,size,plus]); sizeControls.orientation = .horizontal; sizeControls.alignment = .centerY; sizeControls.spacing=6
        func row(_ title:String,_ symbol:String,_ control:NSView)->NSStackView {
            let icon=NSImageView(image:NSImage(systemSymbolName:symbol,accessibilityDescription:title) ?? NSImage()); icon.contentTintColor = .secondaryLabelColor; icon.imageScaling = .scaleProportionallyDown; icon.widthAnchor.constraint(equalToConstant:15).isActive=true
            let label=NSTextField(labelWithString:title); label.font = .systemFont(ofSize:11); label.textColor = .secondaryLabelColor; label.widthAnchor.constraint(equalToConstant:78).isActive=true
            let result=NSStackView(views:[icon,label,control]); result.orientation = .horizontal; result.alignment = .centerY; result.spacing=7; return result
        }
        let heading=NSTextField(labelWithString:"Reading appearance"); heading.font = .systemFont(ofSize:13,weight:.semibold)
        let stack=NSStackView(views:[heading,row("Typeface","textformat",font),row("Text size","textformat.size",sizeControls),row("Line spacing","text.alignleft",spacing),row("Page color","circle.lefthalf.filled",theme)])
        stack.orientation = .vertical; stack.alignment = .leading; stack.distribution = .fill; stack.spacing=12; stack.translatesAutoresizingMaskIntoConstraints=false
        let content=NSView(frame:NSRect(x:0,y:0,width:294,height:212)); content.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:content.leadingAnchor,constant:18),stack.trailingAnchor.constraint(equalTo:content.trailingAnchor,constant:-18),stack.topAnchor.constraint(equalTo:content.topAnchor,constant:16),stack.bottomAnchor.constraint(equalTo:content.bottomAnchor,constant:-16)])
        let controller=NSViewController(); controller.view=content
        let popover=NSPopover(); popover.behavior = .transient; popover.contentViewController=controller; popover.contentSize=content.frame.size
        readerSettingsPopover=popover; popover.show(relativeTo:sender.bounds,of:sender,preferredEdge:.minY)
    }

    private func readerPreferencePayload()->[String:Any] {
        ["size":readerFontSize,"font":readerFontChoice,"theme":UserDefaults.standard.string(forKey:"readerTheme") ?? "paper","spacing":UserDefaults.standard.string(forKey:"readerSpacing") ?? "normal"]
    }

    private func applyReaderPreferences() {
        guard let data=try? JSONSerialization.data(withJSONObject:readerPreferencePayload()),let json=String(data:data,encoding:.utf8) else { return }
        readerWebView?.evaluateJavaScript("window.readerApplyPreferences && window.readerApplyPreferences(\(json));",completionHandler:nil)
        readerSizeLabel?.stringValue="\(Int(readerFontSize)) pt"
    }

    private func updateReaderChapters(_ chapters:[[String:Any]]) {
        readerChapters=chapters
        guard let menu=readerChapterMenu else { return }
        menu.removeAllItems()
        for (index,chapter) in chapters.enumerated() {
            let title=(chapter["title"] as? String ?? "Section \(index+1)")
            menu.addItem(withTitle:title)
            menu.lastItem?.tag=index
        }
        if chapters.isEmpty { menu.addItem(withTitle:"No chapter headings") }
    }

    private func updateReaderPosition(_ info:[String:Any]) {
        let percentage=min(1,max(0,(info["percentage"] as? NSNumber)?.doubleValue ?? 0))
        readerProgressSlider?.doubleValue=percentage
        readerProgressLabel?.stringValue="\(Int((percentage*100).rounded()))%"
        let page=max(1,(info["page"] as? Int) ?? 1),pages=max(1,(info["pages"] as? Int) ?? 1)
        readerPageLabel?.stringValue="\(page) / \(pages)"
        if let chapter=info["chapter"] as? Int,let menu=readerChapterMenu,chapter>=0,chapter<menu.numberOfItems { menu.selectItem(at:chapter) }
    }

    private func navigateReaderChapter(_ offset:Int) {
        guard !readerChapters.isEmpty else { return }
        let selected=readerChapterMenu?.indexOfSelectedItem ?? 0
        let target=max(0,min(readerChapters.count-1,selected+offset))
        readerWebView?.evaluateJavaScript("window.readerGoTo(\(target));",completionHandler:nil)
    }

    @objc private func readerPreviousPage() { readerWebView?.evaluateJavaScript("window.readerPage && window.readerPage(-1)",completionHandler:nil) }
    @objc private func readerNextPage() { readerWebView?.evaluateJavaScript("window.readerPage && window.readerPage(1)",completionHandler:nil) }
    @objc private func readerHighlight() { readerWebView?.evaluateJavaScript("window.captureReaderHighlight && window.captureReaderHighlight()",completionHandler:nil) }
    @objc private func readerPreviousChapter() { navigateReaderChapter(-1) }
    @objc private func readerNextChapter() { navigateReaderChapter(1) }
    @objc private func readerSelectChapter(_ sender:NSPopUpButton) { guard sender.indexOfSelectedItem>=0 else { return }; readerWebView?.evaluateJavaScript("window.readerGoTo(\(sender.indexOfSelectedItem));",completionHandler:nil) }
    @objc private func readerDecreaseText() { readerFontSize=max(12,readerFontSize-1); UserDefaults.standard.set(readerFontSize,forKey:"readerFontSize"); applyReaderPreferences() }
    @objc private func readerIncreaseText() { readerFontSize=min(32,readerFontSize+1); UserDefaults.standard.set(readerFontSize,forKey:"readerFontSize"); applyReaderPreferences() }
    @objc private func readerSelectFont(_ sender:NSPopUpButton) { let values=["sans","serif","system"]; let index=sender.indexOfSelectedItem; guard values.indices.contains(index) else { return }; readerFontChoice=values[index]; UserDefaults.standard.set(readerFontChoice,forKey:readerIsJapanese ? "readerFontFamily.ja" : "readerFontFamily.en"); applyReaderPreferences() }
    @objc private func readerSelectTheme(_ sender:NSPopUpButton) { let values=["light","paper","night"]; let index=sender.indexOfSelectedItem; guard values.indices.contains(index) else { return }; UserDefaults.standard.set(values[index],forKey:"readerTheme"); applyReaderPreferences() }
    @objc private func readerSelectSpacing(_ sender:NSPopUpButton) { let values=["compact","normal","relaxed"]; let index=sender.indexOfSelectedItem; guard values.indices.contains(index) else { return }; UserDefaults.standard.set(values[index],forKey:"readerSpacing"); applyReaderPreferences() }
    @objc private func readerProgressChanged(_ sender:NSSlider) { readerWebView?.evaluateJavaScript("window.readerScrollTo(\(sender.doubleValue));",completionHandler:nil) }
    @objc private func closeReader() {
        guard let dashboardContentView else { return }
        let directory=readerTempDirectory
        let removeDirectory = !readerWorkIsPersistentCache
        readerWebView?.stopLoading()
        readerWebView?.configuration.userContentController.removeScriptMessageHandler(forName:"reader")
        readerSettingsPopover?.performClose(nil); readerSettingsPopover=nil
        readerWebView=nil; readerContentView=nil; activeReader=nil; readerTempDirectory=nil; readerWorkIsPersistentCache=false
        readerChapterMenu=nil; readerFontMenu=nil; readerThemeMenu=nil; readerSpacingMenu=nil; readerSizeLabel=nil; readerProgressSlider=nil; readerProgressLabel=nil; readerPageLabel=nil; readerHighlightButton=nil; readerChapters=[]
        window.contentView=dashboardContentView
        window.title="Shelf"
        if let directory,removeDirectory { DispatchQueue.main.asyncAfter(deadline:.now()+3) { try? FileManager.default.removeItem(at:directory) } }
    }

    private func syncReaderHighlight(_ body:[String:Any]) {
        guard let text=body["text"] as? String,!text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
              let reader=activeReader,let document=reader["document"] as? String,
              document.range(of:#"^[0-9a-fA-F]{32}$"#,options:.regularExpression) != nil else { return }
        let key=syncAuthKey()
        guard !key.isEmpty else { notify("Could not reach CrossPoint Sync to save this highlight."); return }
        let now=Int(Date().timeIntervalSince1970)
        let page=max(1,(body["page"] as? Int) ?? 1)
        let pageCount=max(page,(body["pages"] as? Int) ?? page)
        let item:[String:Any]=[
            "id":UUID().uuidString,"spine":0,"start_page":page,"end_page":page,"pages":pageCount,
            "start_word":0,"end_word":0,"words":0,"para":NSNull(),
            "chapter":String((body["chapter"] as? String ?? "").prefix(64)),"text":String(text.prefix(4096)),
            "created_at":now,"layout_signature":0,"start_offset":NSNull(),"end_offset":NSNull(),
            "color":"yellow"
        ]
        guard let url=URL(string:"\(service("crosspointApi", fallback: "http://127.0.0.1:17303"))/clippings/\(document)"),
              let data=try? JSONSerialization.data(withJSONObject:["items":[item]]) else {
            notify("Could not prepare this highlight."); return
        }
        var request=URLRequest(url:url,timeoutInterval:12)
        request.httpMethod="PUT"; request.httpBody=data
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        request.setValue(username,forHTTPHeaderField:"x-auth-user")
        request.setValue(key,forHTTPHeaderField:"x-auth-key")
        request.setValue("application/vnd.koreader.v1+json",forHTTPHeaderField:"Accept")
        URLSession.shared.dataTask(with:request) { [weak self] _,response,error in
            DispatchQueue.main.async {
                guard let self else { return }
                guard error == nil,(response as? HTTPURLResponse)?.statusCode == 200 else {
                    self.notify("Could not save the highlight to CrossPoint Sync."); return
                }
                self.notify("Highlight saved to CrossPoint · queued for connected highlight services")
            }
        }.resume()
    }

    private func chooseEPUBImports() {
        let panel=NSOpenPanel()
        panel.title="Add EPUBs to your Calibre library"
        panel.message="Files are staged in iCloud and processed by your normal security, duplicate, and metadata import jobs."
        panel.allowedContentTypes=[UTType(filenameExtension:"epub") ?? .data]
        panel.allowsMultipleSelection=true
        panel.canChooseDirectories=false
        panel.canChooseFiles=true
        panel.beginSheetModal(for:window) { [weak self] response in
            guard response == .OK,let self else { return }
            self.queueEPUBImports(panel.urls)
        }
    }

    private func queueEPUBImports(_ urls:[URL]) {
        let epubs=urls.filter{$0.isFileURL && $0.pathExtension.lowercased()=="epub"}
        guard !epubs.isEmpty else { notify("Choose one or more EPUB files."); return }
        let inbox=URL(fileURLWithPath:"\(importPath)",isDirectory:true)
        let importerScript="\(scriptsPath)/calibre_icloud_import.sh"
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            var queued=0
            var failures=[String]()
            do { try FileManager.default.createDirectory(at:inbox,withIntermediateDirectories:true) }
            catch { DispatchQueue.main.async { self?.notify("Could not open the configured import folder: \(error.localizedDescription)") }; return }
            for source in epubs {
                let access=source.startAccessingSecurityScopedResource()
                defer { if access { source.stopAccessingSecurityScopedResource() } }
                let stem=source.deletingPathExtension().lastPathComponent
                let safeName=stem.isEmpty ? "Book" : stem
                let destination=inbox.appendingPathComponent("\(safeName).epub")
                let finalURL:URL
                if FileManager.default.fileExists(atPath:destination.path) {
                    finalURL=inbox.appendingPathComponent("\(safeName) \(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(6)).epub")
                } else { finalURL=destination }
                let temporary=inbox.appendingPathComponent(".CalibreStack-\(UUID().uuidString).partial")
                do {
                    try FileManager.default.copyItem(at:source,to:temporary)
                    try FileManager.default.moveItem(at:temporary,to:finalURL)
                    queued += 1
                } catch {
                    try? FileManager.default.removeItem(at:temporary)
                    failures.append("\(source.lastPathComponent): \(error.localizedDescription)")
                }
            }
            if queued > 0 {
                DispatchQueue.main.async { self?.notify("\(queued) EPUB\(queued == 1 ? "" : "s") added to your import folder · configured import jobs are running.") }
                let importResult=Self.run("/bin/bash",[importerScript])
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.loadBooks()
                    self.loadHardcoverShelf()
                    if importResult.code == 0 {
                        self.notify("Import pass finished · Hardcover and Continue reading refreshed.")
                    } else {
                        self.notify("The files are safe in the iCloud import folder; the importer logged an issue and will retry on its next run.")
                    }
                }
            }
            if !failures.isEmpty { DispatchQueue.main.async { self?.notify("Import copy failed: \(failures.prefix(2).joined(separator:"; "))") } }
        }
    }

    private func syncReaderProgress(_ body:[String:Any]) {
        guard body["type"] as? String == "progress",
              let document=body["document"] as? String,document.range(of:#"^[0-9a-fA-F]{32}$"#,options:.regularExpression) != nil,
              let percent=(body["percentage"] as? NSNumber)?.doubleValue,percent.isFinite,percent>=0,percent<=1 else { return }
        let documents=Array(Set(([document]+(body["syncDocuments"] as? [String] ?? [])).filter{$0.range(of:#"^[0-9a-fA-F]{32}$"#,options:.regularExpression) != nil}))
        let key=syncAuthKey()
        guard !key.isEmpty else { setReaderStatus("Could not reach the saved KOReader Sync login."); return }
        var request=URLRequest(url:URL(string:"\(service("crosspointApi", fallback: "http://127.0.0.1:17303"))/syncs/progress")!,timeoutInterval:10)
        request.httpMethod="PUT"; request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        request.setValue(username,forHTTPHeaderField:"x-auth-user"); request.setValue(key,forHTTPHeaderField:"x-auth-key")
        request.setValue("application/vnd.koreader.v1+json",forHTTPHeaderField:"Accept")
        var metadata=(body["metadata"] as? [String:Any]) ?? [:]
        metadata=metadata.filter { ["title","authors","filename","language"].contains($0.key) }
        let payload:[String:Any]=[
            "progress":String(format:"%.6f",percent),"percentage":percent,
            "device":"Shelf","device_id":"calibre-stack-dashboard","metadata":metadata
        ]
        let group=DispatchGroup(),lock=NSLock(); var results=[String:[Bool]]()
        for (name,root) in [("KOReader Sync",service("kosyncHealth", fallback: "http://127.0.0.1:17200/healthcheck").replacingOccurrences(of: "/healthcheck", with: "")),("CrossPoint Sync",service("crosspointApi", fallback: "http://127.0.0.1:17303"))] {
            for doc in documents {
                guard let url=URL(string:"\(root)/syncs/progress") else { continue }
                var destination=request; destination.url=url
                var payloadForDocument=payload; payloadForDocument["document"]=doc
                guard let data=try? JSONSerialization.data(withJSONObject:payloadForDocument) else { continue }
                destination.httpBody=data
                group.enter()
                URLSession.shared.dataTask(with:destination) { _,response,_ in
                    let success=(response as? HTTPURLResponse)?.statusCode == 200
                    lock.lock(); results[name,default:[]].append(success); lock.unlock(); group.leave()
                }.resume()
            }
        }
        group.notify(queue:.main) { [weak self] in
            guard let self else { return }
            let readerOK=results["KOReader Sync"]?.count == documents.count && (results["KOReader Sync"]?.allSatisfy{$0} ?? false)
            let crosspointOK=results["CrossPoint Sync"]?.count == documents.count && (results["CrossPoint Sync"]?.allSatisfy{$0} ?? false)
            if readerOK && crosspointOK {
                self.readerWebView?.evaluateJavaScript("window.readerAckProgress(\(percent))",completionHandler:nil)
                self.setReaderStatus("Synced to both local servers · \(documents.count) file IDs · Hardcover forwards matched books")
                self.send("readerProgressUpdated",["bookId":body["bookId"] ?? 0,"percentage":percent])
            } else if readerOK || crosspointOK {
                self.readerWebView?.evaluateJavaScript("window.readerFailProgress && window.readerFailProgress()",completionHandler:nil)
                let synced=([readerOK ? "KOReader Sync" : nil,crosspointOK ? "CrossPoint Sync" : nil].compactMap{$0}).joined(separator:" + ")
                self.setReaderStatus("Synced to \(synced); retrying the other server…")
                self.send("readerProgressUpdated",["bookId":body["bookId"] ?? 0,"percentage":percent])
            } else {
                self.readerWebView?.evaluateJavaScript("window.readerFailProgress && window.readerFailProgress()",completionHandler:nil)
                self.setReaderStatus("Both sync servers are unavailable · your book is still open locally.")
            }
        }
    }

    private func setReaderStatus(_ message:String) {
        DispatchQueue.main.async { self.send("readerNotice",["message":message]) }
    }

    private func withCover(_ source:[String:Any])->[String:Any] {
        var book=source
        guard let path=source["coverPath"] as? String, !path.isEmpty,
              let source=CGImageSourceCreateWithURL(URL(fileURLWithPath:path) as CFURL,nil),
              let image=CGImageSourceCreateThumbnailAtIndex(source,0,[kCGImageSourceCreateThumbnailFromImageAlways:true,kCGImageSourceCreateThumbnailWithTransform:true,kCGImageSourceThumbnailMaxPixelSize:520] as CFDictionary) else { return book }
        let output=NSMutableData()
        guard let destination=CGImageDestinationCreateWithData(output,UTType.jpeg.identifier as CFString,1,nil) else { return book }
        CGImageDestinationAddImage(destination,image,[kCGImageDestinationLossyCompressionQuality:0.72] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return book }
        book["coverData"]="data:image/jpeg;base64,\((output as Data).base64EncodedString())"
        return book
    }

    private func hardcoverRequest(path:String,completion:@escaping (Result<[[String:Any]],Error>)->Void) {
        let key=syncAuthKey()
        guard !key.isEmpty, let components=URLComponents(string:"\(service("crosspointApi", fallback: "http://127.0.0.1:17303"))/api/v1/connectors/hardcover/\(path)") else {
            completion(.failure(NSError(domain:"Hardcover",code:1,userInfo:[NSLocalizedDescriptionKey:"CrossPoint Sync credentials are unavailable."]))); return
        }
        var request=URLRequest(url:components.url!,timeoutInterval:30)
        request.setValue(username,forHTTPHeaderField:"x-auth-user"); request.setValue(key,forHTTPHeaderField:"x-auth-key")
        URLSession.shared.dataTask(with:request) { data,response,error in
            if let error { completion(.failure(error)); return }
            guard let data,(response as? HTTPURLResponse)?.statusCode == 200,
                  let payload=try? JSONSerialization.jsonObject(with:data) as? [String:Any],
                  let books=payload["books"] as? [[String:Any]] else {
                completion(.failure(NSError(domain:"Hardcover",code:2,userInfo:[NSLocalizedDescriptionKey:"Hardcover is not linked in CrossPoint Sync, or its catalog could not be reached."]))); return
            }
            completion(.success(books))
        }.resume()
    }

    private func loadHardcoverShelf() {
        hardcoverRequest(path:"candidates") { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error): DispatchQueue.main.async { self.send("hardcoverShelfError",["message":error.localizedDescription]) }
            case .success(let books): DispatchQueue.main.async { self.send("hardcoverShelfData",["books":books,"loadedAt":Self.iso(Date())]) }
            }
        }
    }

    private func searchHardcover(_ query:String) {
        guard !query.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return }
        var parts=URLComponents(); parts.queryItems=[URLQueryItem(name:"q",value:query)]
        let path="search?\(parts.percentEncodedQuery ?? "")"
        hardcoverRequest(path:path) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error): DispatchQueue.main.async { self.send("discoveryError",["period":self.currentDiscoveryPeriod,"message":error.localizedDescription]) }
            case .success(let books): DispatchQueue.main.async { self.send("discoveryData",["period":self.currentDiscoveryPeriod,"basis":"Hardcover catalog search · \(query)","books":books,"loadedAt":Self.iso(Date()),"source":"Hardcover"]) }
            }
        }
    }

    private var currentDiscoveryPeriod="weekly"
    private func loadDiscovery(_ period:String) {
        guard ["weekly","monthly","yearly","all-time"].contains(period) else { return }
        currentDiscoveryPeriod=period
        hardcoverRequest(path:"discover?period=\(period)") { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error): DispatchQueue.main.async { self.send("discoveryError",["period":period,"message":error.localizedDescription]) }
            case .success(let books):
                let label:[String:String]=["weekly":"Trending this week on Hardcover","monthly":"Trending this month on Hardcover","yearly":"Trending this year on Hardcover","all-time":"All-time trending on Hardcover"]
                DispatchQueue.main.async { self.send("discoveryData",["period":period,"basis":label[period] ?? "Hardcover trending","books":books,"loadedAt":Self.iso(Date()),"source":"Hardcover"]) }
            }
        }
    }

    private func openBookLink(_ raw:String) {
        guard let url=URL(string:raw),url.scheme == "https",
              ["hardcover.app","calibre-ebook.com","github.com"].contains(url.host ?? "") else { return }
        NSWorkspace.shared.open(url)
    }

    private func openCrossPointSettings() {
        guard let url=URL(string:service("hardcoverSettings", fallback: "http://127.0.0.1:17300/app/#/settings")) else { return }
        NSWorkspace.shared.open(url)
    }

    // Read only connection metadata from CrossPoint Sync. Never select or return
    // encrypted credentials, account labels, or provider error text.
    private func readConnectorStatuses() -> [[String:Any]] {
        let key=syncAuthKey()
        guard !key.isEmpty,let url=URL(string:"\(service("crosspointApi", fallback: "http://127.0.0.1:17303"))/api/v1/connectors") else { return [] }
        var request=URLRequest(url:url,timeoutInterval:4)
        request.setValue(username,forHTTPHeaderField:"x-auth-user")
        request.setValue(key,forHTTPHeaderField:"x-auth-key")
        let semaphore=DispatchSemaphore(value:0)
        var payload:Data?,status=0
        URLSession.shared.dataTask(with:request) { data,response,_ in
            payload=data; status=(response as? HTTPURLResponse)?.statusCode ?? 0; semaphore.signal()
        }.resume()
        guard semaphore.wait(timeout:.now()+4) == .success,status == 200,
              let payload,let root=try? JSONSerialization.jsonObject(with:payload) as? [String:Any],
              let connectors=root["connectors"] as? [[String:Any]] else { return [] }
        return connectors.compactMap { item in
            guard item["linked"] as? Bool == true else { return nil }
            let queue=item["queue"] as? [String:Any] ?? [:]
            return ["id":item["id"] ?? "","status":item["status"] ?? "unknown",
                    "enabled":(item["enabled"] as? Bool == false) ? 0 : 1,
                    "pending":queue["pending"] ?? 0,"failed":queue["dead"] ?? 0]
        }
    }

    private func readDashboard() -> [String:Any] {
        let logDir=logsPath
        let defs: [(String,String,String,String?,String?,Double?,String,String?,String?)] = [
            ("calibre","Calibre Content Server","Service",agent("calibre",fallback:"app.shelf.calibre-server"),service("calibreOpds",fallback:"http://127.0.0.1:8080/opds/"),nil,"server.rack","\(logDir)/calibre-server.log","restart-calibre"),
            ("caddy","Reverse proxy","Service",agent("caddy",fallback:"homebrew.mxcl.caddy"),service("caddyOpds",fallback:""),nil,"arrow.trianglehead.2.clockwise.rotate.90",logFile("caddy",fallback:"caddy.log"),"restart-caddy"),
            ("kosync","KOReader Sync","Service",nil,service("kosyncHealth",fallback:"http://127.0.0.1:17200/healthcheck"),nil,"arrow.trianglehead.2.clockwise.rotate.90","\(logDir)/kosync.log","restart-kosync"),
            ("crosspoint","CrossPoint Sync","Service",nil,service("crosspointHealth",fallback:"http://127.0.0.1:17303/healthz"),nil,"point.3.connected.trianglepath.dotted","\(logDir)/crosspoint-sync.log","restart-crosspoint"),
            ("xteink-device","E-reader device","Service",nil,service("xteinkStatus",fallback:""),nil,"book.closed.fill","\(logDir)/device-sync.log",nil),
            ("importer","E-book importer","Automation",agent("importer",fallback:"app.shelf.calibre-importer"),nil,600,"square.and.arrow.down","\(logDir)/calibre-icloud-import.log","run-import"),
            ("bridge","Reader progress bridge","Automation",agent("bridge",fallback:"app.shelf.kosync-calibre-bridge"),nil,300,"arrow.left.arrow.right","\(logDir)/kosync-calibre-bridge.log","run-bridge"),
            ("backup","Library backup","Automation",agent("backup",fallback:"app.shelf.restic-backup"),nil,3600,"externaldrive.fill.badge.timemachine","\(logDir)/calibre-restic-backup.log","backup-now"),
            ("japanese","Japanese EPUB audit","Automation",agent("japanese",fallback:"app.shelf.japanese-audit"),nil,86400,"character.book.closed.fill.ja","\(logDir)/calibre-japanese-audit.log","run-japanese-audit"),
            ("duplicates","Duplicate guard","Automation",agent("duplicates",fallback:"app.shelf.duplicate-guard"),nil,300,"doc.on.doc.fill","\(logDir)/calibre-duplicate-guard.log","run-duplicate-guard"),
            ("duplicate-audit","Duplicate audit","Automation",agent("duplicateAudit",fallback:"app.shelf.duplicate-audit"),nil,86400,"checkmark.seal.fill","\(logDir)/calibre-duplicate-audit.log","run-duplicate-audit"),
            ("malware","Incoming ebook safety check","Automation",agent("malware",fallback:"app.shelf.malware-guard"),nil,300,"shield.lefthalf.filled","\(logDir)/calibre-malware-guard.log","run-malware-guard"),
            ("full-scan","Full-library safety scan","Automation",agent("fullScan",fallback:"app.shelf.malware-full-scan"),nil,604800,"shield.fill","\(logDir)/calibre-malware-full-scan.log","run-full-scan"),
            ("xteink","E-reader sync helper","Automation",agent("xteink",fallback:"app.shelf.device-sync"),nil,300,"book.closed.fill","\(logDir)/xteink-sync-configurator.log",nil)
        ]
        var items=[[String:Any]]()
        for (id,name,category,label,endpoint,interval,icon,logPath,action) in defs {
            let agent=label.flatMap { $0.isEmpty ? nil : launchInfo("gui/\(uid)/\($0)") }
            let pid=agent?.pid
            let since=pid.map(processUptime)
            let mod=logPath.flatMap(fileModified)
            let lastLine=logPath.flatMap { tail($0,lines:1).last } ?? ""
            var state="scheduled", summary="Scheduled task waiting for its next interval", code: String?
            var measuredUptime=since ?? "Not running"
            if category == "Service" {
                code=endpoint.flatMap { $0.isEmpty ? nil : httpStatus($0,auth:id == "calibre" || id == "caddy") }
                if id == "kosync" || id == "crosspoint" {
                    let name=id == "kosync" ? "kosync" : "crosspoint-sync"
                let containerName=configuration.value("containers.\(name)",fallback:name)
                    let c=container(containerName)
                    measuredUptime=c.uptime
                    state=c.healthy ? "healthy" : (c.exists ? "warning" : "failed")
                    summary="Container \(c.health) · HTTP probe \(code ?? "unreachable")"
                } else {
                    let optionalEndpoint=id == "xteink-device" || endpoint?.isEmpty == true
                    state=optionalEndpoint ? (code == "200" ? "healthy" : "optional") : ((code == "200" && pid != nil) ? "healthy" : ((code == "200" || pid != nil) ? "warning" : "failed"))
                    summary=optionalEndpoint ? (code == "200" ? "Device endpoint responding" : "Optional · no device connected or configured") : (code == "200" ? "HTTP endpoint responding" : "HTTP \(code ?? "unreachable")")
                }
            } else {
                let maxAge=(interval ?? 3600)*2.2+180
                let age=mod.map { Date().timeIntervalSince($0) }
                let errorLine=lastLine.range(of:#"error|failed|failure|denied|exception"#,options:.regularExpression.union(.caseInsensitive)) != nil
                if let age, age < maxAge {
                    state=(errorLine || (agent?.lastExit ?? 0) != 0) ? "warning" : "healthy"
                }
                else if agent?.pid == nil && agent?.lastExit == nil {
                    state="scheduled"
                    summary="Loaded and waiting for its next scheduled run"
                }
                else if let lastExit=agent?.lastExit, lastExit == 0 {
                    state="healthy"
                    summary="Last scheduled run exited successfully"
                }
                else if mod == nil { state="warning" }
                else { state="stale" }
                if !(state == "healthy" && (age == nil || (age ?? 0) >= maxAge)) {
                    summary=lastLine.isEmpty ? "No log activity recorded" : redact(lastLine)
                }
                if id == "bridge", lastLine.contains("BRIDGE END") {
                    let documents=Int(Self.capture(#"documents=(\d+)"#,lastLine) ?? "0") ?? 0
                    let matched=Int(Self.capture(#"matched=(\d+)"#,lastLine) ?? "0") ?? 0
                    if documents > 0 && matched == 0 {
                        state="warning"
                        summary="No Calibre books matched the latest \(documents) progress records"
                    } else if matched > 0 {
                        summary="Matched \(matched) progress records to Calibre books"
                    }
                }
            }
            let row:[String:Any]=[
                "id":id,"name":name,"category":category,"state":state,"summary":summary,
                "icon":icon,"endpoint":endpoint ?? "","uptime":measuredUptime,
                "lastActivity":mod.map(relative) ?? "No log yet",
                "interval":interval.map(formatInterval) ?? "Continuous",
                "lastExit":agent?.lastExit.map(String.init) ?? "—","logPath":logPath ?? "","action":action ?? ""
            ]
            items.append(row)
        }
        let sources=[
            ("Calibre server","\(logDir)/calibre-server.log"),("Importer","\(logDir)/calibre-icloud-import.log"),
            ("Restic backup","\(logDir)/calibre-restic-backup.log"),("KOReader bridge","\(logDir)/kosync-calibre-bridge.log"),
            ("Japanese audit","\(logDir)/calibre-japanese-audit.log"),("Duplicates","\(logDir)/calibre-duplicate-audit.log"),
            ("Malware guard","\(logDir)/calibre-malware-guard.log"),("Xteink","\(logDir)/xteink-sync-configurator.log")
        ]
        var events=[[String:Any]]()
        for (source,path) in sources {
            let modified=fileModified(path)
            for line in tail(path,lines:120) {
                let level=eventLevel(line)
                guard level != nil else { continue }
                let stamped=eventDate(line)
                let eventTime=stamped ?? modified
                guard let eventTime, Date().timeIntervalSince(eventTime) < (stamped == nil ? 86400 : 172800) else { continue }
                events.append(["source":source,"level":level!,"message":redact(line),"date":iso(eventTime)])
            }
        }
        events.sort { (($0["date"] as? String) ?? "") > (($1["date"] as? String) ?? "") }
        let ips=Self.run("/sbin/ifconfig",["en0"]).output
        let ip=Self.capture(#"inet (\d+\.\d+\.\d+\.\d+)"#,ips) ?? "Unavailable"
        let pass=serverPassword()
        let plugin=(try? Data(contentsOf:URL(fileURLWithPath:"\(home)/Library/Preferences/calibre/plugins/KOReader Sync.json"))).flatMap { try? JSONSerialization.jsonObject(with:$0) as? [String:Any] } ?? [:]
        let redis=Self.run(dockerPath,["exec","kosync","redis-cli","--raw","-n","1","GET","user:\(username):key"]).output.trimmingCharacters(in:.whitespacesAndNewlines)
        let shared=(md5(pass) == (plugin["progress_sync_password"] as? String ?? "") && md5(pass) == redis)
        let readerOPDS=service("readerOpds",fallback:"http://\(ip):8080/opds")
        let readerSync=service("readerSync",fallback:"http://\(ip):17200")
        return ["generatedAt":iso(Date()),"ip":ip,"items":items,"events":Array(events.prefix(300)),"updates":updates,"sharedPasswordAligned":shared,"connectors":readConnectorStatuses(),"config":["username":username,"library":libraryPath,"bridge":bridgeScriptPath,"plugin":"~/Library/Preferences/calibre/plugins/KOReader Sync.json","opds":readerOPDS,"sync":readerSync,"import":importPath,"connections":configuration.strings("connections"),"connectionsConfigured":configuration.bool("connectionsConfigured")]]
    }

    private func confirmAndRun(_ id:String) {
        guard let command=command(id) else { return }
        let descriptions:[String:(String,String)]=[
            "restart-calibre":("Restart Calibre server?","OPDS and Calibre clients will disconnect briefly."),
            "restart-caddy":("Restart Caddy proxy?","Proxy connections will reconnect after restart."),
            "restart-kosync":("Restart KOReader Sync?","Progress uploads pause briefly; stored data is retained."),
            "restart-crosspoint":("Restart CrossPoint Sync?","The local sync endpoint pauses briefly; stored data is retained."),
            "run-import":("Run e-book import now?","The importer processes files in your configured import folder."),
            "run-bridge":("Run progress bridge now?","KOReader progress records will be applied to matching Calibre books."),
            "backup-now":("Run backup now?","Runs Restic, pruning, and the iCloud mirror. This can take several minutes."),
            "run-japanese-audit":("Run Japanese EPUB audit?","EPUBCheck may use significant CPU while the library is scanned."),
            "run-full-scan":("Run full malware scan?","Scans the full Calibre library and may take a while."),
            "run-duplicate-audit":("Run duplicate audit?","Starts the library duplicate check."),
            "run-duplicate-guard":("Run duplicate guard now?","Checks queued imports for duplicate books."),
            "run-malware-guard":("Run malware guard now?","Scans newly queued books for malware.")
        ]
        let (title,message)=descriptions[id] ?? ("Run task?","This starts the selected background action.")
        let alert=NSAlert(); alert.messageText=title; alert.informativeText=message; alert.alertStyle = .warning; alert.addButton(withTitle:"Continue"); alert.addButton(withTitle:"Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        notify("Starting \(command.label)…")
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            let result=Self.run(command.executable,command.arguments)
            DispatchQueue.main.async {
                self?.notify(result.code == 0 ? "\(command.label) started." : "\(command.label) failed: \(result.output)")
                DispatchQueue.main.asyncAfter(deadline:.now()+1.0) { self?.refresh() }
            }
        }
    }

    private func command(_ id:String)->(executable:String,arguments:[String],label:String)? {
        let launch="/bin/launchctl", domain="gui/\(uid)"
        switch id {
        case "restart-calibre":return (launch,["kickstart","-k","\(domain)/\(agent("calibre",fallback:"app.shelf.calibre-server"))"],"Calibre server restart")
        case "restart-caddy":return (brewPath,["services","restart","caddy"],"Reverse proxy restart")
        case "restart-kosync":return (dockerPath,["restart",configuration.value("containers.kosync",fallback:"kosync")],"KOReader Sync restart")
        case "restart-crosspoint":return (dockerPath,["restart",configuration.value("containers.crosspoint",fallback:"crosspoint-sync")],"CrossPoint Sync restart")
        case "run-import":return (launch,["kickstart","-k","\(domain)/\(agent("importer",fallback:"app.shelf.calibre-importer"))"],"E-book import")
        case "run-bridge":return ("/usr/bin/python3",[bridgeScriptPath],"Reading-progress bridge")
        case "backup-now":return ("/bin/bash",["\(scriptsPath)/calibre-restic-backup.sh"],"Library backup")
        case "run-japanese-audit":return (launch,["kickstart","-k","\(domain)/\(agent("japanese",fallback:"app.shelf.japanese-audit"))"],"Japanese EPUB audit")
        case "run-full-scan":return ("/bin/bash",["\(scriptsPath)/calibre-malware-full-scan.sh"],"Full-library safety scan")
        case "run-duplicate-audit":return (launch,["kickstart","-k","\(domain)/\(agent("duplicateAudit",fallback:"app.shelf.duplicate-audit"))"],"Duplicate audit")
        case "run-duplicate-guard":return (launch,["kickstart","-k","\(domain)/\(agent("duplicates",fallback:"app.shelf.duplicate-guard"))"],"Duplicate guard")
        case "run-malware-guard":return (launch,["kickstart","-k","\(domain)/\(agent("malware",fallback:"app.shelf.malware-guard"))"],"Incoming ebook safety check")
        default:return nil
        }
    }

    private func checkUpdates() {
        guard !updateCheckInProgress else { return }
        updateCheckInProgress=true
        notify("Checking official update sources…")
        let group=DispatchGroup(); let lock=NSLock(); var latestCalibre:String?, latestCrossPoint:String?
        group.enter()
        URLSession.shared.dataTask(with:URL(string:"https://calibre-ebook.com/whats-new")!) { data,_,_ in
            if let data, let text=String(data:data,encoding:.utf8), let version=Self.capture(#"Release:\s*([0-9]+\.[0-9]+)"#,text) { lock.lock(); latestCalibre=version; lock.unlock() }
            group.leave()
        }.resume()
        group.enter()
        URLSession.shared.dataTask(with:URL(string:"https://api.github.com/repos/crosspoint-reader/crosspoint-reader/releases?per_page=10")!) { data,_,_ in
            if let data, let releases=try? JSONSerialization.jsonObject(with:data) as? [[String:Any]], let release=releases.first(where:{($0["prerelease"] as? Bool)==false}), let tag=release["tag_name"] as? String { lock.lock(); latestCrossPoint=tag.replacingOccurrences(of:"v",with:""); lock.unlock() }
            group.leave()
        }.resume()
        group.notify(queue:.main) { [weak self] in
            guard let self else { return }
            if let latestCalibre { self.updates["calibreLatest"]=latestCalibre }
            if let latestCrossPoint { self.updates["crossPointLatest"]=latestCrossPoint }
            self.updates["checkedAt"]=Self.iso(Date()); self.updateCheckInProgress=false; self.refresh()
        }
    }

    private func checkAll() {
        notify("Checking services, scheduled jobs, recent errors, credentials and official releases…")
        refresh()
        checkUpdates()
    }

    private func confirmFixAll() {
        let alert=NSAlert()
        alert.messageText="Repair unhealthy services?"
        alert.informativeText="The dashboard will check everything, then restart only unhealthy Calibre, Caddy, KOReader Sync, or CrossPoint services. It will not restart the reader, run library scans, or change book files."
        alert.alertStyle = .warning
        alert.addButton(withTitle:"Check and repair")
        alert.addButton(withTitle:"Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        notify("Checking services before repair…")
        DispatchQueue.global(qos:.utility).async { [weak self] in
            guard let self else { return }
            let snapshot=self.readDashboard()
            let items=snapshot["items"] as? [[String:Any]] ?? []
            let ids=items.compactMap { row -> String? in
                guard let id=row["id"] as? String, let state=row["state"] as? String,
                      ["failed","warning","stale"].contains(state),
                      ["calibre","caddy","kosync","crosspoint"].contains(id) else { return nil }
                return "restart-" + id
            }
            guard !ids.isEmpty else {
                DispatchQueue.main.async { self.notify("Check complete: all repairable core services are healthy.") }
                return
            }
            var repaired=[String](), failed=[String]()
            for id in ids {
                guard let action=self.command(id) else { continue }
                let result=Self.run(action.executable,action.arguments)
                if result.code == 0 { repaired.append(action.label) }
                else { failed.append(action.label) }
            }
            Thread.sleep(forTimeInterval:3)
            let after=self.readDashboard()
            DispatchQueue.main.async {
                self.refresh()
                let remaining=(after["items"] as? [[String:Any]] ?? []).filter { row in
                    ["calibre","caddy","kosync","crosspoint"].contains(row["id"] as? String ?? "") &&
                    ["failed","warning","stale"].contains(row["state"] as? String ?? "")
                }.compactMap { $0["name"] as? String }
                var message="Repair finished. Restarted: \(repaired.count)."
                if !failed.isEmpty { message += " Failed: \(failed.joined(separator:", "))." }
                if !remaining.isEmpty { message += " Still needs attention: \(remaining.joined(separator:", "))." }
                self.notify(message)
            }
        }
    }

    private func confirmUpdateCalibre() {
        let alert=NSAlert()
        alert.messageText="Update Calibre and Caddy?"
        alert.informativeText="Uses Homebrew to install available updates, then restarts the affected services. Calibre and proxy connections will briefly disconnect. Reader firmware is not changed."
        alert.alertStyle = .warning
        alert.addButton(withTitle:"Update software")
        alert.addButton(withTitle:"Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        notify("Updating Calibre and Caddy with Homebrew…")
        let brewExecutable=brewPath
        DispatchQueue.global(qos:.utility).async { [weak self] in
            let brew=brewExecutable
            let first=Self.run(brew,["upgrade","--cask","calibre"])
            guard first.code == 0 else {
                DispatchQueue.main.async { self?.notify("Calibre update stopped: \(first.output.trimmingCharacters(in:.whitespacesAndNewlines).suffix(240))") }
                return
            }
            let calibreRestart=Self.run("/bin/launchctl",["kickstart","-k","gui/\(getuid())/\(self?.agent("calibre",fallback:"app.shelf.calibre-server") ?? "app.shelf.calibre-server")"])
            let second=Self.run(brew,["upgrade","caddy"])
            if second.code != 0 {
                DispatchQueue.main.async {
                    self?.checkUpdates()
                    self?.refresh()
                    self?.notify("Calibre updated. Caddy update failed: \(second.output.trimmingCharacters(in:.whitespacesAndNewlines).suffix(170))")
                }
                return
            }
            let caddyRestart=Self.run(brew,["services","restart","caddy"])
            DispatchQueue.main.async {
                self?.checkUpdates()
                self?.refresh()
                let restartWarning=calibreRestart.code == 0 && caddyRestart.code == 0 ? "" : " Service restart needs attention."
                self?.notify("Calibre and Caddy update completed.\(restartWarning)")
            }
        }
    }

    private func confirmUpdateDashboard() {
        let alert=NSAlert()
        alert.messageText="Rebuild and update the dashboard app?"
        alert.informativeText="Rebuilds the installed dashboard from its local project files and reopens it."
        alert.addButton(withTitle:"Update dashboard")
        alert.addButton(withTitle:"Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        notify("Rebuilding dashboard…")
        let installer="\(projectPath)/Scripts/build-and-install.sh"
        DispatchQueue.global(qos:.utility).async { [weak self] in
            let result=Self.run("/bin/bash",[installer])
            DispatchQueue.main.async { self?.notify(result.code == 0 ? "Dashboard rebuild completed." : "Dashboard rebuild failed: \(result.output.trimmingCharacters(in:.whitespacesAndNewlines).suffix(220))") }
        }
    }

    private func sendBooxSettings() {
        DispatchQueue.global(qos:.utility).async { [weak self] in
            guard let self else { return }
            let devices=adbDevices()
            let adbStatus=Self.run(adbPath,["devices"]).output
            DispatchQueue.main.async {
                if devices.count == 1 { self.confirmBooxTransfer(serial:devices[0]) }
                else if devices.isEmpty {
                    if adbStatus.contains("\tunauthorized") {
                        self.notify("BOOX is connected but not authorized. Unlock the tablet, accept the USB debugging prompt, then retry.")
                        return
                    }
                    if adbStatus.contains("\toffline") {
                        self.notify("BOOX is connected but offline to Android Debug Bridge. Reconnect USB, unlock the tablet and retry.")
                        return
                    }
                    let alert=NSAlert()
                    alert.messageText="No BOOX tablet connected"
                    alert.informativeText="Connect the tablet by USB, enable USB debugging, and accept the authorization prompt. You can also save a settings package to copy onto the tablet manually. The package contains your Calibre server password."
                    alert.addButton(withTitle:"Save setup package…")
                    alert.addButton(withTitle:"Cancel")
                    if alert.runModal() == .alertFirstButtonReturn { self.exportBooxSettings() }
                } else {
                    self.notify("More than one Android device is connected. Disconnect the others and retry.")
                }
            }
        }
    }

    private func confirmBooxTransfer(serial:String) {
        let alert=NSAlert()
        alert.messageText="Send Calibre settings to BOOX?"
        alert.informativeText="This adds Calibre OPDS and KOReader Sync, enables Android auto-rotate, and turns on BOOX's per-app system-orientation setting for KOReader. Existing settings are backed up first. Close KOReader before continuing. The settings include your Calibre password."
        alert.addButton(withTitle:"Send settings")
        alert.addButton(withTitle:"Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        notify("Preparing KOReader settings transfer…")
        DispatchQueue.global(qos:.utility).async { [weak self] in
            do {
                let message=try self?.transferBooxSettings(serial:serial) ?? "Transfer failed."
                DispatchQueue.main.async { self?.notify(message); self?.refresh() }
            } catch {
                DispatchQueue.main.async { self?.notify("BOOX setup not applied: \(error.localizedDescription)") }
            }
        }
    }

    private func exportBooxSettings() {
        let panel=NSSavePanel()
        panel.title="Save KOReader setup package"
        panel.message="The ZIP contains your Calibre server password. Save it locally and remove it after copying the settings to the tablet."
        panel.directoryURL=URL(fileURLWithPath:"\(home)/Downloads",isDirectory:true)
        panel.nameFieldStringValue="KOReader-Calibre-Setup.zip"
        panel.allowedContentTypes=[.zip]
        panel.canCreateDirectories=true
        guard panel.runModal() == .OK, let destination=panel.url else { return }
        DispatchQueue.global(qos:.utility).async { [weak self] in
            do {
                guard let self else { return }
                let package=try self.makeBooxSettingsPackage()
                let zipped=Self.run("/usr/bin/ditto",["-c","-k","--keepParent",package.path,destination.path])
                guard zipped.code == 0 else { throw NSError(domain:"BooxSettings",code:Int(zipped.code),userInfo:[NSLocalizedDescriptionKey:zipped.output]) }
                try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:destination.path)
                try? FileManager.default.removeItem(at:package)
                DispatchQueue.main.async { self.notify("KOReader setup package saved. It contains your Calibre password; delete it after use.") }
            } catch { DispatchQueue.main.async { self?.notify("Could not create setup package: \(error.localizedDescription)") } }
        }
    }

    private func makeBooxSettingsPackage(existing:URL?=nil) throws -> URL {
        let fm=FileManager.default
        let root=fm.temporaryDirectory.appendingPathComponent("KOReaderCalibreSetup-\(UUID().uuidString)",isDirectory:true)
        let source=root.appendingPathComponent("existing",isDirectory:true)
        let koreader=root.appendingPathComponent("koreader",isDirectory:true)
        let output=koreader.appendingPathComponent("settings",isDirectory:true)
        try fm.createDirectory(at:source,withIntermediateDirectories:true)
        let values=try booxSettingsValues()
        let json=try JSONSerialization.data(withJSONObject:values)
        guard let input=String(data:json,encoding:.utf8) else { throw NSError(domain:"BooxSettings",code:1,userInfo:[NSLocalizedDescriptionKey:"Could not encode setup values."]) }
        let helper=Bundle.main.resourceURL?.appendingPathComponent("boox_settings.py").path ?? "\(home)/Shelf/boox_settings.py"
        let merged=Self.run("/usr/bin/python3",[helper,source.path,output.path],input:input)
        guard merged.code == 0 else { try? fm.removeItem(at:root); throw NSError(domain:"BooxSettings",code:Int(merged.code),userInfo:[NSLocalizedDescriptionKey:merged.output]) }
        // KOReader stores the active plugin files in settings/, but its older
        // monolithic reader configuration lives beside that directory.
        let legacyInSettings=output.appendingPathComponent("settings.reader.lua")
        let legacyAtRoot=koreader.appendingPathComponent("settings.reader.lua")
        try fm.moveItem(at:legacyInSettings,to:legacyAtRoot)
        let ip=values["lan_ip"] ?? ""
        let readme="""
        KOReader Calibre setup

        Copy the included files to the matching locations under the tablet's koreader folder while KOReader is closed: settings/opds.lua and settings/kosync.lua go in koreader/settings; settings.reader.lua goes directly in koreader. Keep a copy of the existing settings first. This package contains the Calibre server password. Delete it securely after setup.

        For automatic rotation, enable Android Auto-rotate and, while KOReader is active, open BOOX E-Ink Center > Optimize > Others > Force to follow system orientation.

        Calibre OPDS: http://\(ip):8080/opds
        KOReader Sync: http://\(ip):17200
        Username: \(username)
        """
        try readme.write(to:root.appendingPathComponent("README.txt"),atomically:true,encoding:.utf8)
        return root
    }

    private func booxSettingsValues() throws -> [String:String] {
        let password=serverPassword()
        guard !password.isEmpty else { throw NSError(domain:"BooxSettings",code:2,userInfo:[NSLocalizedDescriptionKey:"The Calibre server password file is empty or unavailable."]) }
        let key=syncAuthKey()
        guard key.range(of:#"^[a-fA-F0-9]{32}$"#,options:.regularExpression) != nil else { throw NSError(domain:"BooxSettings",code:3,userInfo:[NSLocalizedDescriptionKey:"KOReader Sync is unavailable or the saved user key could not be read."]) }
        let raw=Self.run("/sbin/ifconfig",["en0"]).output
        let ip=Self.capture(#"inet (\d+\.\d+\.\d+\.\d+)"#,raw) ?? ""
        guard !ip.isEmpty, !ip.hasPrefix("127.") else { throw NSError(domain:"BooxSettings",code:4,userInfo:[NSLocalizedDescriptionKey:"Could not determine this Mac’s Wi-Fi address."]) }
        return ["lan_ip":ip,"opds_url":service("readerOpds",fallback:"http://\(ip):8080/opds"),"sync_url":service("readerSync",fallback:"http://\(ip):17200"),"username":username,"calibre_password":password,"kosync_userkey":key]
    }

    private func transferBooxSettings(serial:String) throws -> String {
        let adb=adbPath
        let check=Self.run(adb,["-s",serial,"shell","test","-d","/sdcard/koreader/settings"])
        let settingsPath=check.code == 0 ? "/sdcard/koreader/settings" : "/storage/emulated/0/koreader/settings"
        let koreaderRoot=String(settingsPath.dropLast("/settings".count))
        let legacyReaderPath="\(koreaderRoot)/settings.reader.lua"
        let exists=Self.run(adb,["-s",serial,"shell","test","-d",settingsPath])
        guard exists.code == 0 else { throw NSError(domain:"BooxSettings",code:5,userInfo:[NSLocalizedDescriptionKey:"KOReader settings folder was not found. Open KOReader once on the tablet, close it, then retry."]) }
        let running=Self.run(adb,["-s",serial,"shell","pidof","org.koreader.launcher"])
        if running.code == 0 && !running.output.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty { throw NSError(domain:"BooxSettings",code:6,userInfo:[NSLocalizedDescriptionKey:"KOReader is running. Close it on the BOOX and retry so its settings are not overwritten from memory."]) }
        let root=FileManager.default.temporaryDirectory.appendingPathComponent("BOOXTransfer-\(UUID().uuidString)",isDirectory:true)
        defer { try? FileManager.default.removeItem(at:root) }
        let existing=root.appendingPathComponent("existing",isDirectory:true)
        let output=root.appendingPathComponent("merged",isDirectory:true)
        try FileManager.default.createDirectory(at:existing,withIntermediateDirectories:true)
        for name in ["opds.lua","kosync.lua"] {
            let remote="\(settingsPath)/\(name)"
            if Self.run(adb,["-s",serial,"shell","test","-f",remote]).code == 0 {
                let pulled=Self.run(adb,["-s",serial,"pull",remote,existing.appendingPathComponent(name).path])
                guard pulled.code == 0 else { throw NSError(domain:"BooxSettings",code:7,userInfo:[NSLocalizedDescriptionKey:"Could not safely back up existing \(name): \(pulled.output)"]) }
            }
        }
        if Self.run(adb,["-s",serial,"shell","test","-f",legacyReaderPath]).code == 0 {
            let pulled=Self.run(adb,["-s",serial,"pull",legacyReaderPath,existing.appendingPathComponent("settings.reader.lua").path])
            guard pulled.code == 0 else { throw NSError(domain:"BooxSettings",code:7,userInfo:[NSLocalizedDescriptionKey:"Could not safely back up the legacy KOReader settings file: \(pulled.output)"]) }
        }
        let values=try booxSettingsValues()
        guard let json=String(data:try JSONSerialization.data(withJSONObject:values),encoding:.utf8) else { throw NSError(domain:"BooxSettings",code:8,userInfo:[NSLocalizedDescriptionKey:"Could not encode settings."]) }
        let helper=Bundle.main.resourceURL?.appendingPathComponent("boox_settings.py").path ?? "\(home)/Shelf/boox_settings.py"
        let merged=Self.run("/usr/bin/python3",[helper,existing.path,output.path],input:json)
        guard merged.code == 0 else { throw NSError(domain:"BooxSettings",code:Int(merged.code),userInfo:[NSLocalizedDescriptionKey:merged.output]) }
        let stamp=ISO8601DateFormatter().string(from:Date()).replacingOccurrences(of:":",with:"-")
        let backup="\(settingsPath)/.calibre-stack-backup-\(stamp)"
        let mkdir=Self.run(adb,["-s",serial,"shell","mkdir","-p",backup])
        guard mkdir.code == 0 else { throw NSError(domain:"BooxSettings",code:9,userInfo:[NSLocalizedDescriptionKey:"Could not create tablet backup folder."]) }
        var existed=Set<String>()
        for name in ["opds.lua","kosync.lua"] where FileManager.default.fileExists(atPath:existing.appendingPathComponent(name).path) {
            existed.insert(name)
            let cp=Self.run(adb,["-s",serial,"shell","cp","\(settingsPath)/\(name)","\(backup)/\(name)"])
            guard cp.code == 0 else { throw NSError(domain:"BooxSettings",code:10,userInfo:[NSLocalizedDescriptionKey:"Could not back up tablet file \(name). No settings were changed."]) }
        }
        if existed.contains("settings.reader.lua") {
            let cp=Self.run(adb,["-s",serial,"shell","cp",legacyReaderPath,"\(backup)/settings.reader.lua"])
            guard cp.code == 0 else { throw NSError(domain:"BooxSettings",code:10,userInfo:[NSLocalizedDescriptionKey:"Could not back up the legacy KOReader settings file. No settings were changed."]) }
        }
        let oldRotation=Self.run(adb,["-s",serial,"shell","settings","get","system","accelerometer_rotation"]).output.trimmingCharacters(in:.whitespacesAndNewlines)
        if ["0","1"].contains(oldRotation) {
            let rotationBackup=root.appendingPathComponent("accelerometer_rotation.txt")
            try (oldRotation+"\n").write(to:rotationBackup,atomically:true,encoding:.utf8)
            let pushed=Self.run(adb,["-s",serial,"push",rotationBackup.path,"\(backup)/accelerometer_rotation.txt"])
            guard pushed.code == 0 else { throw NSError(domain:"BooxSettings",code:13,userInfo:[NSLocalizedDescriptionKey:"Could not back up Android's auto-rotate setting."]) }
        }
        for name in ["opds.lua","kosync.lua","settings.reader.lua"] {
            let destination=name == "settings.reader.lua" ? legacyReaderPath : "\(settingsPath)/\(name)"
            let pushed=Self.run(adb,["-s",serial,"push",output.appendingPathComponent(name).path,destination])
            if pushed.code != 0 {
                restoreBooxSettings(adb:adb,serial:serial,settingsPath:settingsPath,legacyReaderPath:legacyReaderPath,backup:backup,existed:existed)
                throw NSError(domain:"BooxSettings",code:11,userInfo:[NSLocalizedDescriptionKey:"Transfer failed while writing \(name); previous files were restored where possible."])
            }
        }
        let verify=root.appendingPathComponent("verify",isDirectory:true)
        try FileManager.default.createDirectory(at:verify,withIntermediateDirectories:true)
        for name in ["opds.lua","kosync.lua","settings.reader.lua"] {
            let source=name == "settings.reader.lua" ? legacyReaderPath : "\(settingsPath)/\(name)"
            let pulled=Self.run(adb,["-s",serial,"pull",source,verify.appendingPathComponent(name).path])
            let original=try Data(contentsOf:output.appendingPathComponent(name))
            let received=try? Data(contentsOf:verify.appendingPathComponent(name))
            if pulled.code != 0 || received != original {
                restoreBooxSettings(adb:adb,serial:serial,settingsPath:settingsPath,legacyReaderPath:legacyReaderPath,backup:backup,existed:existed)
                throw NSError(domain:"BooxSettings",code:12,userInfo:[NSLocalizedDescriptionKey:"The tablet did not verify \(name) after transfer; previous settings were restored where possible."])
            }
        }
        let rotationHelper=Bundle.main.resourceURL?.appendingPathComponent("boox_rotation.py").path ?? "\(home)/Shelf/boox_rotation.py"
        let rotation=Self.run("/usr/bin/python3",[rotationHelper,adb,serial])
        guard rotation.code == 0 else {
            throw NSError(domain:"BooxSettings",code:14,userInfo:[NSLocalizedDescriptionKey:"Calibre OPDS and KOReader Sync were transferred successfully, but automatic rotation could not be enabled: \(rotation.output.trimmingCharacters(in:.whitespacesAndNewlines).suffix(220))"])
        }
        return "BOOX setup complete: Calibre OPDS, KOReader Sync, and automatic rotation are enabled. Backups are in \(backup). KOReader is open; verify rotation by turning the tablet."
    }

    private func restoreBooxSettings(adb:String,serial:String,settingsPath:String,legacyReaderPath:String,backup:String,existed:Set<String>) {
        for file in ["opds.lua","kosync.lua"] {
            if existed.contains(file) { _=Self.run(adb,["-s",serial,"shell","cp","\(backup)/\(file)","\(settingsPath)/\(file)"]) }
            else { _=Self.run(adb,["-s",serial,"shell","rm","-f","\(settingsPath)/\(file)"]) }
        }
        if existed.contains("settings.reader.lua") { _=Self.run(adb,["-s",serial,"shell","cp","\(backup)/settings.reader.lua",legacyReaderPath]) }
        else { _=Self.run(adb,["-s",serial,"shell","rm","-f",legacyReaderPath]) }
    }

    private func adbDevices() -> [String] {
        let result=Self.run(adbPath,["devices"])
        guard result.code == 0 else { return [] }
        return result.output.components(separatedBy:.newlines).compactMap { line in
            let fields=line.split(whereSeparator: { $0.isWhitespace })
            guard fields.count >= 2, fields[1] == "device" else { return nil }
            return String(fields[0])
        }
    }


    private func exportDiagnostics(_ additionalText:String) {
        let panel=NSSavePanel()
        panel.title="Export Shelf diagnostics"
        panel.message="Creates a local ZIP of redacted logs, errors, service state, launch settings, and scripts. Nothing is uploaded."
        panel.directoryURL=URL(fileURLWithPath:"\(home)/Downloads",isDirectory:true)
        panel.nameFieldStringValue="Calibre-Stack-Diagnostics-\(ISO8601DateFormatter().string(from:Date()).replacingOccurrences(of:":",with:"-")).zip"
        panel.allowedContentTypes=[.zip]
        panel.canCreateDirectories=true
        guard panel.runModal() == .OK, let destination=panel.url else { return }
        notify("Collecting and redacting logs…")
        DispatchQueue.global(qos:.userInitiated).async { [weak self] in
            guard let self else { return }
            do {
                let result=try self.createDiagnosticBundle(at:destination,additionalText:additionalText)
                DispatchQueue.main.async { self.notify("Export ready: \(result.logs) logs · \(result.errors) error lines · \(result.scripts) scripts") }
            } catch {
                DispatchQueue.main.async { self.notify("Export failed: \(error.localizedDescription)") }
            }
        }
    }

    private func createDiagnosticBundle(at destination:URL,additionalText:String) throws -> (logs:Int,errors:Int,scripts:Int) {
        let fm=FileManager.default
        let root=fm.temporaryDirectory.appendingPathComponent("CalibreStackDiagnostics-\(UUID().uuidString)",isDirectory:true)
        defer { try? fm.removeItem(at:root) }
        let logsOut=root.appendingPathComponent("logs",isDirectory:true)
        let scriptsOut=root.appendingPathComponent("scripts",isDirectory:true)
        let agentsOut=root.appendingPathComponent("launch-agents",isDirectory:true)
        try fm.createDirectory(at:logsOut,withIntermediateDirectories:true)
        try fm.createDirectory(at:scriptsOut,withIntermediateDirectories:true)
        try fm.createDirectory(at:agentsOut,withIntermediateDirectories:true)

        let state=readDashboard()
        let stateData=try JSONSerialization.data(withJSONObject:state,options:[.prettyPrinted,.sortedKeys])
        try stateData.write(to:root.appendingPathComponent("dashboard-state.json"),options:.atomic)
        let environment="""
        Shelf diagnostic export
        Created: \(ISO8601DateFormatter().string(from:Date()))
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Architecture: \(Self.run("/usr/bin/uname",["-m"]).output.trimmingCharacters(in:.whitespacesAndNewlines))
        Hostname: \(Host.current().localizedName ?? "unknown")
        Library: \(libraryPath)
        Import folder: \(importPath)

        Contents: all top-level .log files from ~/Books/logs (redacted), extracted error lines,
        current dashboard state, related scripts, and matching launch-agent plists.
        Passwords, auth values, tokens, and secret fields are redacted. The bundle is created locally;
        it is not sent to an LLM or any other service.
        """
        try environment.write(to:root.appendingPathComponent("README.txt"),atomically:true,encoding:.utf8)

        let logDirectory=URL(fileURLWithPath:logsPath,isDirectory:true)
        let logFiles=(try? fm.contentsOfDirectory(at:logDirectory,includingPropertiesForKeys:nil))?.filter { $0.pathExtension.caseInsensitiveCompare("log") == .orderedSame }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending } ?? []
        let matcher=try NSRegularExpression(pattern:#"(?i)\b(error|failed|failure|fatal|exception|traceback|interruptederror|permission denied|operation not permitted)\b|already running"#)
        var errorLines=[String]()
        for file in logFiles {
            do {
                let clean=redact(try String(contentsOf:file,encoding:.utf8))
                try clean.write(to:logsOut.appendingPathComponent(file.lastPathComponent),atomically:true,encoding:.utf8)
                for (index,line) in clean.components(separatedBy:.newlines).enumerated() where !line.isEmpty {
                    if matcher.firstMatch(in:line,range:NSRange(line.startIndex...,in:line)) != nil {
                        errorLines.append("\(file.lastPathComponent):\(index+1): \(line)")
                    }
                }
            } catch {
                errorLines.append("EXPORT ERROR: Could not read \(file.lastPathComponent): \(error.localizedDescription)")
            }
        }
        try errorLines.joined(separator:"\n").write(to:root.appendingPathComponent("ERRORS.txt"),atomically:true,encoding:.utf8)
        if !additionalText.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty {
            let limit=1_000_000
            let clipped=additionalText.count>limit ? String(additionalText.prefix(limit))+"\n[truncated at 1 MB]" : additionalText
            try redact(clipped).write(to:root.appendingPathComponent("USER-REPORTED-OUTPUT.txt"),atomically:true,encoding:.utf8)
        }

        let scriptNames:Set<String>=[
            "calibre-smart-duplicate.py","calibre-duplicate-guard.py","calibre-duplicate-audit.py",
            "calibre-japanese-audit.py","calibre-malware-guard.py","calibre-malware-full-scan.sh",
            "calibre-restic-backup.sh","calibre-restic-launch.sh","kosync_calibre_bridge.py",
            "calibre-library-analyzer.py","calibre-library-analyzer.sh"
        ]
        var scriptCount=0
        for name in scriptNames.sorted() {
            let source=URL(fileURLWithPath:"\(scriptsPath)/\(name)")
            guard let body=try? String(contentsOf:source,encoding:.utf8) else { continue }
            try redact(body).write(to:scriptsOut.appendingPathComponent(name),atomically:true,encoding:.utf8)
            scriptCount += 1
        }

        let agentDirectory=URL(fileURLWithPath:"\(home)/Library/LaunchAgents",isDirectory:true)
        let agents=(try? fm.contentsOfDirectory(at:agentDirectory,includingPropertiesForKeys:nil))?.filter { url in
            let name=url.lastPathComponent
            return name.hasSuffix(".plist") && (name.contains("calibre") || name.contains("kosync") || name.contains("xteink"))
        } ?? []
        for agent in agents {
            guard let text=try? String(contentsOf:agent,encoding:.utf8) else { continue }
            try redact(text).write(to:agentsOut.appendingPathComponent(agent.lastPathComponent),atomically:true,encoding:.utf8)
        }

        let zip=Self.run("/usr/bin/ditto",["-c","-k","--sequesterRsrc","--keepParent",root.path,destination.path])
        guard zip.code==0 else { throw NSError(domain:"CalibreStackDiagnostics",code:Int(zip.code),userInfo:[NSLocalizedDescriptionKey:zip.output]) }
        return (logFiles.count,errorLines.count,scriptCount)
    }

    private func notify(_ text:String) { send("dashboardNotice",["message":text]) }
    private func send(_ function:String,_ value:[String:Any]) {
        guard JSONSerialization.isValidJSONObject(value), let data=try? JSONSerialization.data(withJSONObject:value,options:[.fragmentsAllowed]), let json=String(data:data,encoding:.utf8) else { return }
        webView.evaluateJavaScript("window.\(function)(\(json));",completionHandler:nil)
    }

    private func launchInfo(_ service:String)->(pid:Int?,lastExit:Int?) {
        let result=Self.run("/bin/launchctl",["print",service])
        let pid=Self.capture(#"(?m)^\s*pid = (\d+)"#,result.output).flatMap(Int.init)
        let exit=Self.capture(#"(?m)^\s*last exit code = (\d+)"#,result.output).flatMap(Int.init)
        return (pid,exit)
    }

    private func container(_ name:String)->(exists:Bool,healthy:Bool,health:String,uptime:String) {
        let r=Self.run(dockerPath,["inspect","--format","{{.State.Status}}|{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}|{{.State.StartedAt}}",name])
        guard r.code==0 else { return (false,false,"stopped","Not running") }
        let p=r.output.trimmingCharacters(in:.whitespacesAndNewlines).split(separator:"|",omittingEmptySubsequences:false).map(String.init)
        let active=p.first == "running", h=p.count>1 ? p[1] : "unknown"
        let dateFormatter=ISO8601DateFormatter(); dateFormatter.formatOptions=[.withInternetDateTime,.withFractionalSeconds]
        let started=p.count>2 ? (dateFormatter.date(from:p[2]) ?? ISO8601DateFormatter().date(from:p[2])) : nil
        let age=started.map { formatUptime(Date().timeIntervalSince($0)) } ?? "Unknown"
        return (active,active && (h=="healthy" || h=="none"),h,age)
    }

    private func formatUptime(_ seconds:TimeInterval)->String {
        let days=Int(seconds/86400), hours=Int(seconds.truncatingRemainder(dividingBy:86400)/3600), minutes=Int(seconds.truncatingRemainder(dividingBy:3600)/60)
        if days>0 { return "\(days)d \(hours)h" }
        if hours>0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }

    private func httpStatus(_ url:String,auth:Bool)->String? {
        var args=["--silent","--show-error","--max-time","5","--output","/dev/null","--write-out","%{http_code}"]
        if url.hasPrefix("https://") { args.append("--insecure") }
        if url.contains("/healthcheck") { args += ["--header","Accept: application/vnd.koreader.v1+json"] }
        if auth { args += ["--config","-"] }
        args.append(url)
        let input:String?
        if auth, let password=Optional(serverPassword()),!password.isEmpty {
            let p=password.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\"",with:"\\\"")
            input="user = \"\(username):\(p)\"\n"
        } else { input=nil }
        let r=Self.run("/usr/bin/curl",args,input:input)
        return r.code==0 ? r.output.trimmingCharacters(in:.whitespacesAndNewlines) : nil
    }

    private func processUptime(_ pid:Int)->String {
        let r=Self.run("/bin/ps",["-p",String(pid),"-o","etime="])
        let raw=r.output.trimmingCharacters(in:.whitespacesAndNewlines)
        if let match=try? NSRegularExpression(pattern:#"(?:(\d+)-)?(\d{1,2}):(\d{2}):(\d{2})"#),
           let result=match.firstMatch(in:raw,range:NSRange(raw.startIndex...,in:raw)) {
            func part(_ index:Int)->Int { guard let range=Range(result.range(at:index),in:raw) else{return 0};return Int(raw[range]) ?? 0 }
            let days=part(1),hours=part(2),minutes=part(3)
            return days>0 ? "\(days)d \(hours)h \(minutes)m" : "\(hours)h \(minutes)m"
        }
        return raw+" running"
    }

    private func fileModified(_ path:String)->Date? {
        (try? FileManager.default.attributesOfItem(atPath:path)[.modificationDate]) as? Date
    }

    private func tail(_ path:String,lines:Int)->[String] {
        guard let handle=FileHandle(forReadingAtPath:path) else { return [] }
        defer { try? handle.close() }
        let size=(try? handle.seekToEnd()) ?? 0, count=min(size,1_000_000)
        try? handle.seek(toOffset:size-count)
        return String(decoding:handle.readDataToEndOfFile(),as:UTF8.self).components(separatedBy:.newlines).filter{!$0.isEmpty}.suffix(lines).map{$0}
    }

    private func eventLevel(_ line:String)->String? {
        if line.range(of:#"broken pipe|failed login attempt"#,options:.regularExpression.union(.caseInsensitive)) != nil { return "Warning" }
        if line.range(of:#"\b(error|failed|failure|fatal|exception|denied)\b"#,options:.regularExpression.union(.caseInsensitive)) != nil { return "Error" }
        if line.range(of:#"\b(warning|warn|unmatched|skipped)\b"#,options:.regularExpression.union(.caseInsensitive)) != nil { return "Warning" }
        return nil
    }

    private func redact(_ source:String)->String {
        source.components(separatedBy:.newlines).map { sourceLine in
            var line=sourceLine
            line=line.replacingOccurrences(of:#"(?i)((?:password|passwd|token|secret|authorization|api[_-]?key|x-auth-key)(?:[_-](?:file|command|hash))?[\"']?\s*[:=]\s*[\"']?)[^\"'\s,;}&]+"#,with:"$1[hidden]",options:.regularExpression)
            line=line.replacingOccurrences(of:#"(?i)((?:password|passwd|token|secret|authorization|api[_-]?key|x-auth-key)(?:[_-](?:file|command|hash))?\s+)[^\s,;]+"#,with:"$1[hidden]",options:.regularExpression)
            line=line.replacingOccurrences(of:#"(?i)([?&](?:password|passwd|token|secret|api[_-]?key)=)[^&\s]+"#,with:"$1[hidden]",options:.regularExpression)
            line=line.replacingOccurrences(of:#"(?i)(Basic\s+)[A-Za-z0-9+/=]+"#,with:"$1[hidden]",options:.regularExpression)
            line=line.replacingOccurrences(of:#"(?i)(Bearer\s+)[A-Za-z0-9._~+/=-]+"#,with:"$1[hidden]",options:.regularExpression)
            return line
        }.joined(separator:"\n")
    }

    private func eventDate(_ line:String)->Date? {
        guard let stamp=Self.capture(#"\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}:\d{2}"#,line) else { return nil }
        let f=DateFormatter(); f.locale=Locale(identifier:"en_US_POSIX"); f.timeZone=TimeZone.current
        f.dateFormat=stamp.contains("T") ? "yyyy-MM-dd'T'HH:mm:ss" : "yyyy-MM-dd HH:mm:ss"
        return f.date(from:stamp)
    }

    private func formatInterval(_ value:Double)->String {
        if value>=604800 { return "Every week" }
        if value>=86400 { return "Every day" }
        if value>=3600 { return "Every \(Int(value/3600))h" }
        return "Every \(Int(value/60))m"
    }

    private func relative(_ date:Date)->String { let f=RelativeDateTimeFormatter(); f.unitsStyle = .abbreviated; return f.localizedString(for:date,relativeTo:Date()) }
    private func iso(_ date:Date)->String { ISO8601DateFormatter().string(from:date) }
    private func md5(_ value:String)->String { let digest=Insecure.MD5.hash(data:Data(value.utf8)); return digest.map{String(format:"%02x",$0)}.joined() }

    private static func run(_ executable:String,_ args:[String],input:String?=nil)->(code:Int32,output:String) {
        let p=Process(); p.executableURL=URL(fileURLWithPath:executable); p.arguments=args
        let out=Pipe(),err=Pipe(); p.standardOutput=out;p.standardError=err
        var inputPipe:Pipe?
        if input != nil { let q=Pipe(); p.standardInput=q;inputPipe=q }
        do {
            try p.run()
            if let input,let inputPipe { inputPipe.fileHandleForWriting.write(Data(input.utf8));try? inputPipe.fileHandleForWriting.close() }
            let a=out.fileHandleForReading.readDataToEndOfFile(), b=err.fileHandleForReading.readDataToEndOfFile();p.waitUntilExit()
            return (p.terminationStatus,String(decoding:a+b,as:UTF8.self))
        } catch { return (127,error.localizedDescription) }
    }
    private static func capture(_ pattern:String,_ text:String)->String? {
        guard let re=try? NSRegularExpression(pattern:pattern),let m=re.firstMatch(in:text,range:NSRange(text.startIndex...,in:text)),m.numberOfRanges>1,let r=Range(m.range(at:1),in:text) else{return nil};return String(text[r])
    }
    private static func iso(_ date:Date)->String { ISO8601DateFormatter().string(from:date) }
}
