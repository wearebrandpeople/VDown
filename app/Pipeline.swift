import Foundation
import AppKit

extension AppDelegate {
    func startNext() {
        guard !quitting,!updateBusy,!jobs.contains(where:{$0.state=="downloading"}),let job=jobs.first(where:{$0.state=="queued"}) else{return}
        job.state="downloading";job.isPreparing=true;job.detail="Video bilgileri alınıyor…";job.percent=min(90,job.percent)
        send("job",job.json);persistJobs(force:true)
        if !job.path.isEmpty,FileManager.default.fileExists(atPath:job.path) {finish(job,state:"done",detail:"Tamamlandı");return}
        do {try verifyFolderWrite(job.folder);try FileManager.default.createDirectory(at:job.temporary,withIntermediateDirectories:true)}catch{finish(job,state:"failed",detail:"Kayıt klasörüne yazılamıyor. Ayarlar > Kayıt klasörü > Değiştir ile yeniden erişim ver; sonra Tekrar dene.");return}
        if let cached=metadataCache[MediaSource.sourceURL(job.info.url)],Date().timeIntervalSince(cached.0)<300 {
            prepareDownload(job,root:cached.1);return
        }
        let run=EngineRun();job.run=run
        var metadata:[String:Any]?;var error="Video bilgileri alınamadı."
        let args=baseArgs+["--format-sort-force","-S","res,fps,hdr:12,vcodec,br","-f",job.mode.format(height:job.height),"--dump-single-json","--skip-download","--",MediaSource.sourceURL(job.info.url)]
        run.start(executable:executionEngine,arguments:args,timeout:100,line:{line in
            if line.hasPrefix("{"),let data=line.data(using:.utf8){metadata=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any]}
            if line.contains("ERROR:"){error=line}
        },done:{code,cancelled,timedOut in DispatchQueue.main.async {
            job.run=nil
            if cancelled || self.quitting {self.finish(job,state:"cancelled",detail:"İptal edildi");return}
            guard code==0,let root=metadata else{self.finish(job,state:"failed",detail:timedOut ? "Video bilgileri zaman aşımına uğradı." : self.friendly(error));return}
            self.metadataCache[MediaSource.sourceURL(job.info.url)]=(Date(),root)
            self.prepareDownload(job,root:root)
        }})
    }
    func prepareDownload(_ job:Job,root:[String:Any]) {
        job.isPreparing=false
            guard let data=MediaSource.selected(root,url:job.info.url) else{self.finish(job,state:"failed",detail:"Seçilen video gönderide bulunamadı. Bağlantıyı yeniden önizle.");return}
            guard data["entries"] == nil else{self.finish(job,state:"failed",detail:"Bu bağlantı birden fazla video içeriyor. Önizlemeden videoları seçerek indir.");return}
            job.info=VideoInfo.parse(data,url:job.info.url);self.infos[job.info.url]=job.info;self.loadCover(job)
            job.tracker=DownloadProgress();job.tracker.configure(data);job.percent=max(job.percent,2)
            do {
                let infoFile=job.temporary.appendingPathComponent("info.json")
                try JSONSerialization.data(withJSONObject:data).write(to:infoFile,options:.atomic)
                try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:infoFile.path)
                self.download(job,metadata:infoFile)
            } catch {self.finish(job,state:"failed",detail:self.friendly(error.localizedDescription))}
    }
    func download(_ job:Job,metadata:URL) {
        let run=EngineRun();job.run=run;var finalPath="",error="İndirme tamamlanamadı."
        let args=baseArgs+["--load-info-json",metadata.path,"--concurrent-fragments","8","--newline","--progress","--progress-delta","0.5","--continue","--no-simulate","--no-overwrites","--format-sort-force","-S","res,fps,hdr:12,vcodec,br","-f",job.mode.format(height:job.height),"--merge-output-format","mp4","-P",job.temporary.path,"-o","source.%(ext)s","--progress-template","download:PROGRESS:{\"format\":%(info.format_id)j,\"progress\":{\"downloaded_bytes\":%(progress.downloaded_bytes)j,\"total_bytes\":%(progress.total_bytes)j,\"total_bytes_estimate\":%(progress.total_bytes_estimate)j,\"speed\":%(progress.speed)j,\"status\":%(progress.status)j}}","--print","after_move:FILE:%(filepath)j"]
        run.start(executable:executionEngine,arguments:args,line:{line in
            if line.hasPrefix("FILE:"),let data=String(line.dropFirst(5)).data(using:.utf8),let path=(try? JSONSerialization.jsonObject(with:data,options:.fragmentsAllowed)) as? String {finalPath=path}
            if line.contains("ERROR:"){error=line}
            if line.hasPrefix("PROGRESS:"),let data=String(line.dropFirst(9)).data(using:.utf8),let event=(try? JSONSerialization.jsonObject(with:data)) as? [String:Any],let progress=event["progress"] as? [String:Any] {
                DispatchQueue.main.async {
                    let value=job.tracker.update(id:event["format"] as? String ?? "source",progress:progress)
                    job.percent=max(job.percent,value)
                    let speed=(progress["speed"] as? NSNumber)?.doubleValue ?? 0
                    let received=job.tracker.received,total=job.tracker.total
                    let remaining=max(0,total-received)
                    let eta=speed>0 ? " · ~\(Int(remaining/speed)) sn" : ""
                    job.detail=String(format:"%.1f / ~%.1f MB · %.1f MB/sn",received/1_000_000,total/1_000_000,speed/1_000_000)+eta
                    self.send("job",job.json)
                }
            } else if line.hasPrefix("[Merger]") || line.hasPrefix("[Fixup") {
                DispatchQueue.main.async {job.percent=max(job.percent,90);job.detail="Görüntü ve ses birleştiriliyor…";self.send("job",job.json)}
            }
        },done:{code,cancelled,_ in DispatchQueue.main.async {
            job.run=nil
            if cancelled || self.quitting {self.finish(job,state:"cancelled",detail:"İptal edildi");return}
            guard code==0,!finalPath.isEmpty,FileManager.default.fileExists(atPath:finalPath) else{self.finish(job,state:"failed",detail:self.friendly(error));return}
            let source=URL(fileURLWithPath:finalPath)
            if job.mode == .original {self.publish(job,source:source)} else {self.convert(job,source:source)}
        }})
    }
    func convert(_ job:Job,source:URL) {
        job.percent=max(job.percent,92);job.detail=job.mode.isAudio ? "Ses hazırlanıyor…" : "Uyumlu MP4 hazırlanıyor…";send("job",job.json)
        let ext=job.mode == .mp3 ? "mp3" : job.mode == .m4a ? "m4a" : "mp4"
        let output=job.temporary.appendingPathComponent("converted."+ext)
        var args=["-hide_banner","-nostdin","-y","-i",source.path]
        switch job.mode {
        case .compatible:args += ["-map","0:v:0","-map","0:a?","-c:v","h264_videotoolbox","-q:v","65","-allow_sw","1","-pix_fmt","yuv420p","-c:a","aac","-b:a","192k","-movflags","+faststart"]
        case .mp3:args += ["-map","0:a:0","-vn","-c:a","libmp3lame","-q:a","2"]
        case .m4a:args += ["-map","0:a:0","-vn","-c:a","aac","-b:a","256k","-movflags","+faststart"]
        case .original:break
        }
        args += ["-progress","pipe:1","-nostats",output.path]
        let run=EngineRun();job.run=run;var error="Dosya dönüştürülemedi."
        run.start(executable:tools.appendingPathComponent("ffmpeg"),arguments:args,line:{line in
            if line.hasPrefix("out_time_us="),let micro=Double(line.dropFirst(12)) {
                DispatchQueue.main.async {let ratio=job.info.duration>0 ? min(1,micro/1_000_000/job.info.duration) : 0;job.percent=max(job.percent,92+7*ratio);self.send("job",job.json)}
            }
            if line.lowercased().contains("error") || line.contains("Invalid") || line.contains("matches no streams") {error=line}
        },done:{code,cancelled,_ in DispatchQueue.main.async {
            job.run=nil
            if cancelled || self.quitting {self.finish(job,state:"cancelled",detail:"İptal edildi");return}
            guard code==0,FileManager.default.fileExists(atPath:output.path) else{self.finish(job,state:"failed",detail:self.friendly(error));return}
            self.publish(job,source:output)
        }})
    }
    func publish(_ job:Job,source:URL) {
        do {
            let invalid=CharacterSet(charactersIn:"/\\:*?\"<>|\n\r\0")
            let clean=job.info.title.components(separatedBy:invalid).joined(separator:"_")
            let title=String(clean.prefix(55)).trimmingCharacters(in:.whitespacesAndNewlines)
            let tag=job.mode.isAudio ? job.mode.rawValue.uppercased() : (job.height.map{"\($0)p"} ?? "En iyi kalite")+(job.mode == .compatible ? " MP4" : "")
            let stem=(title.isEmpty ? "Video" : title)+" ["+tag+"]"
            var destination=job.folder.appendingPathComponent(stem+"."+source.pathExtension);var n=2
            while FileManager.default.fileExists(atPath:destination.path) {destination=job.folder.appendingPathComponent(stem+" (\(n))."+source.pathExtension);n+=1}
            job.path=destination.path;persistJobs(force:true)
            try FileManager.default.moveItem(at:source,to:destination)
            try? FileManager.default.removeItem(at:job.temporary)
            finish(job,state:"done",detail:"Tamamlandı")
        } catch {job.path="";finish(job,state:"failed",detail:friendly(error.localizedDescription))}
    }
    func finish(_ job:Job,state:String,detail:String) {
        job.run=nil
        if quitting && state != "done" {job.state="queued";job.detail="Kaldığı yerden devam edecek"}
        else {job.state=state;job.detail=detail}
        if state=="done" {job.percent=100}
        send("job",job.json);persistJobs(force:true)
        if quitting {finishQuitIfReady()}else{startNext()}
    }
}
