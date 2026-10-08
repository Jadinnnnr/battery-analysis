import AppKit
import Darwin

enum Killer {
    enum Outcome {
        case done(Int)
        case notRunning
        case denied      // owned by root / another user
    }

    /// PIDs of every process that rolls up under this app/process name (read in-process, no `ps`).
    static func pids(for name: String) -> [Int32] {
        let me = getpid()
        return Sampler.allPIDs().filter { pid in
            pid != me && Sampler.path(of: pid).map { Sampler.appIdentity($0).name == name } == true
        }
    }

    /// Graceful quit (apps get a normal Quit request, like ⌘Q) or SIGKILL when forced.
    static func quit(name: String, appPath: String?, force: Bool) -> Outcome {
        var count = 0
        if let appPath, !force {
            for app in NSWorkspace.shared.runningApplications where app.bundleURL?.path == appPath {
                if app.terminate() { count += 1 }
            }
            if count > 0 { return .done(count) }
        }
        let list = pids(for: name)
        if list.isEmpty { return .notRunning }
        var denied = 0
        for pid in list {
            if kill(pid, force ? SIGKILL : SIGTERM) == 0 { count += 1 } else if errno == EPERM { denied += 1 }
        }
        if count > 0 { return .done(count) }
        return denied > 0 ? .denied : .notRunning
    }
}
