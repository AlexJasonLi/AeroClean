import Darwin
import Foundation

/// the open-source command line tools AeroClean runs. all come from homebrew.
public enum Tool: String, CaseIterable, Sendable {
    case mole = "mo"
    case fclones
    case fd

    public var formula: String {
        switch self {
        case .mole: "mole"
        case .fclones: "fclones"
        case .fd: "fd"
        }
    }

    static var searchDirectories: [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin", "\(home)/.cargo/bin"]
    }

    public var location: URL? {
        for directory in Self.searchDirectories {
            let path = (directory as NSString).appendingPathComponent(rawValue)
            if FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    public static var missing: [Tool] { allCases.filter { $0.location == nil } }
}

public struct ProcessFailure: LocalizedError, Sendable {
    public let tool: String
    public let status: Int32
    public let stderr: String

    public var errorDescription: String? {
        let detail = stderr.split(separator: "\n").suffix(3).joined(separator: " ")
        return "\(tool) stopped with code \(status)" + (detail.isEmpty ? "" : ": \(detail)")
    }
}

public enum ProcessRunner {
    public struct Result: Sendable {
        public let status: Int32
        public let stdout: Data
        public let stderr: String
    }

    /// runs a tool to completion in its own process group. `onRecord` gets each stdout
    /// record split on `delimiter` as it arrives. cancelling the task stops the tool and
    /// every helper it started.
    public static func run(
        _ executable: URL,
        _ arguments: [String],
        delimiter: UInt8 = UInt8(ascii: "\n"),
        input: Data? = nil,
        onRecord: (@Sendable (String) -> Void)? = nil
    ) async throws -> Result {
        let job = Job(delimiter: delimiter, onRecord: onRecord, input: input)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Result, Error>) in
                do {
                    try job.start(executable: executable, arguments: arguments, environment: environment) {
                        continuation.resume(returning: $0)
                    }
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            job.cancel()
        }
    }

    /// stops every tool still running, e.g. when the app quits.
    public static func terminateAll() {
        Job.registry.terminateAll()
    }

    /// gui apps start with a bare PATH; the tools and the helpers mole calls live in homebrew.
    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let extra = Tool.searchDirectories + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        env["PATH"] = (extra + (env["PATH"].map { [$0] } ?? [])).joined(separator: ":")
        env["NO_COLOR"] = "1"
        env["TERM"] = "dumb"
        env["LANG"] = env["LANG"] ?? "en_US.UTF-8"
        return env
    }
}

/// one spawned tool. its pid is also its process group id, so signals reach the helpers
/// it forks, including ones that outlive it while still holding its output pipes.
final class Job: @unchecked Sendable {
    static let registry = Registry()

    private let lock = NSLock()
    private var pid: pid_t = 0
    private var cancelled = false
    private var completed = false
    private let out: StreamCollector
    private let err: StreamCollector
    private let input: Data?

    init(delimiter: UInt8, onRecord: (@Sendable (String) -> Void)?, input: Data? = nil) {
        out = StreamCollector(delimiter: delimiter, onRecord: onRecord)
        err = StreamCollector(delimiter: delimiter, onRecord: nil)
        self.input = input
    }

