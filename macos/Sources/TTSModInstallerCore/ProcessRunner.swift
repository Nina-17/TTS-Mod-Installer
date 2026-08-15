import Foundation

public struct ProcessOutput {
    public let exitCode: Int32
    public let output: String

    public init(exitCode: Int32, output: String) {
        self.exitCode = exitCode
        self.output = output
    }
}

public enum ProcessRunner {
    public static func run(
        executable: URL,
        arguments: [String],
        currentDirectoryURL: URL? = nil,
        cancellationToken: CancellationToken? = nil
    ) throws -> ProcessOutput {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = currentDirectoryURL
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let group = DispatchGroup()
        let lock = NSLock()
        var captured = Data()
        var readError: Error?
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            do {
                let data = try pipe.fileHandleForReading.readToEnd() ?? Data()
                lock.lock()
                captured = data
                lock.unlock()
            } catch {
                lock.lock()
                readError = error
                lock.unlock()
            }
            group.leave()
        }

        try process.run()
        while process.isRunning {
            if cancellationToken?.isCancelled == true {
                process.terminate()
                process.waitUntilExit()
                group.wait()
                throw InstallerError.cancelled
            }
            Thread.sleep(forTimeInterval: 0.08)
        }
        process.waitUntilExit()
        group.wait()
        lock.lock()
        let data = captured
        let error = readError
        lock.unlock()
        if let error { throw error }
        return ProcessOutput(exitCode: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}
