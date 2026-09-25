import Darwin
import Foundation

public struct CommandResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String

    public var succeeded: Bool { status == 0 }
    /// `pfctl` writes almost everything to stderr, so callers usually want both.
    public var combined: String { stdout + stderr }
}

public enum Shell {
    /// Runs a command to completion, capturing both streams.
    ///
    /// Uses a concurrent read of both pipes: draining them sequentially can deadlock when a
    /// child fills the pipe buffer of the stream that is not being read yet.
    @discardableResult
    public static func run(
        _ executable: String,
        _ arguments: [String],
        input: String? = nil,
        timeout: TimeInterval = 5
    ) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let outPipe = Pipe(), errPipe = Pipe(), inPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = inPipe
        let ended = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in ended.signal() }

        do {
            try process.run()
        } catch {
            return CommandResult(status: -1, stdout: "", stderr: "\(error)")
        }

        if let input {
            inPipe.fileHandleForWriting.write(Data(input.utf8))
        }
        try? inPipe.fileHandleForWriting.close()

        var outData = Data(), errData = Data()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "hsbg.shell", attributes: .concurrent)
        let lock = NSLock()

        queue.async(group: group) {
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            lock.lock(); outData = data; lock.unlock()
        }
        queue.async(group: group) {
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            lock.lock(); errData = data; lock.unlock()
        }
        let timedOut = ended.wait(timeout: .now() + timeout) == .timedOut
        if timedOut && process.isRunning {
            process.terminate()
            if ended.wait(timeout: .now() + 1) == .timedOut && process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()
        group.wait()

        return CommandResult(
            status: timedOut ? -2 : process.terminationStatus,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self) + (timedOut ? "command timed out" : "")
        )
    }
}
