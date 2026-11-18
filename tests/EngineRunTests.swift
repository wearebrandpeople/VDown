import Foundation
@main struct EngineRunTests {
 static func main() {
  let run=EngineRun();let finished=DispatchSemaphore(value:0);let began=Date()
  run.start(executable:URL(fileURLWithPath:"/bin/sh"),arguments:["-c","trap '' INT TERM; while :; do :; done"],timeout:0.2,line:{_ in},done:{code,cancelled,timedOut in
   precondition(timedOut && !cancelled && code != 0)
   finished.signal()
  })
  precondition(finished.wait(timeout:.now()+10) == .success)
  precondition(Date().timeIntervalSince(began)<10)
  print("PASS: unresponsive process is killed after timeout")
 }
}
