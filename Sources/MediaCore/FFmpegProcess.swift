import Foundation
import Darwin

enum FFmpegTools {
    static func executable(_ name: String) throws -> URL {
        #if SWIFT_PACKAGE
        let url = Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "FFmpeg")
        #else
        let url: URL? = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/\(name)")
        #endif
        guard let url, FileManager.default.isExecutableFile(atPath: url.path) else {
            throw ConversionError.failed("The bundled video tools are missing. Rebuild or reinstall the app.")
        }
        return url
    }
}

struct FFmpegProcessResult: Sendable {
    let status: Int32
    let output: Data
    let diagnostic: String
}

/// All media access uses file handles opened by the parent, including seekable MP4 output.
/// Polling nonblocking pipes bounds memory and avoids a blocked reader deadlocking cancellation.
enum FFmpegProcess {
    static func run(executable: URL, arguments: [String], source: URL? = nil, destination: URL? = nil,
                    captureOutput: Bool = true,
                    onLine: (String) async throws -> Void = { _ in }) async throws -> FFmpegProcessResult {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C", "AV_LOG_FORCE_NOCOLOR": "1"]
        let input = try source.map { try FileHandle(forReadingFrom: $0) }
        defer { try? input?.close() }
        process.standardInput = input ?? FileHandle.nullDevice
        var outputFile: FileHandle?
        if let destination {
            let fd = destination.path.withCString { open($0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600) }
            guard fd >= 0 else {
                if errno == EEXIST { throw ConversionError.outputExists }
                throw ConversionError.failed("Unable to create temporary video output.")
            }
            outputFile = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        }
        defer { try? outputFile?.close() }
        let stdout = Pipe(), stderr = Pipe()
        process.standardOutput = outputFile ?? stdout.fileHandleForWriting
        process.standardError = stderr.fileHandleForWriting
        let readers = outputFile == nil ? [stdout.fileHandleForReading, stderr.fileHandleForReading] : [stderr.fileHandleForReading]
        for reader in readers {
            _ = fcntl(reader.fileDescriptor, F_SETFL, fcntl(reader.fileDescriptor, F_GETFL) | O_NONBLOCK)
        }
        defer {
            for reader in readers { try? reader.close() }
            if outputFile != nil { try? stdout.fileHandleForReading.close() }
            try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForWriting.close()
        }
        do { try process.run() }
        catch { throw ConversionError.failed("Unable to launch the bundled video tool.") }
        try? stdout.fileHandleForWriting.close()
        try? stderr.fileHandleForWriting.close()
        var captured = Data(), diagnostic = Data()
        var pending = Array(repeating: Data(), count: readers.count)
        var eof = Set<Int>()
        var buffer = [UInt8](repeating: 0, count: 32_768)
        do {
            while process.isRunning || eof.count < readers.count {
                try Task.checkCancellation()
                for (index, reader) in readers.enumerated() where !eof.contains(index) {
                    // Limit work per iteration so a busy pipe cannot starve cancellation or its sibling.
                    for _ in 0..<8 {
                        let count = Darwin.read(reader.fileDescriptor, &buffer, buffer.count)
                        if count == 0 { eof.insert(index); break }
                        if count < 0 {
                            if errno == EAGAIN || errno == EINTR { break }
                            throw ConversionError.failed("Unable to read the video tool response.")
                        }
                        let chunk = Data(buffer.prefix(count))
                        let isStdout = outputFile == nil && index == 0
                        if isStdout && captureOutput {
                            guard captured.count + count <= 8 * 1_024 * 1_024 else {
                                throw ConversionError.failed("Video metadata exceeds the supported size.")
                            }
                            captured.append(chunk)
                        }
                        if !isStdout {
                            diagnostic.append(chunk)
                            if diagnostic.count > 16_384 { diagnostic.removeFirst(diagnostic.count - 16_384) }
                        }
                        // Stream stdout for audits, stderr for encode progress. Probe JSON is captured only.
                        if (isStdout && !captureOutput) || (!isStdout && destination != nil) {
                            pending[index].append(chunk)
                            while let newline = pending[index].firstIndex(of: 10) {
                                let line = String(decoding: pending[index][..<newline], as: UTF8.self)
                                pending[index].removeSubrange(...newline)
                                try await onLine(line)
                            }
                            guard pending[index].count < 1_048_576 else {
                                throw ConversionError.failed("Invalid video tool response.")
                            }
                        }
                    }
                }
                if process.isRunning || eof.count < readers.count { try await Task.sleep(for: .milliseconds(10)) }
            }
            // isRunning is already false: Foundation has reaped the child. Calling
            // waitUntilExit here can deadlock a Swift executor thread's run loop.
            for line in pending where !line.isEmpty { try await onLine(String(decoding: line, as: UTF8.self)) }
            try Task.checkCancellation()
            return .init(status: process.terminationStatus, output: captured, diagnostic: String(decoding: diagnostic, as: UTF8.self))
        } catch {
            // Do not let cancellation short-circuit process reaping or leave it writing into a removed file.
            await Task.detached {
                if process.isRunning { process.terminate() }
                for _ in 0..<100 {
                    if !process.isRunning { break }
                    usleep(10_000)
                }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                while process.isRunning { usleep(10_000) }
            }.value
            throw error
        }
    }
}
