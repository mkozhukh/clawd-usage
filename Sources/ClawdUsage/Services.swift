import Foundation
import ClawdCore
import Darwin

/// The app's version from its Info.plist; "dev" when run unbundled (`swift run`).
enum AppVersion {
    static let current: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
}

enum ServiceError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}

final class ChildProcesses: @unchecked Sendable {
    static let shared = ChildProcesses()
    private let lock = NSLock()
    private var ids: Set<Int32> = []
    func insert(_ pid: Int32) { lock.withLock { _ = ids.insert(pid) } }
    func remove(_ pid: Int32) { lock.withLock { _ = ids.remove(pid) } }
    func contains(_ pid: Int32) -> Bool { lock.withLock { ids.contains(pid) } }
    func terminateAll() { lock.withLock { for pid in ids { kill(pid, SIGTERM) } } }
}

/// The first executable among the usual install locations and the inherited PATH, or the one chosen in Settings.
private func findExecutable(_ name: String, custom: String, extra: [String] = []) -> URL? {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let candidates = custom.isEmpty
        ? (["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"] + extra.map { "\(home)/\($0)" }
           + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)).map { "\($0)/\(name)" }
        : [(custom as NSString).expandingTildeInPath]
    return ExecutableLookup.first(candidates)
}

/// The child's PATH starts with the executable's own folder, so an npm-installed script finds its node.
private func childEnvironment(for executable: URL) -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = "\(executable.deletingLastPathComponent().path):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
    environment.removeValue(forKey: "CLAUDECODE")
    return environment
}

enum ClaudeCLI {
    static func executable(custom: String) throws -> URL {
        guard let url = findExecutable("claude", custom: custom) else {
            throw ServiceError.message("Claude Code was not found. Install and sign in to Claude Code, or choose its executable in Settings.")
        }
        return url
    }

    // File-backed output avoids pipe-buffer deadlocks, including unusually large /usage reports.
    static func run(arguments: [String], custom: String, timeout: TimeInterval = 25) async throws -> String {
        try await Task.detached(priority: .utility) {
            let executable = try executable(custom: custom)
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let output = directory.appendingPathComponent("stdout")
            let error = directory.appendingPathComponent("stderr")
            FileManager.default.createFile(atPath: output.path, contents: nil)
            FileManager.default.createFile(atPath: error.path, contents: nil)
            let outHandle = try FileHandle(forWritingTo: output)
            let errHandle = try FileHandle(forWritingTo: error)
            defer { try? outHandle.close(); try? errHandle.close() }
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.standardOutput = outHandle
            process.standardError = errHandle
            process.standardInput = FileHandle.nullDevice
            process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
            process.environment = childEnvironment(for: executable)
            try process.run()
            let pid = process.processIdentifier
            ChildProcesses.shared.insert(pid)
            defer { ChildProcesses.shared.remove(pid) }
            let deadline = Date().addingTimeInterval(timeout)
            while process.isRunning && Date() < deadline { try await Task.sleep(for: .milliseconds(100)) }
            if process.isRunning {
                process.terminate()
                let grace = Date().addingTimeInterval(1)
                while process.isRunning && Date() < grace { try await Task.sleep(for: .milliseconds(50)) }
                if process.isRunning { kill(pid, SIGKILL) }
                process.waitUntilExit()
                throw ServiceError.message("Claude timed out after \(Int(timeout)) seconds. Last known usage is retained.")
            }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let detail = (try? String(contentsOf: error, encoding: .utf8)) ?? ""
                throw ServiceError.message(detail.isEmpty ? "Claude exited with code \(process.terminationStatus). Run claude auth login in Terminal." : String(detail.prefix(600)))
            }
            return try String(contentsOf: output, encoding: .utf8)
        }.value
    }
}

enum CodexCLI {
    enum Failure: Error { case notInstalled }

    /// npm installs under fnm, nvm-less Volta and a custom npm prefix are not on a GUI app's PATH.
    static func executable(custom: String) -> URL? {
        findExecutable("codex", custom: custom, extra: [".local/share/fnm/aliases/default/bin", ".volta/bin", ".npm-global/bin", ".bun/bin"])
    }

