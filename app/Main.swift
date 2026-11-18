import AppKit
import WebKit
import ServiceManagement

final class QuickPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class StatusContents: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class AppDelegate: NSObject, NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate, NSWindowDelegate, NSPopoverDelegate {
    var window: NSWindow!
    var web: WKWebView!
    var previewRun: EngineRun?
    var previewToken = UUID()
    var info: VideoInfo?
    var infos:[String:VideoInfo]=[:]
    var metadataCache:[String:(Date,[String:Any])]=[:]
    var previewRuns:[ObjectIdentifier:EngineRun]=[:]
    var previewURLs:[ObjectIdentifier:String]=[:]
    var previewTokens:[ObjectIdentifier:UUID]=[:]
    var quickWeb:WKWebView?
    var quickPanel:QuickPanel?
    var updateRun:EngineRun?
    var updateBusy=false
    var startedQueue=false
    var quitting=false
    var lastSave=Date.distantPast
    var historyWarning:String?
    let support=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask).first!.appendingPathComponent("VideoIndir")
    var executionEngine:URL {
        let fast=tools.appendingPathComponent("yt-dlp-fast/yt-dlp_macos")
        return !UserDefaults.standard.bool(forKey:"useUpdatedEngine") && FileManager.default.fileExists(atPath:fast.path) ? fast : engine
    }
    var engine:URL { support.appendingPathComponent("engine/yt-dlp") }
    var history:URL {support.appendingPathComponent("history.json")}
    var jobs: [Job] = []
    var statusItem: NSStatusItem!
    let statusPercent = NSTextField(labelWithString:"")
    let completionPopover = NSPopover()
    var completionDismiss: DispatchWorkItem?
    var announcedJobs = Set<String>()
    var folder: URL = FileManager.default.urls(for:.downloadsDirectory,in:.userDomainMask).first!
    let resources = Bundle.main.resourceURL!
    var tools: URL { resources.appendingPathComponent("tools") }
    var baseArgs: [String] { ["--ignore-config","--no-playlist","--no-color","--socket-timeout","20","--retries","3","--fragment-retries","3","--extractor-retries","2","--js-runtimes","node:"+tools.appendingPathComponent("node").path,"--ffmpeg-location",tools.path,"--cache-dir",support.appendingPathComponent("cache").path] }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults:["showMenuBar":true,"resumeOnLaunch":true])
        prepareStorage()
        restoreJobs()
        if let saved = UserDefaults.standard.string(forKey:"downloadFolder"), FileManager.default.fileExists(atPath:saved) { folder=URL(fileURLWithPath:saved) }
        restoreFolderAccess()
        let menu = NSMenu()
        let appItem=NSMenuItem(); menu.addItem(appItem)
        let appMenu=NSMenu(); appItem.submenu=appMenu
        appMenu.addItem(withTitle:"Video İndir Hakkında",action:#selector(about),keyEquivalent:"")
        let settings=appMenu.addItem(withTitle:"Ayarlar…",action:#selector(showSettings),keyEquivalent:",");settings.target=self
        let quick=appMenu.addItem(withTitle:"Hızlı Paneli Aç",action:#selector(showQuickPanel),keyEquivalent:"");quick.target=self
        let updater=appMenu.addItem(withTitle:"Motoru Güncelle…",action:#selector(updateEngine),keyEquivalent:"");updater.target=self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle:"Video İndir’den Çık",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        let editItem=NSMenuItem();menu.addItem(editItem);let edit=NSMenu(title:"Düzen");editItem.submenu=edit
        for (title,action,key) in [("Geri Al","undo:","z"),("Kes","cut:","x"),("Kopyala","copy:","c"),("Yapıştır","paste:","v"),("Tümünü Seç","selectAll:","a")] { edit.addItem(withTitle:title,action:NSSelectorFromString(action),keyEquivalent:key) }
        NSApp.mainMenu=menu
        setupStatusItem()
        let config=WKWebViewConfiguration();config.userContentController.add(self,name:"native")
        web=WKWebView(frame:.zero,configuration:config);web.navigationDelegate=self
        window=NSWindow(contentRect:NSRect(x:0,y:0,width:780,height:620),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title="Video İndir"; window.minSize=NSSize(width:430,height:440);window.delegate=self;window.isReleasedWhenClosed=false
        window.contentView=web;window.center();window.setFrameAutosaveName("MainWindow")
        web.loadFileURL(resources.appendingPathComponent("ui/index.html"),allowingReadAccessTo:resources.appendingPathComponent("ui"))
        window.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
    }
    @objc func about() { NSApp.orderFrontStandardAboutPanel(options:[.applicationName:"Video İndir",.applicationVersion:"2.0.6",.credits:NSAttributedString(string:"YouTube, Instagram, X ve diğer desteklenen siteler.\nyt-dlp · FFmpeg · Node.js")]) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { if quickPanel?.isVisible == true {quickPanel?.makeKey()} else if !flag {showMainWindow()}; return true }
    @objc func showMainWindow() {
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true)
    }
    func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength:26)
        statusItem.isVisible=UserDefaults.standard.bool(forKey:"showMenuBar")
        statusPercent.isHidden=true
        if let button = statusItem.button {
            let icon = NSImage(systemSymbolName:"arrow.down.circle",accessibilityDescription:"Video İndir")
            icon?.isTemplate=true
            let contents=StatusContents();contents.translatesAutoresizingMaskIntoConstraints=false
            let image=NSImageView();image.image=icon;image.translatesAutoresizingMaskIntoConstraints=false
            image.symbolConfiguration=NSImage.SymbolConfiguration(pointSize:16,weight:.regular)
            image.imageScaling = .scaleProportionallyUpOrDown
            statusPercent.translatesAutoresizingMaskIntoConstraints=false
            statusPercent.font = .monospacedDigitSystemFont(ofSize:12,weight:.medium)
            statusPercent.textColor = .labelColor;statusPercent.alignment = .left
            contents.addSubview(image);contents.addSubview(statusPercent);button.addSubview(contents)
            NSLayoutConstraint.activate([
                contents.leadingAnchor.constraint(equalTo:button.leadingAnchor),contents.trailingAnchor.constraint(equalTo:button.trailingAnchor),
                contents.topAnchor.constraint(equalTo:button.topAnchor),contents.bottomAnchor.constraint(equalTo:button.bottomAnchor),
                image.leadingAnchor.constraint(equalTo:contents.leadingAnchor,constant:4),image.centerYAnchor.constraint(equalTo:contents.centerYAnchor),
                image.widthAnchor.constraint(equalToConstant:18),image.heightAnchor.constraint(equalToConstant:18),
                statusPercent.leadingAnchor.constraint(equalTo:contents.leadingAnchor,constant:26),statusPercent.centerYAnchor.constraint(equalTo:contents.centerYAnchor),
                statusPercent.widthAnchor.constraint(equalToConstant:40)
            ])
            button.toolTip="Video İndir";button.target=self;button.action=#selector(statusClicked(_:))
            button.sendAction(on:[.leftMouseUp,.rightMouseUp])
        }
        let controller=NSViewController();controller.view=NSView(frame:NSRect(x:0,y:0,width:112,height:46))
        let check=NSImageView(image:NSImage(systemSymbolName:"checkmark.circle.fill",accessibilityDescription:"Tamamlandı")!)
        check.contentTintColor = .systemGreen
        let label=NSTextField(labelWithString:"Bitti");label.font = .systemFont(ofSize:14,weight:.medium)
        let stack=NSStackView(views:[check,label]);stack.orientation = .horizontal;stack.alignment = .centerY;stack.spacing=8;stack.translatesAutoresizingMaskIntoConstraints=false
        controller.view.addSubview(stack)
        NSLayoutConstraint.activate([stack.centerXAnchor.constraint(equalTo:controller.view.centerXAnchor),stack.centerYAnchor.constraint(equalTo:controller.view.centerYAnchor),check.widthAnchor.constraint(equalToConstant:18),check.heightAnchor.constraint(equalToConstant:18)])
        completionPopover.contentViewController=controller;completionPopover.contentSize=NSSize(width:112,height:46)
        completionPopover.behavior = .transient;completionPopover.animates=false;completionPopover.delegate=self
    }
    @objc func statusClicked(_ sender:Any?) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            let menu=NSMenu()
            let show=menu.addItem(withTitle:"Video İndir’i Aç",action:#selector(showMainWindow),keyEquivalent:"");show.target=self
            menu.addItem(.separator())
            menu.addItem(withTitle:"Çık",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"")
            statusItem.menu=menu;statusItem.button?.performClick(nil);statusItem.menu=nil
        } else { completionPopover.performClose(nil);showQuickPanel() }
    }
    func updateStatus(_ payload:[String:Any]) {
        guard let button=statusItem.button else{return}
        let completedID = payload["state"] as? String == "done" ? payload["id"] as? String : nil
        let willShowCompletion = completedID.map { !announcedJobs.contains($0) } ?? false
        if let active=jobs.first(where:{$0.state=="downloading"}) {
            statusItem.length=68;statusPercent.isHidden=false
            statusPercent.stringValue=active.isPreparing ? "…" : "\(min(99,max(0,Int(active.percent))))%"
            button.toolTip="\(active.info.title) — \(active.detail)"
        } else {
            statusPercent.stringValue="";statusPercent.isHidden=true;button.toolTip="Video İndir"
            if !completionPopover.isShown && quickPanel?.isVisible != true && !willShowCompletion { statusItem.length=26 }
        }
        if payload["state"] as? String == "done",let id=payload["id"] as? String,announcedJobs.insert(id).inserted {
            completionDismiss?.cancel()
            if statusItem.isVisible && quickPanel?.isVisible != true { completionPopover.show(relativeTo:NSRect(x:4,y:0,width:18,height:button.bounds.height),of:button,preferredEdge:.minY) } else { send("completed",[:],to:quickWeb) }
            let dismiss=DispatchWorkItem { [weak self] in self?.completionPopover.performClose(nil) }
            completionDismiss=dismiss;DispatchQueue.main.asyncAfter(deadline:.now()+5,execute:dismiss)
        }
    }
    func popoverDidClose(_ notification:Notification) { updateStatus([:]) }
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply {
        if updateBusy {let alert=NSAlert();alert.messageText="Motor güncellemesi sürüyor";alert.informativeText="Güncelleme bittikten sonra çıkabilirsin.";alert.runModal();return .terminateCancel}
        quitting=true
        previewRuns.values.forEach{$0.cancel()}
        persistJobs(force:true)
        let running=jobs.compactMap{$0.run}
        if running.isEmpty {return .terminateNow}
        running.forEach{$0.cancel()}
        return .terminateLater
    }
    func finishQuitIfReady() {
        if quitting && jobs.allSatisfy({$0.run==nil}) {persistJobs(force:true);NSApp.reply(toApplicationShouldTerminate:true)}
    }
    func webView(_ webView:WKWebView,decidePolicyFor navigationAction:WKNavigationAction,decisionHandler:@escaping(WKNavigationActionPolicy)->Void) {
        let allowed=navigationAction.request.url?.isFileURL == true && navigationAction.request.url?.standardizedFileURL.path.hasPrefix(resources.appendingPathComponent("ui").path+"/") == true
        decisionHandler(allowed ? .allow : .cancel)
    }
    func send(_ type:String,_ payload:[String:Any],to target:WKWebView?=nil) {
        DispatchQueue.main.async {
            if type=="job" {self.updateStatus(payload);self.persistJobs(force:payload["state"] as? String != "downloading")}
            guard let data=try? JSONSerialization.data(withJSONObject:["type":type,"data":payload]),let json=String(data:data,encoding:.utf8) else{return}
            let views=target.map{[$0]} ?? [self.web,self.quickWeb].compactMap{$0}
            for view in views {view.evaluateJavaScript("window.receiveNative(\(json))",completionHandler:nil)}
        }
    }
    func validURL(_ raw:String)->String? {
        guard let url=URL(string:raw.trimmingCharacters(in:.whitespacesAndNewlines)),["https","http"].contains(url.scheme?.lowercased() ?? ""),url.host != nil,url.user == nil,url.password == nil else{return nil}
        return url.absoluteString
    }
    func userContentController(_ controller:WKUserContentController,didReceive message:WKScriptMessage) {
        guard message.frameInfo.isMainFrame,let body=message.body as? [String:Any],let action=body["action"] as? String else{return}
        let target=message.webView ?? web!
        switch action {
        case "ready":
            sendSettings(to:target)
            send("folder",["name":folder.lastPathComponent,"path":folder.path],to:target)
            send("history",["jobs":jobs.map{$0.json}],to:target)
            if let warning=historyWarning {send("error",["message":warning],to:target)}
            if target === web && !UserDefaults.standard.bool(forKey:"folderAccessConfigured") {
                send("openSettings",[:],to:target)
                send("settingsMessage",["message":"İlk kurulum: Kayıt klasörünün yanındaki Değiştir ile videoların kaydedileceği klasörü seç. Yalnızca bu klasöre erişim gerekir. Başlangıçta çalıştır isteğe bağlıdır."],to:target)
            }
            if !startedQueue {startedQueue=true;startNext()}
        case "preview":
            if let raw=body["url"] as? String,let url=validURL(raw) {preview(url,to:target)} else {send("error",["message":"Geçerli bir video bağlantısı gir."],to:target)}
        case "collection":
            let urls=body["urls"] as? [String] ?? []
            if body["playlist"] as? Bool == true,let url=urls.first.flatMap({validURL($0)}) {loadPlaylist(url,to:target)}
            else {
                var seen=Set<String>();let valid=urls.compactMap{validURL($0)}.filter{seen.insert($0).inserted}
                guard valid.count==urls.count else{send("error",["message":"Geçersiz veya tekrar eden bağlantıları kaldır."],to:target);return}
                send("collection",["entries":valid.map{["url":$0,"title":$0]},"title":"Bağlantılar","limited":false],to:target)
            }
        case "download", "downloadMany":
            guard UserDefaults.standard.bool(forKey:"folderAccessConfigured") else {
                showSettings();send("settingsMessage",["message":"İndirmeden önce Değiştir düğmesiyle kayıt klasörünü seçerek erişim ver."]);return
            }
            guard let mode=OutputMode(rawValue:body["mode"] as? String ?? "original") else{return}
            if action=="download",let raw=body["url"] as? String,let url=validURL(raw),let info=infos[url] {
                let height=mode.isAudio ? nil : body["height"] as? Int
                if let h=height,!info.heights.contains(h){send("error",["message":"Çözünürlük videoda bulunmuyor."],to:target);return}
                if mode.isAudio && !info.hasAudio {send("error",["message":"Bu videoda indirilebilir ses bulunamadı."],to:target);return}
                enqueue(info:info,height:height,mode:mode)
            } else if action=="downloadMany",let entries=body["entries"] as? [[String:String]],!entries.isEmpty {
                for entry in entries {if let raw=entry["url"],let url=validURL(raw) {enqueue(info:infos[url] ?? .pending(url:url,title:entry["title"]),height:nil,mode:mode,start:false)}}
                startNext()
            } else {send("error",["message":"Önce bağlantının önizlemesini getir."],to:target)}
        case "clearHistory":clearHistory()
        case "folder":
            chooseDownloadFolder()
        case "cancel":
            if let id=body["id"] as? String,let job=jobs.first(where:{$0.id==id}) {
                if job.state=="queued" {job.state="cancelled";job.detail="İptal edildi";send("job",job.json)}
                else if job.state=="downloading" {job.detail="İptal ediliyor…";send("job",job.json);job.run?.cancel()}
            }
        case "retry":
            if let id=body["id"] as? String,let job=jobs.first(where:{$0.id==id}),["failed","cancelled","paused"].contains(job.state) {job.state="queued";job.detail="Sırada";send("job",job.json);startNext()}
        case "reveal":
            if let id=body["id"] as? String,let job=jobs.first(where:{$0.id==id}),job.state=="done",!job.path.isEmpty {
                if FileManager.default.fileExists(atPath:job.path){NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:job.path)])}else{send("error",["message":"Dosya taşınmış veya silinmiş."],to:target)}
            }
        case "showMain":closeQuickPanel();showMainWindow()
        case "update":updateEngine()
        case "openSettings":showSettings()
        case "settings":sendSettings(to:target)
        case "setting":
            if let key=body["key"] as? String,let enabled=body["value"] as? Bool {changeSetting(key,enabled:enabled,to:target)}
        case "loginApproval":SMAppService.openSystemSettingsLoginItems()
        default:break
        }
    }
    func friendly(_ message:String)->String {
        let lower=message.lowercased()
        if lower.contains("sign in") || lower.contains("login") || lower.contains("cookies") {return "Bu içerik oturum açmayı gerektiriyor veya platform erişimi sınırladı. Herkese açık başka bir bağlantı dene."}
        if lower.contains("unsupported url") {return "Bu bağlantı desteklenmiyor. Videonun doğrudan paylaşım bağlantısını kullan."}
        if lower.contains("unavailable") || lower.contains("private") {return "Video kaldırılmış, gizli veya bu bağlantıdan erişilemiyor."}
        if lower.contains("403") {return "Platform indirmeye izin vermedi (403). Daha sonra tekrar dene."}
        if lower.contains("no space") {return "Diskte yeterli boş alan yok."}
        if lower.contains("permission denied") {return "Kayıt klasörüne yazılamıyor. Başka bir klasör seç."}
        return String(message.replacingOccurrences(of:"ERROR: ",with:"").prefix(600))
    }

}
@main
struct Launcher {
    static func main() {
        let app=NSApplication.shared
        let delegate=AppDelegate()
        app.delegate=delegate;app.setActivationPolicy(.regular);app.run()
        withExtendedLifetime(delegate) {}
    }
}
