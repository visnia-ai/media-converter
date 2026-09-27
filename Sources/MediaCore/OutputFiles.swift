import Foundation
import Darwin

enum OutputFiles {
    /// Hold the destination directory open so later path swaps cannot redirect writes.
    final class PreparedOutput {
        let temporary: URL
        private let workspace: URL
        private let directory: Int32
        private let output: URL
        private let root: URL

        fileprivate init(output: URL, root: URL, directory: Int32) throws {
            self.output = output
            self.root = root
            self.directory = directory
            var template = Array(FileManager.default.temporaryDirectory
                .appendingPathComponent("MediaConverter-Output-XXXXXX").path.utf8CString)
            guard mkdtemp(&template) != nil else {
                throw ConversionError.failed("Unable to create a private conversion workspace.")
            }
            workspace = URL(fileURLWithPath: String(decoding: template.dropLast().map { UInt8(bitPattern: $0) }, as: UTF8.self), isDirectory: true)
            temporary = workspace.appendingPathComponent("converted.\(output.pathExtension)")
        }

        deinit {
            close(directory)
            try? FileManager.default.removeItem(at: workspace)
        }

        func publish(source: URL) throws -> Int64 {
            try Task.checkCancellation()
            let current = try OutputFiles.openParent(output, root: root, create: false)
            defer { close(current) }
            var originalInfo = stat(), currentInfo = stat()
            guard fstat(directory, &originalInfo) == 0, fstat(current, &currentInfo) == 0,
                  originalInfo.st_dev == currentInfo.st_dev, originalInfo.st_ino == currentInfo.st_ino else {
                throw ConversionError.failed("The destination folder changed during conversion.")
            }
            // Apply metadata only inside the private workspace, never through the destination path.
            if let dates = try? source.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey]) {
                var attributes: [FileAttributeKey: Any] = [:]
                attributes[.creationDate] = dates.creationDate
                attributes[.modificationDate] = dates.contentModificationDate
                try? FileManager.default.setAttributes(attributes, ofItemAtPath: temporary.path)
            }
            let input = open(temporary.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard input >= 0 else { throw ConversionError.failed("Unable to read converted output.") }
            defer { close(input) }
            var info = stat()
            guard fstat(input, &info) == 0, info.st_mode & S_IFMT == S_IFREG, fchmod(input, 0o600) == 0 else {
                throw ConversionError.failed("Converted output is not a regular file.")
            }
            let staging = ".mediaconverter-\(UUID().uuidString)"
            let target = openat(directory, staging, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard target >= 0 else { throw ConversionError.failed("Unable to stage converted output.") }
            defer { close(target); unlinkat(directory, staging, 0) }
            var buffer = [UInt8](repeating: 0, count: 1_024 * 1_024)
            while true {
                try Task.checkCancellation()
                let count = read(input, &buffer, buffer.count)
                if count == 0 { break }
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw ConversionError.failed("Unable to read converted output.") }
                try buffer.withUnsafeBytes { bytes in
                    var offset = 0
                    while offset < count {
                        try Task.checkCancellation()
                        let written = write(target, bytes.baseAddress!.advanced(by: offset), count - offset)
                        if written < 0 && errno == EINTR { continue }
                        guard written > 0 else { throw ConversionError.failed("Unable to write converted output.") }
                        offset += written
                    }
                }
            }
            _ = fcopyfile(input, target, nil, copyfile_flags_t(COPYFILE_STAT))
            guard fchmod(target, 0o600) == 0, fsync(target) == 0 else { throw ConversionError.failed("Unable to protect output permissions.") }
            try Task.checkCancellation()
            // Both names resolve relative to the held directory; EXCL prevents overwrite races.
            guard renameatx_np(directory, staging, directory, output.lastPathComponent, UInt32(RENAME_EXCL)) == 0 else {
                if errno == EEXIST { throw ConversionError.outputExists }
                throw ConversionError.failed("Unable to publish converted output.")
            }
            return Int64(info.st_size)
        }
    }

    static func prepare(_ output: URL, root: URL) throws -> PreparedOutput {
        let directory = try openParent(output, root: root, create: true)
        do {
            var info = stat()
            let status = fstatat(directory, output.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW)
            guard status != 0, errno == ENOENT else { throw ConversionError.outputExists }
            return try PreparedOutput(output: output, root: root, directory: directory)
        } catch {
            close(directory)
            throw error
        }
    }

    private static func openParent(_ output: URL, root: URL, create: Bool) throws -> Int32 {
        // Normalize dot components lexically. Foundation standardization can rewrite
        // existing /private/var paths to /var while leaving new output paths unchanged.
        func components(_ url: URL) -> [String] {
            var result: [String] = []
            for component in url.pathComponents {
                if component == "." { continue }
                if component == ".." { if result.count > 1 { result.removeLast() } }
                else { result.append(component) }
            }
            return result
        }
        let rootComponents = components(root)
        let outputComponents = components(output)
        guard output.isFileURL, root.isFileURL,
              outputComponents.starts(with: rootComponents), outputComponents.count > rootComponents.count,
              !["", ".", ".."].contains(output.lastPathComponent) else {
            throw ConversionError.failed("The output must be inside the selected destination.")
        }
        var directory = open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw ConversionError.failed("The destination is no longer a regular folder.") }
        do {
            for component in outputComponents.dropFirst(rootComponents.count).dropLast() {
                if create && mkdirat(directory, component, 0o700) != 0 && errno != EEXIST {
                    throw ConversionError.failed("Unable to create an output folder.")
                }
                let next = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw ConversionError.failed("The output path contains a link or a non-directory item.") }
                close(directory)
                directory = next
            }
            return directory
        } catch {
            close(directory)
            throw error
        }
    }

    static func exists(_ url: URL) -> Bool {
        var info = stat()
        return url.path.withCString { lstat($0, &info) } == 0
    }
}
