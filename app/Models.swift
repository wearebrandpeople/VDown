import Foundation

struct VideoInfo: Codable {
    let url: String
    let title: String
    let duration: Double
    let thumbnail: String
    let heights: [Int]
    let hasAudio: Bool
    var hasVideo: Bool? = nil
    var containsVideo: Bool { hasVideo ?? !heights.isEmpty }
    var json: [String: Any] { ["url":url,"title":title,"duration":duration,"thumbnail":thumbnail,"heights":heights,"hasAudio":hasAudio,"hasVideo":containsVideo] }
    static func pending(url:String,title:String?=nil)->VideoInfo { VideoInfo(url:url,title:title ?? url,duration:0,thumbnail:"",heights:[],hasAudio:true) }
    static func parse(_ data:[String:Any],url:String)->VideoInfo {
        var formats=data["formats"] as? [[String:Any]] ?? []
        if formats.isEmpty,data["url"] is String { formats=[data] }
        formats=formats.filter { $0["has_drm"] as? Bool != true }
        func video(_ f:[String:Any])->Bool {
            if let codec=f["vcodec"] as? String {return codec != "none"}
            if let h=f["height"] as? NSNumber,h.intValue>0{return true}
            return ["mp4","webm","mov","mkv","m3u8"].contains(f["ext"] as? String ?? "") && f["url"] is String
        }
        let heights=Set(formats.filter(video).compactMap { ($0["height"] as? NSNumber)?.intValue }.filter{$0>0}).sorted(by:>)
        let audio=formats.contains { f in
            if let codec=f["acodec"] as? String {return codec != "none"}
            return ["m4a","mp3","aac","opus","ogg","wav","flac"].contains(f["ext"] as? String ?? "")
        }
        let thumbs=data["thumbnails"] as? [[String:Any]] ?? []
        return VideoInfo(url:url,title:data["title"] as? String ?? "Video",duration:(data["duration"] as? NSNumber)?.doubleValue ?? 0,thumbnail:data["thumbnail"] as? String ?? thumbs.last?["url"] as? String ?? "",heights:heights,hasAudio:audio,hasVideo:formats.contains(where:video))
    }
}
enum OutputMode:String,Codable,CaseIterable {
    case original, compatible, m4a, mp3
    var label:String {switch self {case .original:return "Video";case .compatible:return "Uyumlu MP4";case .m4a:return "M4A ses";case .mp3:return "MP3 ses"}}
    var isAudio:Bool {self == .m4a || self == .mp3}
    func format(height:Int?)->String {
        if isAudio {return "bestaudio/best"}
        let filter=height.map{"[height=\($0)]"} ?? ""
        return "bestvideo"+filter+"+bestaudio/best"+filter+"/bestvideo"+filter
    }
}
final class Job: Codable {
    let id:String
    var info:VideoInfo
    let height:Int?
    let folder:URL
    let mode:OutputMode
    let created:Date
    var state="queued",detail="Sırada",path=""
    var isPreparing=false
    var coverDataURI=""
    var canClearHistory:Bool {["done","failed","cancelled"].contains(state)}
    var percent=0.0
    var run:EngineRun? = nil
    var tracker=DownloadProgress()
    enum CodingKeys:String,CodingKey {case id,info,height,folder,mode,created,state,detail,path,percent}
    init(info:VideoInfo,height:Int?,folder:URL,mode:OutputMode = .original) {id=UUID().uuidString;created=Date();self.info=info;self.height=height;self.folder=folder;self.mode=mode}
    var json:[String:Any] {["id":id,"title":info.title,"thumbnail":coverDataURI.isEmpty ? info.thumbnail : coverDataURI,"quality":mode.isAudio ? mode.label : (height.map{"\($0)p"} ?? "En iyi kalite")+(mode == .compatible ? " · Uyumlu MP4" : ""),"state":state,"percent":percent,"preparing":isPreparing,"detail":detail,"path":path,"created":created.timeIntervalSince1970]}
    var temporary:URL {folder.appendingPathComponent(".video-indir-partials/"+id)}
}
struct DownloadProgress {
    var weights:[String:Double]=[:]
    var downloaded:[String:Double]=[:]
    var fractions:[String:Double]=[:]
    mutating func configure(_ info:[String:Any]) {
        let formats=info["requested_formats"] as? [[String:Any]] ?? [info]
        let duration=(info["duration"] as? NSNumber)?.doubleValue ?? 1
        for f in formats {let id=f["format_id"] as? String ?? "source";let estimate=(f["filesize"] as? NSNumber)?.doubleValue ?? (f["filesize_approx"] as? NSNumber)?.doubleValue ?? ((f["tbr"] as? NSNumber)?.doubleValue ?? 1000)*1000/8*max(1,duration);weights[id]=max(1,estimate)}
    }
    mutating func update(id:String,progress:[String:Any])->Double {
        let key=weights[id] != nil ? id : weights.count==1 ? weights.keys.first! : id
        let bytes=(progress["downloaded_bytes"] as? NSNumber)?.doubleValue ?? 0
        let total=(progress["total_bytes"] as? NSNumber)?.doubleValue ?? (progress["total_bytes_estimate"] as? NSNumber)?.doubleValue ?? weights[key] ?? max(1,bytes)
        if weights[key]==nil {weights[key]=max(1,total)}
        downloaded[key]=bytes
        let fraction=(progress["status"] as? String)=="finished" ? 1 : min(1,bytes/max(1,total))
        fractions[key]=max(fractions[key] ?? 0,fraction)
        let sum=weights.values.reduce(0,+)
        return 2 + 88 * weights.reduce(0){$0+$1.value*(fractions[$1.key] ?? 0)}/max(1,sum)
    }
    var total:Double {weights.values.reduce(0,+)}
    var received:Double {downloaded.values.reduce(0,+)}
}

// Stable per-video identity for multi-video posts; the source URL stays reusable.
enum MediaSource {
    static let marker="video-indir-item="
    static func entryURL(_ source:String,id:String)->String {
        guard var parts=URLComponents(string:source) else{return source}
        parts.fragment=marker+id
        return parts.string ?? source
    }
    static func sourceURL(_ url:String)->String {
        guard var parts=URLComponents(string:url),parts.fragment?.hasPrefix(marker)==true else{return url}
        parts.fragment=nil;return parts.string ?? url
    }
    static func selected(_ data:[String:Any],url:String)->[String:Any]? {
        guard let fragment=URLComponents(string:url)?.fragment,fragment.hasPrefix(marker) else{return data}
        let id=String(fragment.dropFirst(marker.count))
        let matches=videos(data).filter{($0["id"] as? String)==id}
        return matches.count==1 ? matches[0] : nil
    }
    static func videos(_ data:[String:Any])->[[String:Any]] {
        (data["entries"] as? [[String:Any]] ?? []).flatMap { entry -> [[String:Any]] in
            if entry["entries"] != nil {return videos(entry)}
            let info=VideoInfo.parse(entry,url:"")
            return entry["id"] is String && (info.containsVideo || info.hasAudio) ? [entry] : []
        }
    }
}