    /// Asks `codex app-server` for the account's rate limits over JSON-RPC on stdio. This uses the
    /// existing Codex login and runs no model. Throws `Failure.notInstalled` when nothing was found
    /// automatically, so a missing Codex is not an error.
    static func rateLimits(custom: String, timeout: TimeInterval = 20) async throws -> Data {
        guard let executable = executable(custom: custom) else {
            if custom.isEmpty { throw Failure.notInstalled }
            throw ServiceError.message("Codex was not found at \(custom). Choose its executable in Settings.")
        }
        return try await Task.detached(priority: .utility) {
            let process = Process()
            process.executableURL = executable
            process.arguments = ["app-server"]
            process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser
            process.environment = childEnvironment(for: executable)
            let input = Pipe(), output = Pipe()
            process.standardInput = input
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            // stdout is drained as it arrives, so the pipe buffer never fills; the reply is the line with id 2.
            let reply = ReplyBuffer()
            output.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty { handle.readabilityHandler = nil; reply.finish() } else { reply.append(chunk) }
            }
            try process.run()
            let pid = process.processIdentifier
            ChildProcesses.shared.insert(pid)
            defer {
                output.fileHandleForReading.readabilityHandler = nil
                if process.isRunning { process.terminate() }
                let grace = Date().addingTimeInterval(1)
                while process.isRunning && Date() < grace { usleep(50_000) }
                if process.isRunning { kill(pid, SIGKILL) }
                ChildProcesses.shared.remove(pid)
            }
            let requests = [
                #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"clawd-mac","version":"\#(AppVersion.current)"}}}"#,
                #"{"jsonrpc":"2.0","method":"initialized"}"#,
                #"{"jsonrpc":"2.0","id":2,"method":"account/rateLimits/read"}"#
            ]
            try input.fileHandleForWriting.write(contentsOf: Data((requests.joined(separator: "\n") + "\n").utf8))
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if let line = reply.line(id: 2) { return line }
                if !process.isRunning {
                    // The reply may still be in the pipe: wait for the reader to reach EOF, then look again.
                    while !reply.ended && Date() < deadline { try await Task.sleep(for: .milliseconds(20)) }
                    if let line = reply.line(id: 2) { return line }
                    throw ServiceError.message("Codex exited with code \(process.terminationStatus). Run codex login in Terminal.")
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            throw ServiceError.message("Codex timed out after \(Int(timeout)) seconds. Last known usage is retained.")
        }.value
    }

    /// Lines read so far from the app server, filled from its reading thread.
    private final class ReplyBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        private var eof = false
        func append(_ chunk: Data) { lock.withLock { data.append(chunk) } }
        /// The server closed its stdout; everything it wrote has been appended.
        func finish() { lock.withLock { eof = true } }
        var ended: Bool { lock.withLock { eof } }
        func line(id: Int) -> Data? {
            lock.withLock {
                data.split(separator: UInt8(ascii: "\n")).first { line in
                    (try? JSONSerialization.jsonObject(with: line) as? [String: Any])?["id"] as? Int == id
                }.map { Data($0) }
            }
        }
    }
}

enum SessionReader {
    static func read() async -> [Session] {
        await Task.detached(priority: .utility) {
            let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/sessions")
            let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
            return files.filter { $0.pathExtension == "json" }.compactMap { url -> Session? in
                guard let data = try? Data(contentsOf: url),
                      let session = try? JSONDecoder().decode(Session.self, from: data), session.pid > 0,
                      !ChildProcesses.shared.contains(session.pid),
                      kill(session.pid, 0) == 0 || errno == EPERM else { return nil }
                // A stale registry file must not count an unrelated process that reused the PID.
                var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
                guard proc_pidpath(session.pid, &path, UInt32(path.count)) > 0 else { return nil }
                let executable = String(decoding: path.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self).lowercased()
                guard executable.contains("claude") || URL(fileURLWithPath: executable).lastPathComponent == "node" else { return nil }
                return session
            }.sorted { $0.pid < $1.pid }
        }.value
    }
}

/// Follows Codex session logs, reading only what was appended since the last call, so a poll every
/// few seconds stays cheap. Logs come from today's and yesterday's folders, plus any log a running
/// Codex holds open: a resumed session keeps writing its first day's log, however old. The whole
/// history is never walked. Logs are kept by path and checked through a fresh URL each time,
/// since a URL caches its size and date after the first look.
actor CodexActivityReader {
    private struct Log { var offset = 0; var rollout = CodexRollout(); var modified = Date.distantPast }
    private var logs: [String: Log] = [:]
    private var lastConfig = Date.distantPast
    private var configuredModel: String?
    /// Logs untouched for longer are dropped, unless a running Codex still holds them.
    private let horizon: TimeInterval = 6 * 3600
    private let home: URL = ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")

    func read(now: Date = .now) -> CodexActivity {
        if now.timeIntervalSince(lastConfig) > 60 {
            lastConfig = now
            configuredModel = (try? String(contentsOf: home.appendingPathComponent("config.toml"), encoding: .utf8)).flatMap(CodexConfig.model(toml:))
        }
        let live = CodexProcesses.list()
        let held = Set((live ?? []).compactMap { $0.rollout?.path })
        var found = Set(logs.keys).union(held)
        let sessions = home.appendingPathComponent("sessions")
        for day in [now, now.addingTimeInterval(-86400)] {
            let parts = Calendar.current.dateComponents([.year, .month, .day], from: day)
            let folder = sessions.appendingPathComponent(String(format: "%04d/%02d/%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0))
            for url in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
            where url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension == "jsonl" {
                found.insert(url.standardizedFileURL.path)
            }
        }
        for path in found {
            let url = URL(fileURLWithPath: path)
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]),
                  let modified = values.contentModificationDate, let size = values.fileSize,
                  now.timeIntervalSince(modified) < horizon || held.contains(path) else { logs[path] = nil; continue }
            var log = logs[path] ?? Log()
            if size < log.offset { log = Log() }  // rewritten from scratch
            if size > log.offset, let handle = try? FileHandle(forReadingFrom: url) {
                defer { try? handle.close() }
                if (try? handle.seek(toOffset: UInt64(log.offset))) != nil, let data = try? handle.readToEnd() {
                    log.offset += log.rollout.feed(data)
                }
            }
            log.modified = modified
            logs[path] = log
        }
        var activity = CodexActivity.resolve(logs.values.map { ($0.rollout, $0.modified) }, configuredModel: configuredModel, now: now)
        if let live { activity.apply(live: live.map { ($0.pid, $0.cwd, $0.rollout.flatMap { logs[$0.path]?.rollout }) }) }
        return activity
    }
}