    func start(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        completion: @escaping @Sendable (ProcessRunner.Result) -> Void
    ) throws {
        var outPipe: [Int32] = [-1, -1]
        var errPipe: [Int32] = [-1, -1]
        guard pipe(&outPipe) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        guard pipe(&errPipe) == 0 else {
            close(outPipe[0]); close(outPipe[1])
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        var inPipe: [Int32] = [-1, -1]
        if input != nil, pipe(&inPipe) != 0 {
            close(outPipe[0]); close(outPipe[1]); close(errPipe[0]); close(errPipe[1])
            throw POSIXError(.init(rawValue: errno) ?? .EIO)
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if input != nil {
            posix_spawn_file_actions_adddup2(&actions, inPipe[0], 0)
        } else {
            posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        }
        posix_spawn_file_actions_adddup2(&actions, outPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, errPipe[1], 2)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // own process group; close every other inherited descriptor; reset signal handling.
        let flags = POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK
        posix_spawnattr_setflags(&attributes, Int16(flags))
        posix_spawnattr_setpgroup(&attributes, 0)
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal in [SIGPIPE, SIGTERM, SIGINT, SIGHUP, SIGQUIT, SIGCHLD] { sigaddset(&defaults, signal) }
        posix_spawnattr_setsigdefault(&attributes, &defaults)
        var unblocked = sigset_t()
        sigemptyset(&unblocked)
        posix_spawnattr_setsigmask(&attributes, &unblocked)

        let argv: [UnsafeMutablePointer<CChar>?] = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var child: pid_t = 0
        let spawned = posix_spawn(&child, executable.path, &actions, &attributes, argv, envp)
        close(outPipe[1])
        close(errPipe[1])
        if input != nil { close(inPipe[0]) }
        guard spawned == 0 else {
            close(outPipe[0]); close(errPipe[0])
            if input != nil { close(inPipe[1]) }
            throw POSIXError(.init(rawValue: spawned) ?? .EIO)
        }
        if let input {
            let writer = inPipe[1]
            DispatchQueue.global(qos: .utility).async {
                input.withUnsafeBytes { raw in
                    var offset = 0
                    while offset < raw.count {
                        let written = write(writer, raw.baseAddress! + offset, raw.count - offset)
                        if written > 0 { offset += written } else if errno != EINTR { break }
                    }
                }
                close(writer)
            }
        }

        let leader = child
        Self.registry.add(leader)
        let cancelledEarly = lock.withLock { () -> Bool in
            pid = leader
            return cancelled
        }
        if cancelledEarly { signalGroup(leader) }

        let readers = DispatchGroup()
        for (fd, collector) in [(outPipe[0], out), (errPipe[0], err)] {
            readers.enter()
            DispatchQueue.global(qos: .utility).async {
                var buffer = [UInt8](repeating: 0, count: 65_536)
                while true {
                    let count = read(fd, &buffer, buffer.count)
                    if count > 0 {
                        collector.append(Data(buffer[0..<count]))
                    } else if count < 0, errno == EINTR {
                        continue
                    } else {
                        break
                    }
                }
                close(fd)
                readers.leave()
            }
        }

        DispatchQueue.global(qos: .utility).async { [self] in
            var status: Int32 = 0
            while waitpid(leader, &status, 0) == -1, errno == EINTR {}
            // helpers that outlived the tool can keep its pipes open; give them a moment.
            if readers.wait(timeout: .now() + 2) == .timedOut {
                kill(-leader, SIGKILL)
                readers.wait()
            }
            lock.withLock { completed = true }
            Self.registry.remove(leader)
            out.finish()
            let exited = (status & 0x7F) == 0
            let code = exited ? (status >> 8) & 0xFF : 128 + (status & 0x7F)
            completion(ProcessRunner.Result(
                status: code,
                stdout: out.data,
                stderr: String(decoding: err.data, as: UTF8.self)
            ))
        }
    }

    func cancel() {
        let target: pid_t? = lock.withLock {
            cancelled = true
            return pid > 0 && !completed ? pid : nil
        }
        if let target { signalGroup(target) }
    }

    /// polite stop, then a hard one if the group is still around.
    private func signalGroup(_ group: pid_t) {
        kill(-group, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [self] in
            if lock.withLock({ !completed }) { kill(-group, SIGKILL) }
        }
    }

    final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var groups: Set<pid_t> = []

        func add(_ group: pid_t) { lock.withLock { _ = groups.insert(group) } }
        func remove(_ group: pid_t) { lock.withLock { _ = groups.remove(group) } }

        func terminateAll() {
            let live = lock.withLock { groups }
            guard !live.isEmpty else { return }
            live.forEach { kill(-$0, SIGTERM) }
            usleep(300_000)
            live.forEach { kill(-$0, SIGKILL) }
        }
    }
}

/// thread-safe buffer for a pipe that also splits records as they arrive.
/// each pipe has exactly one reader, so chunks arrive in order.
final class StreamCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var pending = Data()
    private let delimiter: UInt8
    private let onRecord: (@Sendable (String) -> Void)?

    init(delimiter: UInt8, onRecord: (@Sendable (String) -> Void)?) {
        self.delimiter = delimiter
        self.onRecord = onRecord
    }

    var data: Data { lock.withLock { buffer } }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        var records: [String] = []
        lock.withLock {
            buffer.append(chunk)
            guard onRecord != nil else { return }
            pending.append(chunk)
            while let index = pending.firstIndex(of: delimiter) {
                records.append(String(decoding: pending[pending.startIndex..<index], as: UTF8.self))
                pending.removeSubrange(pending.startIndex...index)
            }
        }
        records.forEach { onRecord?($0) }
    }

    func finish() {
        let rest: String? = lock.withLock {
            guard onRecord != nil, !pending.isEmpty else { return nil }
            defer { pending.removeAll() }
            return String(decoding: pending, as: UTF8.self)
        }
        if let rest { onRecord?(rest) }
    }
}
