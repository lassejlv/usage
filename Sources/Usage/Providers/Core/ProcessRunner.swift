import Foundation
import Darwin

struct ProcessResult: Sendable {
    var exitCode: Int32
    var stdout: String
    var stderr: String

    var succeeded: Bool { exitCode == 0 }
}

enum ProcessRunError: Error {
    case timedOut
}

/// A small, synchronous subprocess runner. Call it off the main/actor thread (e.g. inside a
/// `Task.detached`) — `run` blocks until the child exits or `timeout` elapses. Both pipes are drained
/// on background queues *before* the child runs, so a child that writes past the OS pipe buffer
/// (~64KB) can't block on write and deadlock the timeout.
enum ProcessRunner {
    static func run(
        executable: String,
        arguments: [String],
        environment: [String: String] = [:],
        timeout: TimeInterval
    ) throws -> ProcessResult {
        let process = Process()
        // Absolute paths run directly; a bare command name goes through `/usr/bin/env` so PATH
        // resolution (and the enriched PATH we pass) applies.
        if executable.hasPrefix("/") {
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
        } else {
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments
        }
        if !environment.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let output = OutputCollector()
        let drained = DispatchGroup()
        drain(stdoutPipe.fileHandleForReading, isStdout: true, into: output, group: drained)
        drain(stderrPipe.fileHandleForReading, isStdout: false, into: output, group: drained)

        // One kernel-level wait instead of polling: the termination handler (registered before
        // `run()` so an instantly-exiting child can't race it) trips the group.
        let exited = DispatchGroup()
        exited.enter()
        process.terminationHandler = { _ in exited.leave() }

        try process.run()

        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = exited.wait(timeout: .now() + 0.2)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            drained.wait() // the killed child closed its pipes, so the drains hit EOF and finish
            throw ProcessRunError.timedOut
        }

        process.waitUntilExit()
        drained.wait()
        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: output.stdoutString,
            stderr: output.stderrString
        )
    }

    /// Read a pipe to EOF on a background queue, started before the child runs so the pipe is
    /// continuously drained and can never fill.
    private static func drain(
        _ handle: FileHandle, isStdout: Bool, into output: OutputCollector, group: DispatchGroup
    ) {
        let box = HandleBox(handle)
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            let data = box.handle.readDataToEndOfFile()
            output.set(data, isStdout: isStdout)
            group.leave()
        }
    }
}

/// Carries a non-Sendable `FileHandle` into the drain closure under strict concurrency. The handle is
/// read by exactly one queue, so the unchecked conformance is sound.
private final class HandleBox: @unchecked Sendable {
    let handle: FileHandle
    init(_ handle: FileHandle) { self.handle = handle }
}

/// Lock-guarded accumulator for the two concurrently-drained pipes.
private final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = Data()
    private var stderr = Data()

    func set(_ data: Data, isStdout: Bool) {
        lock.lock(); defer { lock.unlock() }
        if isStdout { stdout = data } else { stderr = data }
    }

    var stdoutString: String { lock.lock(); defer { lock.unlock() }; return String(data: stdout, encoding: .utf8) ?? "" }
    var stderrString: String { lock.lock(); defer { lock.unlock() }; return String(data: stderr, encoding: .utf8) ?? "" }
}
