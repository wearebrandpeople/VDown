import AppKit
import WebKit
import ServiceManagement

extension AppDelegate {
    func prepareStorage() {
        do {
            try FileManager.default.createDirectory(at:engine.deletingLastPathComponent(),withIntermediateDirectories:true)
            if !FileManager.default.fileExists(atPath:engine.path) {try FileManager.default.copyItem(at:tools.appendingPathComponent("yt-dlp"),to:engine)}
        } catch {historyWarning="Yerel uygulama verileri hazırlanamadı: "+error.localizedDescription}
    }
    func restoreJobs() {
        guard FileManager.default.fileExists(atPath:history.path) else{return}
        do {
            jobs=try JSONDecoder().decode([Job].self,from:Data(contentsOf:history))
            for job in jobs {
                loadCover(job)
                if job.state=="downloading" {job.state="queued";job.detail="Kaldığı yerden devam edecek"}
                if job.state=="queued" && !UserDefaults.standard.bool(forKey:"resumeOnLaunch") {job.state="paused";job.detail="Devam etmek için hazır"}
                if job.state=="done" {announcedJobs.insert(job.id)}
            }
        } catch {
            let backup=support.appendingPathComponent("history-unreadable-\(UUID().uuidString).json")
            try? FileManager.default.copyItem(at:history,to:backup)
            historyWarning="Geçmiş dosyası okunamadı; mevcut dosyanın yedeği saklandı."
        }
    }
    func persistJobs(force:Bool=false) {
        guard force || Date().timeIntervalSince(lastSave)>1 else{return}
        do {try JSONEncoder().encode(jobs).write(to:history,options:.atomic);lastSave=Date()}
        catch {if historyWarning==nil {historyWarning="İndirme geçmişi kaydedilemiyor: "+error.localizedDescription;send("error",["message":historyWarning!])}}
    }
    func loadCover(_ job:Job) {
        let directory=support.appendingPathComponent("covers")
        let file=directory.appendingPathComponent(job.id+".txt")
        if let cached=try? String(contentsOf:file,encoding:.utf8),cached.hasPrefix("data:image/") {job.coverDataURI=cached;return}
        guard let url=URL(string:job.info.thumbnail),["https","http"].contains(url.scheme ?? "") else{return}
        var request=URLRequest(url:url);request.timeoutInterval=15
        URLSession.shared.dataTask(with:request) {data,response,_ in
            guard let data=data,data.count<5_000_000,(response as? HTTPURLResponse)?.statusCode==200,
                  let mime=response?.mimeType,mime.hasPrefix("image/"),NSImage(data:data) != nil else{return}
            let value="data:"+mime+";base64,"+data.base64EncodedString()
            try? FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            try? value.write(to:file,atomically:true,encoding:.utf8)
            DispatchQueue.main.async {
                job.coverDataURI=value
                if self.jobs.contains(where:{$0.id==job.id}) {self.send("job",job.json)}
            }
        }.resume()
    }
    func clearHistory() {
        guard jobs.contains(where:{$0.canClearHistory}) else{return}
        // Keep an undo copy; this action never touches downloaded media.
        do {try JSONEncoder().encode(jobs).write(to:support.appendingPathComponent("history-before-clear.json"),options:.atomic)}
        catch {send("error",["message":"Geçmiş yedeklenemedi; temizlenmedi."]);return}
        jobs.removeAll(where:{$0.canClearHistory});persistJobs(force:true)
        send("history",["jobs":jobs.map{$0.json}])
    }
    func enqueue(info:VideoInfo,height:Int?,mode:OutputMode,start:Bool=true) {
        let job=Job(info:info,height:height,folder:folder,mode:mode)
        jobs.append(job);loadCover(job);send("job",job.json);persistJobs(force:true)
        if start {startNext()}
    }
    @objc func showQuickPanel() {
        DispatchQueue.main.async {self.presentQuickPanel()}
    }
    func presentQuickPanel() {
        guard let button=statusItem.button,let host=button.window else{return}
        if !statusItem.isVisible {showMainWindow();return}
        if quickPanel?.isVisible == true {closeQuickPanel();return}
        completionPopover.performClose(nil);statusItem.length=68;button.layoutSubtreeIfNeeded()
        if quickWeb==nil {
            let config=WKWebViewConfiguration();config.userContentController.add(self,name:"native")
            config.userContentController.addUserScript(WKUserScript(source:"window.isQuickPanel = true;",injectionTime:.atDocumentStart,forMainFrameOnly:true))
            let view=WKWebView(frame:NSRect(x:0,y:0,width:390,height:560),configuration:config);view.navigationDelegate=self;quickWeb=view
            let panel=QuickPanel(contentRect:view.bounds,styleMask:[.borderless],backing:.buffered,defer:false)
            panel.title="VDown — Hızlı panel";panel.level = .popUpMenu;panel.hasShadow=true;panel.isReleasedWhenClosed=false;panel.isFloatingPanel=true;panel.delegate=self
            panel.backgroundColor = .windowBackgroundColor;panel.contentView=view;view.wantsLayer=true;view.layer?.cornerRadius=12;view.layer?.masksToBounds=true
            quickPanel=panel
            view.loadFileURL(resources.appendingPathComponent("ui/index.html"),allowingReadAccessTo:resources.appendingPathComponent("ui"))
        }
        let anchor=host.convertToScreen(button.convert(button.bounds,to:nil))
        let screen=host.screen?.visibleFrame ?? NSScreen.main!.visibleFrame
        let x=min(max(anchor.midX-195,screen.minX+8),screen.maxX-398)
        quickPanel?.setFrameOrigin(NSPoint(x:x,y:max(screen.minY+8,anchor.minY-566)))
        NSApp.activate(ignoringOtherApps:true);quickPanel?.makeKeyAndOrderFront(nil);quickPanel?.makeMain()
    }
    func closeQuickPanel() {quickPanel?.orderOut(nil);updateStatus([:])}
    func windowDidResignKey(_ notification:Notification) {
        if let panel=quickPanel,notification.object as? NSWindow === panel {closeQuickPanel()}
    }
    func preview(_ url:String,to target:WKWebView) {
        guard !updateBusy else{send("error",["message":"Motor güncelleniyor; bitince tekrar dene."],to:target);return}
        let key=ObjectIdentifier(target)
        // Repeated clicks must not restart an extraction already in flight.
        if previewRuns[key] != nil,previewURLs[key]==url {return}
        previewRuns[key]?.cancel();previewRuns[key]=nil
        let token=UUID();previewTokens[key]=token;previewURLs[key]=url
        if let cached=metadataCache[MediaSource.sourceURL(url)],Date().timeIntervalSince(cached.0)<300 {
            presentPreview(cached.1,url:url,to:target);return
        }
        let run=EngineRun();previewRuns[key]=run;send("loading",[:],to:target)
        var result:[String:Any]?;var error="Video bilgileri alınamadı."
        run.start(executable:executionEngine,arguments:baseArgs+["--dump-single-json","--skip-download","--",MediaSource.sourceURL(url)],timeout:100,line:{line in
            if line.hasPrefix("{"),let d=line.data(using:.utf8),let object=(try? JSONSerialization.jsonObject(with:d)) as? [String:Any]{result=object}
            else if line.contains("ERROR:"){error=line}
        },done:{code,cancelled,timedOut in DispatchQueue.main.async {
            guard self.previewTokens[key]==token else{return};self.previewRuns[key]=nil
            guard !cancelled else{return}
            guard code==0,let data=result else{self.send("error",["message":timedOut ? "Bağlantı yanıt vermedi. Tekrar dene." : self.friendly(error)],to:target);return}
            self.metadataCache[MediaSource.sourceURL(url)]=(Date(),data)
            self.presentPreview(data,url:url,to:target)
        }})
    }
    func presentPreview(_ data:[String:Any],url:String,to target:WKWebView) {
            let children=MediaSource.videos(data)
            if !children.isEmpty && MediaSource.sourceURL(url)==url {
                let items=children.enumerated().map {index,child -> [String:String] in
                    let childURL=MediaSource.entryURL(url,id:child["id"] as! String)
                    let info=VideoInfo.parse(child,url:childURL);self.infos[childURL]=info
                    return ["url":childURL,"title":"\(index+1). \(info.title)"]
                }
                self.send("collection",["entries":items,"title":"Gönderideki videolar","limited":false,"sourceURL":url],to:target);return
            }
            guard let selected=MediaSource.selected(data,url:url) else{self.send("error",["message":"Seçilen video artık gönderide bulunamadı. Bağlantıyı yeniden önizle."],to:target);return}
            let info=VideoInfo.parse(selected,url:url)
            guard info.containsVideo || info.hasAudio else{self.send("error",["message":"İndirilebilir video veya ses bulunamadı."],to:target);return}
            self.infos[url]=info;self.send("preview",info.json,to:target)
    }

