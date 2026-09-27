import Foundation
import Testing
@testable import MediaCore

private final class EncodingCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    private var active = 0
    private var peak = 0
    var calls: Int { lock.withLock { value } }
    var peakWorkers: Int { lock.withLock { peak } }
    func begin() { lock.withLock { value += 1; active += 1; peak = max(peak, active) } }
    func end() { lock.withLock { active -= 1 } }
}

@Suite struct EstimatorTests {
    @Test func reproducibleSampleIsBoundedAndSpreadAcrossFormats() {
        var candidates: [ImageSampleCandidate] = []
        for index in 0..<300 {
            let name = "\(index).jpg"
            let url = URL(fileURLWithPath: "/synthetic").appendingPathComponent(name)
            let pixels = Double(index % 150 + 1) * 1_000_000.0
            candidates.append(ImageSampleCandidate(url: url, relativePath: name,
                format: index < 150 ? "jpeg" : "png", pixels: pixels, bytes: Int64(index + 1) * 1_000))
        }
        let sample = ImageSampler.select(candidates)
        #expect(sample.count == 50)
        #expect(Set(sample.map(\.url)).count == 50)
        #expect(sample.filter { $0.format == "jpeg" }.count == 25)
        #expect(sample.contains { $0.pixels < 10_000_000 })
        #expect(sample.contains { $0.pixels > 140_000_000 })
        #expect(sample.map(\.url) == ImageSampler.select(candidates.reversed()).map(\.url))
        #expect(ImageSampler.select(Array(candidates.prefix(7))).count == 7)
        #expect(ImageSampler.select([]).isEmpty)
    }

    @Test func reportsMeasuredSizesAndExcludesSkippedFailures() async throws {
        let w = try Workspace(); defer { w.clean() }
        try w.file("good.jpg", contents: Data(repeating: 1, count: 100))
        try w.file("unsupported.png", contents: Data(repeating: 2, count: 500))
        try w.file("corrupt.jpg", contents: Data(repeating: 3, count: 600))
        let temporary = w.root.appendingPathComponent("Estimates")
        let estimator = ImageSizeEstimator(temporaryRoot: temporary) { source, output, _ in
            if source.lastPathComponent == "unsupported.png" { throw ConversionError.unsupported("Unsupported fixture") }
            if source.lastPathComponent == "corrupt.jpg" { throw ConversionError.failed("Corrupt fixture") }
            try Data(repeating: 0, count: 200).write(to: output)
        }
        let result = try await estimator.estimate(source: w.source, format: .heic, quality: 95)
        #expect(result.discoveredImages == 3 && result.sampledCount == 3)
        #expect(result.measuredCount == 1 && result.skippedCount == 1 && result.failedCount == 1)
        #expect(result.averageOutputBytes == 200)
        #expect(result.sourceBytes == 100 && result.outputBytes == 200)
        #expect(result.sizeChange == 1 && result.largerCount == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: temporary.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: w.destination.path).isEmpty)
    }

    @Test func averageAndOverallChangeUseMatchingSuccessfulSources() async throws {
        let w = try Workspace(); defer { w.clean() }
        try w.file("small.jpg", contents: Data(repeating: 1, count: 150))
        try w.file("large.jpg", contents: Data(repeating: 2, count: 300))
        let estimator = ImageSizeEstimator(temporaryRoot: w.root.appendingPathComponent("Estimates")) { _, output, _ in
            try Data(repeating: 0, count: 200).write(to: output)
        }
        let result = try await estimator.estimate(source: w.source, format: .jpeg, quality: 80)
        #expect(result.averageOutputBytes == 200)
        #expect(result.largerCount == 1 && result.measuredCount == 2)
        #expect(abs(try #require(result.sizeChange) + 1.0 / 9) < 0.000_001)
    }

