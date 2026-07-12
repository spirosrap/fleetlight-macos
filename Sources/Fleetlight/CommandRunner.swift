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

enum CommandRunner {
    static func runBuffered(executable: String, arguments: [String], timeout: TimeInterval) -> CommandResult {
        let process = Process()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        let startedAt = Date()

        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return CommandResult(
                exitCode: -1,
                stdout: "",
                stderr: error.localizedDescription,
                elapsedMilliseconds: Int(Date().timeIntervalSince(startedAt) * 1_000),
                timedOut: false
            )
        }

        let processReadyMilliseconds = Int(Date().timeIntervalSince(startedAt) * 1_000)
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.02)
        }

        let timedOut = process.isRunning
        if timedOut {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.1)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()

        let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        return CommandResult(
            exitCode: process.terminationStatus,
            stdout: String(decoding: stdout, as: UTF8.self),
            stderr: String(decoding: stderr, as: UTF8.self),
            elapsedMilliseconds: Int(Date().timeIntervalSince(startedAt) * 1_000),
            firstOutputMilliseconds: stdout.isEmpty ? nil : processReadyMilliseconds,
            timedOut: timedOut
        )
    }

    static func run(executable: String, arguments: [String], timeout: TimeInterval) -> CommandResult {
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

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }

        let timedOut = process.isRunning
        if timedOut {
            process.terminate()
            Thread.sleep(forTimeInterval: 0.15)
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()
        _ = readers.wait(timeout: .now() + 1)

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
