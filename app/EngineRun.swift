import Foundation
import Darwin

final class EngineRun {
    let process = Process()
    private let pipe = Pipe()
    private let lock = NSLock()
    private var cancelled = false
    private var timedOut = false
    func start(executable: URL, arguments: [String], timeout: Double? = nil,
               line: @escaping (String)->Void, done: @escaping (Int32, Bool, Bool)->Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            self.lock.lock()
            if self.cancelled { self.lock.unlock(); done(-1,true,false); return }
            self.process.executableURL = executable
            self.process.arguments = arguments
            self.process.standardOutput = self.pipe
            self.process.standardError = self.pipe
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = executable.deletingLastPathComponent().path + ":/usr/bin:/bin:/usr/sbin:/sbin"
            env["LANG"] = "en_US.UTF-8"
            self.process.environment = env
            do { try self.process.run() } catch {
                self.lock.unlock(); line("ERROR: \(error.localizedDescription)"); done(-1,false,false); return
            }
            self.lock.unlock()
            if let timeout = timeout {
                DispatchQueue.global().asyncAfter(deadline: .now()+timeout) {
                    self.lock.lock()
                    if self.process.isRunning { self.timedOut = true; self.process.interrupt(); self.escalateStop() }
                    self.lock.unlock()
                }
            }
            var buffer = Data()
            while true {
                let data = self.pipe.fileHandleForReading.availableData
                if data.isEmpty { break }
                buffer.append(data)
                while let end = buffer.firstIndex(of: 10) {
                    let part = buffer.prefix(upTo: end)
                    line(String(decoding: part, as: UTF8.self))
                    buffer.removeSubrange(...end)
                }
            }
            if !buffer.isEmpty { line(String(decoding:buffer,as:UTF8.self)) }
            self.process.waitUntilExit()
            self.lock.lock(); let c=self.cancelled; let t=self.timedOut; self.lock.unlock()
            done(self.process.terminationStatus,c,t)
        }
    }
    func cancel() {
        lock.lock(); cancelled = true
        if process.isRunning { process.interrupt() }
        lock.unlock()
        escalateStop()
    }
    private func escalateStop() {
        for (delay,signal) in [(3.0,SIGTERM),(6.0,SIGKILL)] {
            DispatchQueue.global().asyncAfter(deadline:.now()+delay) {
                self.lock.lock();defer{self.lock.unlock()}
                if self.process.isRunning {kill(self.process.processIdentifier,signal)}
            }
        }
    }
}

