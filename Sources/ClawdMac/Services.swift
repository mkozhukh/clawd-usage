import Foundation
import ClawdCore
import Darwin

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

enum ClaudeCLI {
    static func executable(custom: String) throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let candidates = custom.isEmpty
            ? ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
              + (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/claude" }
            : [(custom as NSString).expandingTildeInPath]
        guard let path = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw ServiceError.message("Claude Code was not found. Install and sign in to Claude Code, or choose its executable in Settings.")
        }
        return URL(fileURLWithPath: path)
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
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "\(executable.deletingLastPathComponent().path):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (environment["PATH"] ?? "")
            environment.removeValue(forKey: "CLAUDECODE")
            process.environment = environment
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

/// The last usage report, shown at launch until the first refresh.
actor SnapshotStorage {
    private let url: URL
    private let legacy: URL
    init() {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClawdMac")
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
