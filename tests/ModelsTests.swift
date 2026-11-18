import Foundation
final class EngineRun {}
@main struct Tests {
 static func main() throws {
    let info=VideoInfo.pending(url:"https://example.org/video",title:"Örnek")
    let job=Job(info:info,height:2160,folder:URL(fileURLWithPath:"/tmp"),mode:.compatible)
    job.percent=47.5;job.state="downloading";job.path="/tmp/example.mp4"
    let copy=try JSONDecoder().decode(Job.self,from:JSONEncoder().encode(job))
    precondition(copy.id==job.id && copy.percent==47.5 && copy.mode == .compatible && copy.height==2160)
    precondition(copy.temporary==job.temporary)
    for state in ["queued","downloading","paused"] {job.state=state;precondition(!job.canClearHistory)}
    for state in ["done","failed","cancelled"] {job.state=state;precondition(job.canClearHistory)}
    job.coverDataURI="data:image/png;base64,dGVzdA=="
    precondition(job.json["thumbnail"] as? String == job.coverDataURI)
    var p=DownloadProgress();p.configure(["requested_formats":[["format_id":"video","filesize":900],["format_id":"audio","filesize":100]]])
    let a=p.update(id:"video",progress:["downloaded_bytes":900,"total_bytes":900,"status":"finished"])
    let b=p.update(id:"audio",progress:["downloaded_bytes":10,"total_bytes":100,"status":"downloading"])
    let c=p.update(id:"audio",progress:["downloaded_bytes":100,"total_bytes":100,"status":"finished"])
    precondition(a>80 && b>a && c==90)
    precondition(OutputMode.mp3.format(height:2160)=="bestaudio/best")
    precondition(OutputMode.original.format(height:2160).contains("height=2160"))
    let parsed=VideoInfo.parse(["formats":[["vcodec":"h264","height":2160,"acodec":"none"],["vcodec":"none","acodec":"aac"]]],url:info.url)
    precondition(parsed.heights==[2160] && parsed.hasAudio)
    let source="https://www.instagram.com/p/album/?utm_source=test"
    let childURL=MediaSource.entryURL(source,id:"child-2")
    let album:[String:Any]=["entries":[["id":"child-1","formats":[["height":720,"vcodec":"h264","acodec":"none"]]],["id":"child-2","formats":[["height":1080,"vcodec":"vp9","acodec":"none"]]],["id":"image"]]]
    precondition(MediaSource.sourceURL(childURL)==source)
    precondition(MediaSource.videos(album).count==2)
    precondition(MediaSource.selected(album,url:childURL)?["id"] as? String == "child-2")
    precondition(MediaSource.selected(album,url:MediaSource.entryURL(source,id:"missing"))==nil)
    let unknown=VideoInfo.parse(["formats":[["url":"https://example.org/a.mp4","ext":"mp4"]]],url:source)
    precondition(unknown.containsVideo && unknown.heights.isEmpty)
    let drm=VideoInfo.parse(["formats":[["height":1080,"vcodec":"h264","acodec":"aac","has_drm":true]]],url:source)
    precondition(!drm.containsVideo && !drm.hasAudio)
    precondition(MediaSource.videos(["entries":[album]]).count==2)
    precondition(MediaSource.selected(["entries":[album,album]],url:childURL)==nil)
    let legacy=try JSONSerialization.jsonObject(with:JSONEncoder().encode(info)) as! [String:Any]
    var legacyNoVideo=legacy;legacyNoVideo.removeValue(forKey:"hasVideo")
    _ = try JSONDecoder().decode(VideoInfo.self,from:JSONSerialization.data(withJSONObject:legacyNoVideo))
    print("PASS: history round-trip, stable resume path, weighted progress, audio/4K selection")
 }
}