    func loadPlaylist(_ url:String,to target:WKWebView) {
        guard !updateBusy else{send("error",["message":"Motor güncelleniyor."],to:target);return}
        let key=ObjectIdentifier(target);previewRuns[key]?.cancel();previewURLs[key]=nil;let token=UUID();previewTokens[key]=token
        let run=EngineRun();previewRuns[key]=run;send("loading",["message":"Çalma listesi alınıyor…"],to:target)
        var result:[String:Any]?;var error="Çalma listesi alınamadı."
        let args=baseArgs.filter{$0 != "--no-playlist"}+["--yes-playlist","--flat-playlist","--playlist-end","500","--ignore-errors","--dump-single-json","--skip-download","--",url]
        run.start(executable:executionEngine,arguments:args,timeout:120,line:{line in
            if line.hasPrefix("{"),let d=line.data(using:.utf8){result=(try? JSONSerialization.jsonObject(with:d)) as? [String:Any]}
            if line.contains("ERROR:"){error=line}
        },done:{code,cancelled,timedOut in DispatchQueue.main.async {
            guard self.previewTokens[key]==token else{return};self.previewRuns[key]=nil
            guard !cancelled else{return}
            guard let result=result,let entries=result["entries"] as? [[String:Any]] else{self.send("error",["message":timedOut ? "Çalma listesi zaman aşımına uğradı." : self.friendly(error)],to:target);return}
            var seen=Set<String>()
            let items=entries.compactMap {entry->[String:String]? in
                var candidate=entry["webpage_url"] as? String ?? entry["url"] as? String ?? ""
                if self.validURL(candidate)==nil,(entry["ie_key"] as? String)=="Youtube",let id=entry["id"] as? String {candidate="https://www.youtube.com/watch?v="+id}
                guard let valid=self.validURL(candidate),seen.insert(valid).inserted else{return nil}
                return ["url":valid,"title":entry["title"] as? String ?? valid]
            }
            if items.isEmpty {self.send("error",["message":"Listede erişilebilir video bulunamadı."],to:target);return}
            self.send("collection",["entries":items,"title":result["title"] as? String ?? "Çalma listesi","limited":entries.count>=500,"sourceURL":url],to:target)
        }})
    }
    @objc func updateEngine() {
        guard !updateBusy else{return}
        guard !jobs.contains(where:{$0.state=="downloading"}),previewRuns.isEmpty else{send("update",["busy":false,"message":"Önizleme veya indirme sürüyor. Tamamlandıktan sonra güncelle."]);return}
        updateBusy=true;send("update",["busy":true,"message":"Motor güncellemeleri denetleniyor…"])
        let backup=engine.deletingLastPathComponent().appendingPathComponent("yt-dlp.backup")
        do {
            if FileManager.default.fileExists(atPath:backup.path){try FileManager.default.removeItem(at:backup)}
            try FileManager.default.copyItem(at:engine,to:backup)
        }catch{updateBusy=false;send("update",["busy":false,"message":"Güncelleme yedeği oluşturulamadı: "+error.localizedDescription]);return}
        let run=EngineRun();updateRun=run;var last="Motor güncel."
        run.start(executable:engine,arguments:["--ignore-config","--update-to","stable","--socket-timeout","20"],timeout:180,line:{line in if !line.isEmpty{last=line}},done:{code,cancelled,timedOut in DispatchQueue.main.async {
            if code != 0 || cancelled || timedOut {
                self.restoreEngine(backup);self.updateBusy=false;self.updateRun=nil;self.send("update",["busy":false,"message":"Güncelleme tamamlanamadı; önceki motor korundu. "+self.friendly(last)]);self.startNext();return
            }
            let verify=EngineRun();self.updateRun=verify;var version=""
            verify.start(executable:self.engine,arguments:["--version"],timeout:30,line:{version=$0},done:{result,_,_ in DispatchQueue.main.async {
                if result != 0 {self.restoreEngine(backup)}
                else {UserDefaults.standard.set(version.trimmingCharacters(in:.whitespacesAndNewlines) != "2026.10.26",forKey:"useUpdatedEngine")}
                self.updateBusy=false;self.updateRun=nil
                self.send("update",["busy":false,"message":result==0 ? "Motor güncel · "+version : "Yeni motor çalışmadı; önceki sürüme dönüldü."])
                self.startNext()
            }})
        }})
    }
    func restoreEngine(_ backup:URL) {
        do {let temp=engine.deletingLastPathComponent().appendingPathComponent(UUID().uuidString);try FileManager.default.copyItem(at:backup,to:temp);_ = try FileManager.default.replaceItemAt(engine,withItemAt:temp)}catch{send("error",["message":"Motor geri yüklenemedi: "+error.localizedDescription])}
    }
}

