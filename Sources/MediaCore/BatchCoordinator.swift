import Foundation

public actor BatchCoordinator {
    public typealias ProgressHandler = @Sendable (BatchSnapshot) async -> Void
    typealias JobConverter = @Sendable (ConversionJob, URL, ConversionOptions, @escaping @Sendable (Double) async -> Void) async throws -> Void
    private let converter: JobConverter
    private var snapshot = BatchSnapshot()
    private var fractions: [Int: Double] = [:]
    private var lastUpdate = ContinuousClock.now
    private var running = false

    public init() { converter = Self.convert }
    init(converter: @escaping JobConverter) { self.converter = converter }

    public func run(source: URL, destination: URL, options: ConversionOptions,
                    limits: WorkerLimits = WorkerLimits(), onProgress: @escaping ProgressHandler) async throws -> BatchSnapshot {
        guard !running else { throw ConversionError.failed("A conversion is already running.") }
        running = true
        defer { running = false }
        snapshot = BatchSnapshot(); fractions = [:]
        await onProgress(snapshot)
        let plan = try FolderScanner.scan(source: source, destination: destination, options: options)
        snapshot.issues = plan.issues
        snapshot.failed = plan.issues.count
        let images = plan.jobs.filter { $0.kind == .image }
        let videos = plan.jobs.filter { $0.kind == .video }
        snapshot.totalImages = images.count; snapshot.totalVideos = videos.count
        snapshot.phase = .converting
        await onProgress(snapshot)
        await withTaskGroup(of: JobResult.self) { group in
            var imageIndex = 0, videoIndex = 0, activeImages = 0, activeVideos = 0
            var reservedMemory: UInt64 = 0
            while imageIndex < images.count || videoIndex < videos.count || activeImages + activeVideos > 0 {
                if Task.isCancelled { group.cancelAll() }
                if !Task.isCancelled {
                    for kind in [MediaKind.image, .video] {
                        while true {
                            let index = kind == .image ? imageIndex : videoIndex
                            let jobs = kind == .image ? images : videos
                            let active = kind == .image ? activeImages : activeVideos
                            let limit = kind == .image ? limits.images : limits.videos
                            guard index < jobs.count, active < limit else { break }
                            let job = jobs[index]
                            let remaining = limits.memoryBytes > reservedMemory ? limits.memoryBytes - reservedMemory : 0
                            guard job.estimatedMemory <= remaining || activeImages + activeVideos == 0 else { break }
                            if kind == .image { imageIndex += 1; activeImages += 1 }
                            else { videoIndex += 1; activeVideos += 1 }
                            reservedMemory += job.estimatedMemory
                            group.addTask {
                                await Self.perform(job: job, root: plan.destination, options: options, converter: self.converter) { value in
                                    await self.update(job: job.id, fraction: value, handler: onProgress)
                                }
                            }
                        }
                    }
                }
                guard let result = await group.next() else { break }
                reservedMemory -= result.job.estimatedMemory
                if result.job.kind == .image { activeImages -= 1 } else { activeVideos -= 1 }
                fractions.removeValue(forKey: result.job.id)
                if case .cancelled = result.outcome { continue }
                if result.job.kind == .image { snapshot.completedImages += 1 } else { snapshot.completedVideos += 1 }
                switch result.outcome {
                case .converted(let bytes):
                    snapshot.converted += 1
                    snapshot.sourceBytes += result.job.sourceBytes; snapshot.outputBytes += bytes
                case .skipped(let message):
                    snapshot.skipped += 1
                    snapshot.issues.append(.init(path: result.job.relativePath, message: message))
                case .failed(let message):
                    snapshot.failed += 1
                    snapshot.issues.append(.init(path: result.job.relativePath, message: message))
                case .cancelled: break
                }
                refreshProgress()
                if lastUpdate.duration(to: .now) >= .milliseconds(100) {
                    await onProgress(snapshot); lastUpdate = .now
                }
            }
        }
        snapshot.phase = Task.isCancelled ? .cancelled : .finished
        if !Task.isCancelled { snapshot.progress = 1 }
        await onProgress(snapshot)
        return snapshot
    }

    private func update(job: Int, fraction: Double, handler: ProgressHandler) async {
        fractions[job] = fraction
        refreshProgress()
        if lastUpdate.duration(to: .now) >= .milliseconds(100) {
            lastUpdate = .now
            await handler(snapshot)
        }
    }

    private func refreshProgress() {
        snapshot.progress = snapshot.total > 0 ? min(1, (Double(snapshot.completed) + fractions.values.reduce(0, +)) / Double(snapshot.total)) : 0
    }

    private struct JobResult: Sendable {
        enum Outcome: Sendable { case converted(Int64), skipped(String), failed(String), cancelled }
        let job: ConversionJob
        let outcome: Outcome
    }

    private nonisolated static func perform(job: ConversionJob, root: URL, options: ConversionOptions,
                                           converter: JobConverter,
                                           progress: @escaping @Sendable (Double) async -> Void) async -> JobResult {
        do {
            try Task.checkCancellation()
            let prepared = try OutputFiles.prepare(job.destination, root: root)
            try await converter(job, prepared.temporary, options, progress)
            let bytes = try prepared.publish(source: job.source)
            return .init(job: job, outcome: .converted(bytes))
        } catch {
            if error is CancellationError || Task.isCancelled { return .init(job: job, outcome: .cancelled) }
            if let error = error as? ConversionError {
                switch error {
                case .unsupported, .outputExists: return .init(job: job, outcome: .skipped(error.localizedDescription))
                default: return .init(job: job, outcome: .failed(error.localizedDescription))
                }
            }
            let nsError = error as NSError
            // Avoid embedding absolute user paths in errors or diagnostic exports.
            return .init(job: job, outcome: .failed("Conversion failed (\(nsError.domain), \(nsError.code))."))
        }
    }

    private nonisolated static func convert(job: ConversionJob, temporary: URL, options: ConversionOptions,
                                           progress: @escaping @Sendable (Double) async -> Void) async throws {
        switch job.kind {
        case .image: try ImageConverter.convert(source: job.source, destination: temporary, options: options)
        case .video: try await VideoConverter.convert(source: job.source, destination: temporary,
                                                      quality: options.videoQuality, progress: progress)
        }
    }
}