/// Running Codex sessions: the native `codex` binary (the npm wrapper is a separate `node`
/// process), its working directory, and the session log it holds open. The widget's own
/// children (by parent PID and by `ChildProcesses`) and Codex servers (`app-server`,
/// `mcp-server`) are left out. Each check fails open on its own: an unreadable parent PID
/// skips only the parent check, unreadable arguments only the server check.
enum CodexProcesses {
    struct Entry { var pid: Int32; var cwd: String; var rollout: URL? }

    /// nil when the process table could not be read; callers then fall back to the logs alone.
    static func list() -> [Entry]? {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return nil }
        var pids = [Int32](repeating: 0, count: Int(count) + 32)
        let filled = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard filled > 0 else { return nil }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        return pids.prefix(Int(filled)).compactMap { pid -> Entry? in
            guard pid > 0, !ChildProcesses.shared.contains(pid),
                  proc_pidpath(pid, &path, UInt32(path.count)) > 0,
                  URL(fileURLWithPath: String(decoding: path.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)).lastPathComponent == "codex",
                  parent(of: pid) != getpid(),
                  arguments(of: pid).map(CodexProcessRule.isSession(arguments:)) ?? true else { return nil }
            var info = proc_vnodepathinfo()
            guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(MemoryLayout<proc_vnodepathinfo>.size)) > 0 else { return nil }
            return Entry(pid: pid, cwd: text(info.pvi_cdir.vip_path), rollout: rollout(of: pid))
        }
    }

    /// nil when it cannot be read.
    private static func parent(of pid: Int32) -> Int32? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Int32(bitPattern: info.pbi_ppid)
    }

    /// argv[1...] from `KERN_PROCARGS2`: argc, the executable path, NUL padding, then argv.
    /// nil when the data cannot be read or is truncated.
    private static func arguments(of pid: Int32) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        let argc = Int(buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        guard argc >= 1 else { return nil }
        var index = MemoryLayout<Int32>.size
        while index < size && buffer[index] != 0 { index += 1 }   // executable path
        while index < size && buffer[index] == 0 { index += 1 }   // padding
        var argv: [String] = []
        while argv.count < argc {
            guard index < size, let end = buffer[index..<size].firstIndex(of: 0) else { return nil }
            argv.append(String(decoding: buffer[index..<end], as: UTF8.self))
            index = end + 1
        }
        return Array(argv.dropFirst())
    }

    private static func rollout(of pid: Int32) -> URL? {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return nil }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.size + 8)
        let used = fds.withUnsafeMutableBytes { proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count)) }
        for fd in fds.prefix(Int(used) / MemoryLayout<proc_fdinfo>.size) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
            var vnode = vnode_fdinfowithpath()
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &vnode, Int32(MemoryLayout<vnode_fdinfowithpath>.size)) > 0 else { continue }
            let file = URL(fileURLWithPath: text(vnode.pvip.vip_path))
            if file.lastPathComponent.hasPrefix("rollout-") && file.pathExtension == "jsonl" { return file.standardizedFileURL }
        }
        return nil
    }

    /// A fixed-size C path buffer imported as a tuple.
    private static func text<T>(_ tuple: T) -> String {
        withUnsafeBytes(of: tuple) { String(decoding: $0.prefix(while: { $0 != 0 }), as: UTF8.self) }
    }
}

/// The last Codex limits, shown at launch until the first refresh.
actor CodexStorage {
    private let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ClawdUsage/last-codex-usage.json")
    func load() throws -> CodexUsage? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(CodexUsage.self, from: Data(contentsOf: url))
    }
    func save(_ usage: CodexUsage) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(usage).write(to: url, options: .atomic)
    }
}

/// The last usage report, shown at launch until the first refresh.
actor SnapshotStorage {
    private let url: URL
    private let legacy: URL
    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClawdUsage")
        url = directory.appendingPathComponent("last-usage.json")
        legacy = directory.appendingPathComponent("usage-history.json")
    }
    func load() throws -> UsageSnapshot? {
        if FileManager.default.fileExists(atPath: url.path) {
            return try JSONDecoder().decode(UsageSnapshot.self, from: Data(contentsOf: url))
        }
        // Earlier versions kept a week of samples; only the newest is still needed.
        guard FileManager.default.fileExists(atPath: legacy.path) else { return nil }
        return try JSONDecoder().decode([UsageSnapshot].self, from: Data(contentsOf: legacy)).last
    }
    func save(_ snapshot: UsageSnapshot) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: url, options: .atomic)
        try? FileManager.default.removeItem(at: legacy)
    }
}