    @Test func cacheSeparatesFormatsQualityAndFileContents() async throws {
        let w = try Workspace(); defer { w.clean() }
        let file = try w.file("photo.jpg", contents: Data(repeating: 1, count: 128))
        let originalDate = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let counter = EncodingCounter()
        let estimator = ImageSizeEstimator(temporaryRoot: w.root.appendingPathComponent("Estimates")) { source, output, options in
            counter.begin(); defer { counter.end() }
            let first = Int(try Data(contentsOf: source).first ?? 0)
            try Data(repeating: 0, count: first + Int(options.imageQuality * 100)).write(to: output)
        }
        let first = try await estimator.estimate(source: w.source, format: .heic, quality: 95)
        let again = try await estimator.estimate(source: w.source, format: .heic, quality: 95)
        #expect(first.outputBytes == again.outputBytes && counter.calls == 1)
        _ = try await estimator.estimate(source: w.source, format: .heic, quality: 50)
        _ = try await estimator.estimate(source: w.source, format: .jpeg, quality: 50)
        #expect(counter.calls == 3)
        try Data(repeating: 2, count: 128).write(to: file)
        if let originalDate { try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: file.path) }
        let changed = try await estimator.estimate(source: w.source, format: .heic, quality: 95)
        #expect(counter.calls == 4)
        #expect(changed.outputBytes == first.outputBytes + 1)
    }

    @Test func atMostFiftyEncodesWithBoundedWorkersAndCleanTemporaryFiles() async throws {
        let w = try Workspace(); defer { w.clean() }
        for index in 0..<80 { try w.file("Nested/\(index).jpg") }
        try w.file("video.mov"); try w.file("note.txt"); try w.file(".hidden.jpg")
        try w.file("Fixture.app/inside.jpg")
        try FileManager.default.createSymbolicLink(at: w.source.appendingPathComponent("Alias.jpg"),
                                                  withDestinationURL: w.source.appendingPathComponent("Nested/1.jpg"))
        let counter = EncodingCounter()
        let temporary = w.root.appendingPathComponent("Estimates")
        let estimator = ImageSizeEstimator(temporaryRoot: temporary) { _, output, _ in
            counter.begin(); defer { counter.end() }
            Thread.sleep(forTimeInterval: 0.005)
            try Data(repeating: 0, count: 10).write(to: output)
        }
        let result = try await estimator.estimate(source: w.source, format: .heic, quality: 75)
        #expect(counter.calls == 50)
        #expect(counter.peakWorkers <= 4 && counter.peakWorkers > 1)
        #expect(result.sampledCount == 50 && result.discoveredImages == 80)
        #expect(try FileManager.default.contentsOfDirectory(atPath: temporary.path).isEmpty)
        let plan = try FolderScanner.scan(source: w.source, destination: w.destination, options: .init())
        #expect(plan.jobs.filter { $0.kind == .image }.count == 80)
    }

    @Test func cancellationCleansUpAndEstimatorCanBeReused() async throws {
        let w = try Workspace(); defer { w.clean() }
        for index in 0..<12 { try w.file("\(index).jpg") }
        let counter = EncodingCounter()
        let temporary = w.root.appendingPathComponent("Estimates")
        let estimator = ImageSizeEstimator(temporaryRoot: temporary) { _, output, _ in
            counter.begin(); defer { counter.end() }
            try Data("partial".utf8).write(to: output)
            Thread.sleep(forTimeInterval: 0.06)
        }
        let task = Task { try await estimator.estimate(source: w.source, format: .heic, quality: 95) }
        for _ in 0..<100 {
            if counter.calls > 0 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        task.cancel()
        do { _ = try await task.value; Issue.record("The cancelled estimate returned a result.") }
        catch { #expect(error is CancellationError) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: temporary.path).isEmpty)
        let result = try await estimator.estimate(source: w.source, format: .heic, quality: 70)
        #expect(result.measuredCount == 12)
    }

    @Test func emptyAndUnconvertibleSamplesDoNotReportZeroByteEstimates() async throws {
        let w = try Workspace(); defer { w.clean() }
        let estimator = ImageSizeEstimator(temporaryRoot: w.root.appendingPathComponent("Estimates")) { _, _, _ in
            throw ConversionError.unsupported("Unsupported fixture")
        }
        let empty = try await estimator.estimate(source: w.source, format: .jpeg, quality: 90)
        #expect(empty.discoveredImages == 0 && empty.averageOutputBytes == nil && empty.sizeChange == nil)
        try w.file("alpha.png")
        let skipped = try await estimator.estimate(source: w.source, format: .jpeg, quality: 90)
        #expect(skipped.skippedCount == 1 && skipped.measuredCount == 0)
        #expect(skipped.averageOutputBytes == nil && skipped.sizeChange == nil)
    }

    @Test func sourceChangedDuringEncodingIsNotCached() async throws {
        let w = try Workspace(); defer { w.clean() }
        try w.file("photo.jpg")
        let counter = EncodingCounter()
        let estimator = ImageSizeEstimator(temporaryRoot: w.root.appendingPathComponent("Estimates")) { source, output, _ in
            counter.begin(); defer { counter.end() }
            try Data("encoded".utf8).write(to: output)
            if counter.calls == 1 { try Data("changed".utf8).write(to: source) }
        }
        let changed = try await estimator.estimate(source: w.source, format: .heic, quality: 95)
        #expect(changed.failedCount == 1 && changed.measuredCount == 0)
        let retry = try await estimator.estimate(source: w.source, format: .heic, quality: 95)
        #expect(retry.measuredCount == 1 && counter.calls == 2)
    }
}
