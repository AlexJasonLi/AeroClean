import Foundation

/// the open-source command line tools MacCleaner runs. all come from homebrew.
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

    /// runs a tool to completion. `onRecord` gets each stdout record split on `delimiter`
    /// as it arrives. cancelling the task terminates the process.
    public static func run(
        _ executable: URL,
        _ arguments: [String],
        delimiter: UInt8 = UInt8(ascii: "\n"),
        onRecord: (@Sendable (String) -> Void)? = nil
    ) async throws -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err

        let collected = StreamCollector(delimiter: delimiter, onRecord: onRecord)
        let errors = StreamCollector(delimiter: delimiter, onRecord: nil)
        out.fileHandleForReading.readabilityHandler = { handle in collected.append(handle.availableData) }
        err.fileHandleForReading.readabilityHandler = { handle in errors.append(handle.availableData) }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Result, Error>) in
                process.terminationHandler = { finished in
                    out.fileHandleForReading.readabilityHandler = nil
                    err.fileHandleForReading.readabilityHandler = nil
                    collected.append(out.fileHandleForReading.readDataToEndOfFile())
                    errors.append(err.fileHandleForReading.readDataToEndOfFile())
                    collected.finish()
                    continuation.resume(returning: Result(
                        status: finished.terminationStatus,
                        stdout: collected.data,
                        stderr: String(decoding: errors.data, as: UTF8.self)
                    ))
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }
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

/// thread-safe buffer for a pipe that also splits records as they arrive.
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
