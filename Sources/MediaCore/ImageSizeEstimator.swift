import Foundation
import CryptoKit
import ImageIO

public struct ImageSizeEstimate: Sendable {
    public let format: ImageFormat
    public let quality: Int
    public let discoveredImages: Int
    public let sampledCount: Int
    public let measuredCount: Int
    public let skippedCount: Int
    public let failedCount: Int
    public let unreadableCount: Int
    public let largerCount: Int
    public let sourceBytes: Int64
    public let outputBytes: Int64

    public var averageOutputBytes: Int64? {
        measuredCount > 0 ? Int64((Double(outputBytes) / Double(measuredCount)).rounded()) : nil
    }
    /// A positive value means the sampled outputs grew; failures are excluded from both totals.
    public var sizeChange: Double? {
        sourceBytes > 0 ? Double(outputBytes) / Double(sourceBytes) - 1 : nil
    }
}

public struct ImageEstimateProgress: Sendable {
    public enum Phase: Sendable { case scanning, measuring }
    public let phase: Phase
    public let completed: Int
    public let total: Int
}

struct ImageSampleCandidate: Sendable {
    let url: URL
    let relativePath: String
    let format: String
    let pixels: Double
    let bytes: Int64
    var memory: UInt64 {
        let bytesPerPixel = format == "com.canon.cr3-raw-image" ? 64.0 : 32.0
        return UInt64(min(Double(UInt64.max / 2), max(32 * 1_024 * 1_024, pixels * bytesPerPixel)))
    }
}

enum ImageSampler {
    /// Systematic sampling across format, pixel count, and byte size avoids taking only the first subfolder.
    static func select(_ candidates: [ImageSampleCandidate]) -> [ImageSampleCandidate] {
        let ordered = candidates.sorted {
            if $0.format != $1.format { return $0.format < $1.format }
            if $0.pixels != $1.pixels { return $0.pixels < $1.pixels }
            if $0.bytes != $1.bytes { return $0.bytes < $1.bytes }
            return $0.relativePath < $1.relativePath
        }
        let count = min(50, ordered.count)
        guard count > 0 else { return [] }
        return (0..<count).map { ordered[(2 * $0 + 1) * ordered.count / (2 * count)] }
    }

    static func scan(_ source: URL) throws -> (sample: [ImageSampleCandidate], total: Int, unreadable: Int) {
        let root = FolderScanner.canonical(source)
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isPackageKey, .isSymbolicLinkKey, .fileSizeKey]
        let rootValues = try root.resourceValues(forKeys: keys)
        guard rootValues.isDirectory == true, rootValues.isPackage != true else {
            throw ConversionError.invalidFolders("Choose a source folder to estimate image sizes.")
        }
        var unreadable = 0
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants], errorHandler: { _, _ in
                unreadable += 1
                return true
            }) else { throw ConversionError.failed("Unable to sample this folder.") }
        var candidates: [ImageSampleCandidate] = []
        for case let url as URL in files {
            try Task.checkCancellation()
            do {
                let values = try url.resourceValues(forKeys: keys)
                // The enumerator already skips package descendants and never follows symlinks.
                // Calling skipDescendants on a file link can suppress the next real directory.
                if values.isSymbolicLink == true || values.isPackage == true { continue }
                guard values.isRegularFile == true, FolderScanner.classify(url) == .image else { continue }
                let dimensions: (String, Double) = autoreleasepool {
                    guard let image = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
                        return (url.pathExtension.lowercased(), 4_000_000)
                    }
                    let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any]
                    let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
                    let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
                    let pixels = width * height
                    return ((CGImageSourceGetType(image) as String?) ?? url.pathExtension.lowercased(),
                            pixels.isFinite && pixels > 0 ? pixels : 4_000_000)
                }
                candidates.append(.init(url: url, relativePath: FolderScanner.relative(url, to: root),
                    format: dimensions.0, pixels: dimensions.1, bytes: Int64(values.fileSize ?? 0)))
            } catch { unreadable += 1 }
        }
        return (select(candidates), candidates.count, unreadable)
    }
}