extension AppDelegate {
    @objc func showSettings() {closeQuickPanel();showMainWindow();sendSettings(to:web);send("openSettings",[:],to:web)}
    func sendSettings(to target:WKWebView) {
        let state=SMAppService.mainApp.status
        send("settings",["launchAtLogin":state == .enabled || state == .requiresApproval,"loginApproval":state == .requiresApproval,"loginStatus":loginStatusText(state),"showMenuBar":UserDefaults.standard.bool(forKey:"showMenuBar"),"resumeOnLaunch":UserDefaults.standard.bool(forKey:"resumeOnLaunch"),"folder":folder.path],to:target)
    }
    func changeSetting(_ key:String,enabled:Bool,to target:WKWebView) {
        do {
            switch key {
            case "launchAtLogin":
                if enabled {try SMAppService.mainApp.register()} else {try SMAppService.mainApp.unregister()}
            case "showMenuBar":
                UserDefaults.standard.set(enabled,forKey:key)
                if !enabled {closeQuickPanel();completionPopover.performClose(nil)}
                statusItem.isVisible=enabled
                if !enabled {showMainWindow()}
            case "resumeOnLaunch":UserDefaults.standard.set(enabled,forKey:key)
            default:return
            }
            send("settingsMessage",["message":"Kaydedildi."],to:target)
        } catch {send("settingsMessage",["message":"Ayar değiştirilemedi: "+error.localizedDescription],to:target)}
        sendSettings(to:target)
    }
}


