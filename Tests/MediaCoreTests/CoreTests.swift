import Foundation
import Testing
@testable import MediaCore

struct Workspace {
    let root: URL
    let source: URL
    let destination: URL
    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MediaConverterTests-\(UUID())")
        source = root.appendingPathComponent("Source")
        destination = root.appendingPathComponent("Destination")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    }
    func clean() { try? FileManager.default.removeItem(at: root) }
    @discardableResult func file(_ relative: String, contents: Data = Data("fixture".utf8)) throws -> URL {
        let url = source.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url)
        return url
    }
}

@Suite struct CoreTests {
    @Test(arguments: ImageFormat.allCases)
    func folderHierarchyAndCollisions(format: ImageFormat) throws {
        let w = try Workspace(); defer { w.clean() }
        try w.file("Holiday/Photo.jpg"); try w.file("Holiday/Photo.png")
        try w.file("Holiday/Clip.mov"); try w.file("Holiday/Ignore.txt")
        try w.file(".hidden.jpg")
        try FileManager.default.createSymbolicLink(at: w.source.appendingPathComponent("Link.jpg"),
                                                  withDestinationURL: w.source.appendingPathComponent("Holiday/Photo.jpg"))
        let options = ConversionOptions(imageFormat: format)
        let plan = try FolderScanner.scan(source: w.source, destination: w.destination, options: options)
        #expect(plan.jobs.count == 3)
        #expect(Set(plan.jobs.map { FolderScanner.relative($0.destination, to: w.destination) }) ==
                Set(["Holiday/Photo.jpg.\(format.fileExtension)", "Holiday/Photo.png.\(format.fileExtension)", "Holiday/Clip.mp4"]))
        let again = try FolderScanner.scan(source: w.source, destination: w.destination, options: options)
        #expect(plan.jobs.map(\.destination) == again.jobs.map(\.destination))
    }

    @Test func overlappingFoldersRejected() throws {
        let w = try Workspace(); defer { w.clean() }
        let nested = w.source.appendingPathComponent("Nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) { try FolderScanner.validate(source: w.source, destination: w.source) }
        #expect(throws: (any Error).self) { try FolderScanner.validate(source: w.source, destination: nested) }
        #expect(throws: (any Error).self) { try FolderScanner.validate(source: nested, destination: w.source) }
        let link = w.root.appendingPathComponent("Alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: nested)
        #expect(throws: (any Error).self) { try FolderScanner.validate(source: w.source, destination: link) }
        _ = try FolderScanner.validate(source: w.source, destination: w.destination)
    }

    @Test func cr3HierarchyAndSidecarCollisions() throws {
        let w = try Workspace(); defer { w.clean() }
        try w.file("Trip/Photo.CR3"); try w.file("Trip/Photo.jpg")
        try w.file("Trip/Another.cr3")
        for format in ImageFormat.allCases {
            let plan = try FolderScanner.scan(source: w.source, destination: w.destination,
                                              options: .init(imageFormat: format))
            #expect(plan.jobs.count == 3)
            #expect(plan.jobs.allSatisfy { $0.kind == .image })
            #expect(Set(plan.jobs.map { FolderScanner.relative($0.destination, to: w.destination) }) ==
                    Set(["Trip/Photo.CR3.\(format.fileExtension)", "Trip/Photo.jpg.\(format.fileExtension)",
                         "Trip/Another.\(format.fileExtension)"]))
        }
    }

    @Test func unreadableCR3ReportsIssueAndCleansUp() async throws {
        let w = try Workspace(); defer { w.clean() }
        try w.file("damaged.CR3")
        let result = try await BatchCoordinator().run(source: w.source, destination: w.destination,
                                                     options: .init(), onProgress: { _ in })
        #expect(result.skipped == 1)
        #expect(result.completed == 1)
        #expect(result.issues.first?.message.contains("CR3") == true)
        #expect(try FileManager.default.contentsOfDirectory(atPath: w.destination.path).isEmpty)
    }

    @Test func refusesExistingFilesAndOutputSymlinks() throws {
        let w = try Workspace(); defer { w.clean() }
        let output = w.destination.appendingPathComponent("image.jpg")
        try Data("original".utf8).write(to: output)
        #expect(throws: (any Error).self) { try OutputFiles.prepare(output, root: w.destination) }
        let link = w.destination.appendingPathComponent("Nested")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: w.source)
        #expect(throws: (any Error).self) {
            try OutputFiles.prepare(link.appendingPathComponent("image.jpg"), root: w.destination)
        }
        #expect(try String(contentsOf: output, encoding: .utf8) == "original")
    }

    @Test func corruptFilesDoNotStopBatchAndCleanup() async throws {
        let w = try Workspace(); defer { w.clean() }
        try w.file("bad.jpg"); try w.file("bad.mkv")
        let result = try await BatchCoordinator().run(source: w.source, destination: w.destination,
                                                     options: .init(), onProgress: { _ in })
        // MKV is recognized by the video engine; corrupt bytes are a failure, not a format skip.
        #expect(result.failed == 2)
        #expect(result.skipped == 0)
        #expect(result.completed == 2)
        #expect(result.progress == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: w.destination.path).isEmpty)
    }

    @Test(arguments: ImageFormat.allCases)
    func existingOutputSkippedRegardlessOfQuality(format: ImageFormat) async throws {
        let w = try Workspace(); defer { w.clean() }
        try w.file("photo.jpg")
        let output = w.destination.appendingPathComponent("photo.\(format.fileExtension)")
        try Data("existing".utf8).write(to: output)
        let result = try await BatchCoordinator().run(source: w.source, destination: w.destination,
                                                     options: .init(imageFormat: format, imageQuality: 0.2), onProgress: { _ in })
        #expect(result.skipped == 1)
        #expect(result.failed == 0)
        #expect(try String(contentsOf: output, encoding: .utf8) == "existing")
    }

    @Test func cancellationStopsQueuedWork() async throws {
        let w = try Workspace(); defer { w.clean() }
        for i in 0..<100 { try w.file("\(i).jpg") }
        let task = Task {
            try await BatchCoordinator().run(source: w.source, destination: w.destination,
                                             options: .init(), limits: .init(images: 1, videos: 1), onProgress: { _ in })
        }
        task.cancel()
        do {
            let result = try await task.value
            #expect(result.phase == .cancelled)
            #expect(result.completed < result.total)
        } catch { #expect(error is CancellationError) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: w.destination.path).isEmpty)
    }

    @Test func normalizedQualityAndWorkerLimits() {
        let options = ConversionOptions(imageQuality: -.infinity, videoQuality: 2)
        #expect(options.imageQuality == 0.95)
        #expect(options.videoQuality == 1)
        #expect(ConversionOptions(imageQuality: -2).imageQuality == 0.01)
        #expect(WorkerLimits().images <= 8)
        #expect(WorkerLimits(images: 0, videos: 0, memoryBytes: 0).images == 1)
    }

    @Test func workersRespectConcurrencyAndMemory() async throws {
        let w = try Workspace(); defer { w.clean() }
        for i in 0..<8 { try w.file("\(i).jpg") }
        for i in 0..<4 { try w.file("\(i).mov") }
        actor Meter {
            var images = 0, videos = 0, peakImages = 0, peakVideos = 0
            var memory: UInt64 = 0, peakMemory: UInt64 = 0
            func enter(_ job: ConversionJob) {
                if job.kind == .image { images += 1 } else { videos += 1 }
                memory += job.estimatedMemory
                peakImages = max(images, peakImages); peakVideos = max(videos, peakVideos)
                peakMemory = max(memory, peakMemory)
            }
            func leave(_ job: ConversionJob) {
                if job.kind == .image { images -= 1 } else { videos -= 1 }
                memory -= job.estimatedMemory
            }
        }
        let meter = Meter()
        let coordinator = BatchCoordinator { job, output, _, _ in
            await meter.enter(job)
            try await Task.sleep(for: .milliseconds(25))
            try Data("converted".utf8).write(to: output)
            await meter.leave(job)
        }
        let result = try await coordinator.run(source: w.source, destination: w.destination, options: .init(),
            limits: .init(images: 3, videos: 1, memoryBytes: 512 * 1_024 * 1_024), onProgress: { _ in })
        #expect(result.converted == 12)
        #expect(await meter.peakImages == 3)
        #expect(await meter.peakVideos == 1)
        #expect(await meter.peakMemory <= 512 * 1_024 * 1_024)
    }

    @Test func activeCancellationRemovesTemporaryOutput() async throws {
        let w = try Workspace(); defer { w.clean() }
        try w.file("photo.jpg")
        let coordinator = BatchCoordinator { _, output, _, progress in
            try Data("partial".utf8).write(to: output)
            await progress(0.5)
            try await Task.sleep(for: .seconds(10))
        }
        let task = Task {
            try await coordinator.run(source: w.source, destination: w.destination, options: .init(), onProgress: { _ in })
        }
        for _ in 0..<100 {
            if try !FileManager.default.contentsOfDirectory(atPath: w.destination.path).isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        task.cancel()
        let result = try await task.value
        #expect(result.phase == .cancelled)
        #expect(result.converted == 0)
        #expect(try FileManager.default.contentsOfDirectory(atPath: w.destination.path).isEmpty)
    }
}