public actor ImageSizeEstimator {
    public typealias ProgressHandler = @Sendable (ImageEstimateProgress) async -> Void
    typealias Encoder = @Sendable (URL, URL, ConversionOptions) throws -> Void
    private let encoder: Encoder
    private let temporaryRoot: URL
    private var cache: [CacheKey: Measurement] = [:]
    private var cacheOrder: [CacheKey] = []
    private var running = false

    public init() {
        encoder = ImageConverter.convert
        temporaryRoot = FileManager.default.temporaryDirectory
    }
    init(temporaryRoot: URL, encoder: @escaping Encoder) {
        self.temporaryRoot = temporaryRoot
        self.encoder = encoder
    }

    public func estimate(source: URL, format: ImageFormat, quality: Int,
                         onProgress: @escaping ProgressHandler = { _ in }) async throws -> ImageSizeEstimate {
        // The UI cancels and awaits its previous request before starting the next one.
        guard !running else { throw ConversionError.failed("An estimate is already running.") }
        running = true
        defer { running = false }
        try Task.checkCancellation()
        let quality = min(100, max(1, quality))
        await onProgress(.init(phase: .scanning, completed: 0, total: 0))
        let inventory = try ImageSampler.scan(source)
        let options = ConversionOptions(imageFormat: format, imageQuality: Double(quality) / 100)
        let workspace = temporaryRoot.appendingPathComponent("MediaConverter-Estimate-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: workspace) }
        var results: [Measurement] = []
        let limits = WorkerLimits(images: min(4, WorkerLimits().images))
        let priorCache = cache
        var lastProgress = ContinuousClock.now
        await onProgress(.init(phase: .measuring, completed: 0, total: inventory.sample.count))
        try await withThrowingTaskGroup(of: Trial.self) { group in
            var index = 0, active = 0
            var memory: UInt64 = 0
            while index < inventory.sample.count || active > 0 {
                try Task.checkCancellation()
                while index < inventory.sample.count, active < limits.images {
                    let candidate = inventory.sample[index]
                    let remaining = limits.memoryBytes > memory ? limits.memoryBytes - memory : 0
                    guard candidate.memory <= remaining || active == 0 else { break }
                    index += 1; active += 1; memory += candidate.memory
                    group.addTask { [encoder] in
                        try Self.measure(candidate, workspace: workspace, options: options,
                                         quality: quality, cache: priorCache, encoder: encoder)
                    }
                }
                guard let trial = try await group.next() else { break }
                active -= 1; memory -= trial.memory
                results.append(trial.measurement)
                if let key = trial.key, trial.measurement.cacheable { remember(trial.measurement, for: key) }
                if lastProgress.duration(to: .now) >= .milliseconds(100) || results.count == inventory.sample.count {
                    lastProgress = .now
                    await onProgress(.init(phase: .measuring, completed: results.count, total: inventory.sample.count))
                }
            }
        }
        try Task.checkCancellation()
        let measured = results.filter { $0.status == .measured }
        return ImageSizeEstimate(format: format, quality: quality, discoveredImages: inventory.total,
            sampledCount: results.count, measuredCount: measured.count,
            skippedCount: results.filter { $0.status == .skipped }.count,
            failedCount: results.filter { $0.status == .failed }.count, unreadableCount: inventory.unreadable,
            largerCount: measured.filter { $0.outputBytes > $0.sourceBytes }.count,
            sourceBytes: measured.reduce(0) { $0 + $1.sourceBytes }, outputBytes: measured.reduce(0) { $0 + $1.outputBytes })
    }

    private struct CacheKey: Hashable, Sendable {
        let path: String
        let digest: String
        let format: ImageFormat
        let quality: Int
    }
    private struct Measurement: Sendable {
        enum Status: Sendable { case measured, skipped, failed }
        let status: Status
        let sourceBytes: Int64
        let outputBytes: Int64
        var cacheable: Bool { status == .measured || status == .skipped }
    }
    private struct Trial: Sendable {
        let key: CacheKey?
        let measurement: Measurement
        let memory: UInt64
    }

    private func remember(_ value: Measurement, for key: CacheKey) {
        if cache[key] == nil { cacheOrder.append(key) }
        cache[key] = value
        if cacheOrder.count > 5_000 { cache.removeValue(forKey: cacheOrder.removeFirst()) }
    }

    private nonisolated static func measure(_ candidate: ImageSampleCandidate, workspace: URL,
        options: ConversionOptions, quality: Int, cache: [CacheKey: Measurement], encoder: Encoder) throws -> Trial {
        let temporary = workspace.appendingPathComponent("\(UUID()).\(options.imageFormat.fileExtension)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        var key: CacheKey?
        do {
            try Task.checkCancellation()
            let before = try fingerprint(candidate.url)
            let currentKey = CacheKey(path: candidate.url.path, digest: before.digest, format: options.imageFormat, quality: quality)
            key = currentKey
            if let cached = cache[currentKey] { return Trial(key: key, measurement: cached, memory: candidate.memory) }
            try encoder(candidate.url, temporary, options)
            try Task.checkCancellation()
            // Do not publish/cache a measurement for a file that changed during its trial conversion.
            let after = try fingerprint(candidate.url)
            guard before.digest == after.digest else { throw ConversionError.failed("The source changed during sampling.") }
            let outputBytes = Int64((try temporary.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0)
            return Trial(key: key, measurement: .init(status: .measured, sourceBytes: before.bytes, outputBytes: outputBytes), memory: candidate.memory)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            if case ConversionError.unsupported = error {
                return Trial(key: key, measurement: .init(status: .skipped, sourceBytes: 0, outputBytes: 0), memory: candidate.memory)
            }
            return Trial(key: nil, measurement: .init(status: .failed, sourceBytes: 0, outputBytes: 0), memory: candidate.memory)
        }
    }

    private nonisolated static func fingerprint(_ url: URL) throws -> (digest: String, bytes: Int64) {
        // Content hashes invalidate a cached result even if a file was replaced with the same size/date.
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var digest = SHA256()
        var bytes: Int64 = 0
        while let data = try handle.read(upToCount: 1_024 * 1_024), !data.isEmpty {
            try Task.checkCancellation()
            digest.update(data: data); bytes += Int64(data.count)
        }
        return (digest.finalize().map { String(format: "%02x", $0) }.joined(), bytes)
    }
}
