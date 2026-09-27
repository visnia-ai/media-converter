import Foundation
import ImageIO
import UniformTypeIdentifiers
import Darwin

public enum FolderScanner {
    public static func validate(source: URL, destination: URL) throws -> (URL, URL) {
        let source = canonical(source)
        let destination = canonical(destination)
        for url in [source, destination] {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
            guard values.isDirectory == true, values.isPackage != true else {
                throw ConversionError.invalidFolders("Choose two regular folders.")
            }
        }
        // Component boundaries matter: /Photos and /Photos Copy do not overlap.
        let lhs = source.pathComponents, rhs = destination.pathComponents
        guard !lhs.starts(with: rhs), !rhs.starts(with: lhs) else {
            throw ConversionError.invalidFolders("Source and destination must be separate, non-overlapping folders.")
        }
        guard FileManager.default.isReadableFile(atPath: source.path),
              FileManager.default.isWritableFile(atPath: destination.path) else {
            throw ConversionError.invalidFolders("The source must be readable and the destination writable.")
        }
        return (source, destination)
    }

    public static func scan(source: URL, destination: URL, options: ConversionOptions) throws -> ConversionPlan {
        let (source, destination) = try validate(source: source, destination: destination)
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .isPackageKey, .fileSizeKey]
        var issues: [ConversionIssue] = []
        guard let enumerator = FileManager.default.enumerator(at: source,
            includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants],
            errorHandler: { url, _ in
                issues.append(.init(path: relative(url, to: source), message: "Unable to read this item."))
                return true
            }) else { throw ConversionError.failed("Unable to read the source folder.") }
        var entries: [(url: URL, path: String, kind: MediaKind, bytes: Int64, memory: UInt64)] = []
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            do {
                let values = try url.resourceValues(forKeys: Set(keys))
                // Package descendants are excluded by the enumerator; file links have no descendants.
                if values.isSymbolicLink == true || values.isPackage == true { continue }
                guard values.isRegularFile == true, let kind = classify(url) else { continue }
                let memory = kind == .image ? imageMemory(url) : 256 * 1_024 * 1_024
                entries.append((url, relative(url, to: source), kind, Int64(values.fileSize ?? 0), memory))
            } catch {
                issues.append(.init(path: relative(url, to: source), message: "Unable to read this item."))
            }
        }
        entries.sort { $0.path < $1.path }
        func base(_ entry: (url: URL, path: String, kind: MediaKind, bytes: Int64, memory: UInt64)) -> String {
            let ext = entry.kind == .image ? options.imageFormat.fileExtension : "mp4"
            return (entry.path as NSString).deletingPathExtension + "." + ext
        }
        // Use a conservative, case-insensitive key even on case-sensitive volumes.
        func key(_ path: String) -> String { path.precomposedStringWithCanonicalMapping.lowercased() }
        let counts = Dictionary(grouping: entries, by: { key(base($0)) }).mapValues(\.count)
        var reserved = Set<String>()
        let jobs = entries.enumerated().map { index, entry in
            var path = base(entry)
            if counts[key(path), default: 0] > 1 {
                path = entry.path + "." + (entry.kind == .image ? options.imageFormat.fileExtension : "mp4")
            }
            let original = path
            var suffix = 2
            while !reserved.insert(key(path)).inserted {
                path = (original as NSString).deletingPathExtension + "-\(suffix)." + (original as NSString).pathExtension
                suffix += 1
            }
            return ConversionJob(id: index, source: entry.url, destination: destination.appendingPathComponent(path),
                                 relativePath: entry.path, kind: entry.kind, sourceBytes: entry.bytes,
                                 estimatedMemory: entry.memory)
        }
        return ConversionPlan(source: source, destination: destination, jobs: jobs, issues: issues)
    }

    static func relative(_ url: URL, to root: URL) -> String {
        canonical(url).pathComponents.dropFirst(canonical(root).pathComponents.count).joined(separator: "/")
    }

    static func canonical(_ url: URL) -> URL {
        // Foundation sometimes standardizes /private/var to /var, while its enumerator does the reverse.
        guard let path = url.path.withCString({ realpath($0, nil) }) else { return url }
        defer { free(path) }
        return URL(fileURLWithPath: String(cString: path))
    }

    static func classify(_ url: URL) -> MediaKind? {
        let ext = url.pathExtension.lowercased()
        if VideoSourceTypes.all.contains(ext) { return .video }
        if ["raw", "dng", "cr2", "cr3", "nef", "arw", "orf", "rw2"].contains(ext) { return .image }
        // Recognize common formats without depending on Launch Services being available.
        if ["jpg", "jpeg", "jpe", "png", "tif", "tiff", "heic", "heif", "webp", "bmp", "gif", "avif", "exr", "ico", "icns", "svg"].contains(ext) { return .image }
        if let type = UTType(filenameExtension: ext), type.conforms(to: .image) { return .image }
        return nil
    }

    private static func imageMemory(_ url: URL) -> UInt64 {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else { return 128 * 1_024 * 1_024 }
        // RAW development also needs demosaicing and floating-point color-processing buffers.
        let bytesPerPixel: Double = CGImageSourceGetType(source) as String? == "com.canon.cr3-raw-image" ? 64 : 32
        let estimate = min(Double(UInt64.max / 2), max(1, width.doubleValue) * max(1, height.doubleValue) * bytesPerPixel)
        return max(32 * 1_024 * 1_024, UInt64(estimate))
    }
}
