import AppKit
import Darwin

enum Killer {
    enum Outcome {
        case done(Int)
        case notRunning
        case denied      // owned by root / another user
    }

    /// Whether a process at `path` belongs to this entry. Apps match on their bundle path, so
    /// two copies of an app (or an unrelated app with the same name) aren't caught together.
    static func matches(path: String, name: String, appPath: String?) -> Bool {
        let id = Sampler.appIdentity(path)
        if let appPath { return id.appPath == appPath }
        return id.appPath == nil && id.name == name
    }

    /// PIDs of every process that rolls up under this entry (read in-process, no `ps`).
    static func pids(for name: String, appPath: String?) -> [Int32] {
        let me = getpid()
        return Sampler.allPIDs().filter { pid in
            pid != me && Sampler.path(of: pid).map { matches(path: $0, name: name, appPath: appPath) } == true
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
        let list = pids(for: name, appPath: appPath)
        if list.isEmpty { return .notRunning }
        var denied = 0
        for pid in list {
            if kill(pid, force ? SIGKILL : SIGTERM) == 0 { count += 1 } else if errno == EPERM { denied += 1 }
        }
        if count > 0 { return .done(count) }
        return denied > 0 ? .denied : .notRunning
    }
}
