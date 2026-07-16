import Dispatch
import Foundation
import FleetlightCore

private final class ProcessOutputCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let startedAt: Date
    private var stdoutData = Data()
    private var stderrData = Data()
    private var firstOutputMilliseconds: Int?

    init(startedAt: Date) {
        self.startedAt = startedAt
    }

    func appendStdout(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        if firstOutputMilliseconds == nil {
            firstOutputMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
        }
        stdoutData.append(data)
        lock.unlock()
    }

    func appendStderr(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        stderrData.append(data)
        lock.unlock()
    }

    func snapshot() -> (stdout: Data, stderr: Data, firstOutputMilliseconds: Int?) {
        lock.lock()
        defer { lock.unlock() }
        return (stdoutData, stderrData, firstOutputMilliseconds)
    }
}

private final class CommandCancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func cancel() {
        lock.lock()
        value = true
        lock.unlock()
    }
}

enum CommandRunner {
    // Process waits are blocking. Keep them off Swift's cooperative executor so
    // concurrent fleet probes cannot starve their own pipe readers or UI tasks.
    private static let executionQueue = DispatchQueue(
        label: "app.fleetlight.command-runner",
        qos: .userInitiated,
        attributes: .concurrent
    )

    static func runBufferedAsync(
        executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) async -> CommandResult {
        await runAsync(executable: executable, arguments: arguments, timeout: timeout)
    }

    static func runAsync(
        executable: String,
        arguments: [String],
        timeout: TimeInterval
    ) async -> CommandResult {
        let cancellation = CommandCancellationState()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                executionQueue.async {
                    continuation.resume(returning: run(
                        executable: executable,
                        arguments: arguments,
                        timeout: timeout,
                        isCancelled: { cancellation.isCancelled }
                    ))
                }
            }
        } onCancel: {
            cancellation.cancel()
        }
    }

    static func runBuffered(executable: String, arguments: [String], timeout: TimeInterval) -> CommandResult {
        run(executable: executable, arguments: arguments, timeout: timeout)
    }

    static func run(
        executable: String,
        arguments: [String],
        timeout: TimeInterval,
        isCancelled: (@Sendable () -> Bool)? = nil
    ) -> CommandResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let startedAt = Date()
        let capture = ProcessOutputCapture(startedAt: startedAt)

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice
        let terminated = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in terminated.signal() }

        do {
            try process.run()
            // The child owns duplicated write descriptors after launch. Closing the
            // parent's copies lets the asynchronous readers observe EOF reliably,
            // including for very short-lived local probes.
            try? stdoutPipe.fileHandleForWriting.close()
            try? stderrPipe.fileHandleForWriting.close()
        } catch {
            return CommandResult(
                exitCode: -1,
                stdout: "",
                stderr: error.localizedDescription,
                elapsedMilliseconds: Int(Date().timeIntervalSince(startedAt) * 1_000),
                timedOut: false
            )
        }

        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            while true {
                let data = stdoutPipe.fileHandleForReading.availableData
                guard !data.isEmpty else { break }
                capture.appendStdout(data)
            }
            readers.leave()
        }
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            while true {
                let data = stderrPipe.fileHandleForReading.availableData
                guard !data.isEmpty else { break }
                capture.appendStderr(data)
            }
            readers.leave()
        }

        var timedOut = false
        var cancelled = false
        if let isCancelled {
            let deadline = Date().addingTimeInterval(timeout)
            while true {
                let remaining = deadline.timeIntervalSinceNow
                guard remaining > 0 else {
                    timedOut = true
                    break
                }
                if terminated.wait(timeout: .now() + min(0.05, remaining)) == .success {
                    break
                }
                if isCancelled() {
                    cancelled = true
                    break
                }
            }
        } else {
            timedOut = terminated.wait(timeout: .now() + timeout) == .timedOut
        }
        if timedOut || cancelled {
            process.terminate()
            if terminated.wait(timeout: .now() + 0.15) == .timedOut, process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                _ = terminated.wait(timeout: .now() + 1)
            }
        }
        process.waitUntilExit()
        _ = readers.wait(timeout: .now() + 2)

        let output = capture.snapshot()
        return CommandResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: output.stdout, as: UTF8.self),
            stderr: String(decoding: output.stderr, as: UTF8.self),
            elapsedMilliseconds: Int(Date().timeIntervalSince(startedAt) * 1_000),
            firstOutputMilliseconds: output.firstOutputMilliseconds,
            timedOut: timedOut
        )
    }
}