extension AppDelegate {
    func loginStatusText(_ state:SMAppService.Status)->String {
        switch state {
        case .enabled:return "macOS giriş kaydı etkin."
        case .requiresApproval:return "macOS onayı bekleniyor. Sistem Ayarları’nda etkinleştir."
        case .notRegistered:return "Başlangıçta çalıştır kapalı."
        case .notFound:return "macOS uygulamayı bulamadı. Uygulamayı sabit konumundan açıp tekrar etkinleştir."
        @unknown default:return "macOS giriş kaydı durumu alınamadı."
        }
    }
    func applicationDidBecomeActive(_ notification:Notification) {
        guard web != nil else{return}
        sendSettings(to:web)
    }
    func restoreFolderAccess() {
        guard let data=UserDefaults.standard.data(forKey:"downloadFolderBookmark") else{return}
        do {
            var stale=false
            let url=try URL(resolvingBookmarkData:data,options:[],relativeTo:nil,bookmarkDataIsStale:&stale)
            guard FileManager.default.fileExists(atPath:url.path) else{throw CocoaError(.fileNoSuchFile)}
            folder=url
            if stale {UserDefaults.standard.set(try url.bookmarkData(options:[],includingResourceValuesForKeys:nil,relativeTo:nil),forKey:"downloadFolderBookmark")}
        } catch {UserDefaults.standard.set(false,forKey:"folderAccessConfigured")}
    }
    func chooseDownloadFolder() {
        closeQuickPanel();showMainWindow()
        let panel=NSOpenPanel();panel.canChooseFiles=false;panel.canChooseDirectories=true;panel.canCreateDirectories=true;panel.allowsMultipleSelection=false;panel.directoryURL=folder;panel.prompt="Seç"
        panel.message="Videoların kaydedileceği klasöre erişim ver."
        panel.beginSheetModal(for:window) {result in
            guard result == .OK,let url=panel.url else{return}
            do {
                try self.verifyFolderWrite(url)
                let bookmark=try url.bookmarkData(options:[],includingResourceValuesForKeys:nil,relativeTo:nil)
                self.folder=url
                UserDefaults.standard.set(bookmark,forKey:"downloadFolderBookmark")
                UserDefaults.standard.set(url.path,forKey:"downloadFolder")
                UserDefaults.standard.set(true,forKey:"folderAccessConfigured")
                self.send("folder",["name":url.lastPathComponent,"path":url.path])
                self.send("settingsMessage",["message":"Klasöre yazma erişimi doğrulandı. Hazır."])
            }catch{self.send("settingsMessage",["message":"Klasöre yazılamıyor. Başka bir klasör seç veya macOS Sistem Ayarları > Gizlilik ve Güvenlik > Dosyalar ve Klasörler bölümünü kontrol et."])}
        }
    }
    func verifyFolderWrite(_ url:URL) throws {
        let probe=url.appendingPathComponent(".video-indir-access-"+UUID().uuidString)
        try Data("Video Indir permission test".utf8).write(to:probe,options:.withoutOverwriting)
        defer {try? FileManager.default.removeItem(at:probe)}
        guard try Data(contentsOf:probe)==Data("Video Indir permission test".utf8) else{throw CocoaError(.fileReadCorruptFile)}
    }
}
