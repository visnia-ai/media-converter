import Foundation
import Testing
@preconcurrency import AVFoundation
@testable import MediaCore

@Suite struct FFmpegPolicyTests {
    @Test func allExtensionsAndCollisions() throws {
        let w = try Workspace(); defer { w.clean() }
        for ext in VideoSourceTypes.all { try w.file("clip.\(ext.uppercased())") }
        let plan = try FolderScanner.scan(source: w.source, destination: w.destination, options: .init())
        #expect(plan.jobs.count == VideoSourceTypes.all.count)
        #expect(Set(plan.jobs.map(\.destination)).count == VideoSourceTypes.all.count)
        #expect(plan.jobs.allSatisfy { $0.destination.pathExtension == "mp4" })
    }

    @Test func rejectsLossyTrackChoices() throws {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        func probe(_ extra: String = "", video: String = "") throws -> FFmpegProbe {
            try decoder.decode(FFmpegProbe.self, from: Data("""
            {"streams":[{"index":0,"codec_type":"video","codec_name":"h264","width":160,"height":120,"pix_fmt":"yuv420p"\(video)}\(extra)]}
            """.utf8))
        }
        try probe().validateInput()
        for track in [
            #",{"index":1,"codec_type":"subtitle","codec_name":"ass"}"#,
            #",{"index":1,"codec_type":"attachment","codec_name":"ttf"}"#,
            #",{"index":1,"codec_type":"audio","codec_name":"dts","channels":6,"sample_rate":"48000"}"#,
            #",{"index":1,"codec_type":"video","codec_name":"h264"}"#
        ] { #expect(throws: ConversionError.self) { try probe(track).validateInput() } }
        #expect(throws: ConversionError.self) { try probe(video: #", "side_data_list":[{"side_data_type":"Mastering display metadata"}]"#).validateInput() }
        #expect(throws: ConversionError.self) { try FFmpegProbe.validatePixels("yuva420p") }
        #expect(throws: ConversionError.self) { try FFmpegProbe.validateSideData("DOVI configuration record") }
        let floatVideo = try decoder.decode(FFmpegProbe.self, from: Data(#"{"streams":[{"index":0,"codec_type":"video","codec_name":"rawvideo","width":160,"height":120,"pix_fmt":"gbrpf32le"}]}"#.utf8))
        #expect(throws: ConversionError.self) { try floatVideo.validateInput() }
        #expect(throws: ConversionError.self) {
            try probe(video: #", "side_data_list":[{"side_data_type":"Display Matrix","rotation":0,"displaymatrix":"00000000: -65536 0 0\n00000001: 0 65536 0\n00000002: 0 0 1073741824"}]"#).validateInput()
        }
    }

    @Test func processFailureAndCancellation() async throws {
        await #expect(throws: ConversionError.self) {
            _ = try await FFmpegProcess.run(executable: URL(fileURLWithPath: "/does-not-exist"), arguments: [])
        }
        let clock = ContinuousClock(), started = clock.now
        let task = Task { try await FFmpegProcess.run(executable: URL(fileURLWithPath: "/bin/sleep"), arguments: ["20"]) }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(started.duration(to: clock.now) < .seconds(3))
        let result = try await FFmpegProcess.run(executable: URL(fileURLWithPath: "/usr/bin/false"), arguments: [])
        #expect(result.status != 0)
    }

    @Test func seekableDescriptorsAndExistingOutput() async throws {
        let source = try #require(Bundle.module.url(forResource: "h264", withExtension: "mkv", subdirectory: "Fixtures/Video"))
        let probe = try await FFmpegProbe.read(source)
        #expect(probe.video?.codecName == "h264")
        let w = try Workspace(); defer { w.clean() }
        let output = try w.file("existing.mp4", contents: Data("original".utf8))
        await #expect(throws: ConversionError.self) {
            _ = try await FFmpegProcess.run(executable: FFmpegTools.executable("ffmpeg"), arguments: [], source: source, destination: output)
        }
        #expect(try String(contentsOf: output, encoding: .utf8) == "original")
    }
}

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MEDIA_CONVERTER_CODEC_TESTS"] == "1"))
struct FFmpegCodecTests {
    static let containers: [(String, String)] = [
        ("h264.mkv", "mkv"), ("mpeg4.avi", "avi"), ("vp8.webm", "webm"), ("vp9.webm", "webm"),
        ("mpeg2.ts", "ts"), ("mpeg2.ts", "mts"), ("mpeg2.ts", "m2ts"), ("mpeg2.mpg", "mpg"),
        ("mpeg2.mpg", "mpeg"), ("mpeg2.vob", "vob"), ("wmv2.asf", "wmv"), ("wmv2.asf", "asf"),
        ("sorenson.flv", "flv"), ("h263.3gp", "3gp"), ("h263.3g2", "3g2"), ("theora.ogv", "ogv"),
        ("variable.mkv", "mkv"), ("chapters.mkv", "mkv"), ("text-subtitle.3gp", "3gp"), ("hlg.mkv", "mkv"), ("pq.mkv", "mkv")
    ]
    @Test(arguments: containers) func containersConvert(fixture: String, ext: String) async throws {
        let w = try Workspace(); defer { w.clean() }
        let input = try #require(Bundle.module.url(forResource: fixture, withExtension: nil, subdirectory: "Fixtures/Video"))
        let source = w.source.appendingPathComponent("Space & Unicode é.\(ext.uppercased())")
        try FileManager.default.copyItem(at: input, to: source)
        let result = try await BatchCoordinator().run(source: w.source, destination: w.destination, options: .init(), onProgress: { _ in })
        try #require(result.converted == 1, "\(fixture): \(result.issues.map(\.message))")
        let output = w.destination.appendingPathComponent("Space & Unicode é.mp4")
        let probe = try await FFmpegProbe.read(output)
        #expect(probe.video?.codecName == "hevc")
        #expect(probe.audio.count == 1)
        #expect(try Data(contentsOf: input) == Data(contentsOf: source))
        let again = try await BatchCoordinator().run(source: w.source, destination: w.destination, options: .init(), onProgress: { _ in })
        #expect(again.skipped == 1)
    }

    @Test func multipleAudioAndIncompatibleSubtitles() async throws {
        let w = try Workspace(); defer { w.clean() }
        for name in ["multiple-audio.mkv", "styled-subtitle.mkv"] {
            let input = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "Fixtures/Video"))
            try FileManager.default.copyItem(at: input, to: w.source.appendingPathComponent(name))
        }
        let result = try await BatchCoordinator().run(source: w.source, destination: w.destination, options: .init(), onProgress: { _ in })
        #expect(result.converted == 1 && result.skipped == 1 && result.failed == 0)
        let probe = try await FFmpegProbe.read(w.destination.appendingPathComponent("multiple-audio.mp4"))
        #expect(probe.audio.count == 2)
        #expect(!FileManager.default.fileExists(atPath: w.destination.appendingPathComponent("styled-subtitle.mp4").path))
    }

    @Test func activeHelperCancellationCleansBatchOutput() async throws {
        let w = try Workspace(); defer { w.clean() }
        let input = try #require(Bundle.module.url(forResource: "h264.mkv", withExtension: nil, subdirectory: "Fixtures/Video"))
        try FileManager.default.copyItem(at: input, to: w.source.appendingPathComponent("loop.mkv"))
        let coordinator = BatchCoordinator { job, output, _, _ in
            _ = try await FFmpegProcess.run(executable: FFmpegTools.executable("ffmpeg"), arguments: [
                "-v", "error", "-nostdin", "-re", "-stream_loop", "100", "-i", "fd:",
                "-map", "0", "-c", "copy", "-f", "mp4", "fd:"
            ], source: job.source, destination: output)
        }
        let task = Task { try await coordinator.run(source: w.source, destination: w.destination, options: .init(), onProgress: { _ in }) }
        for _ in 0..<100 {
            if try !FileManager.default.contentsOfDirectory(atPath: w.destination.path).isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        let result = try await task.value
        #expect(result.phase == .cancelled)
        #expect(try FileManager.default.contentsOfDirectory(atPath: w.destination.path).isEmpty)
    }

    @Test func qualityRotationAndHDR() async throws {
        let w = try Workspace(); defer { w.clean() }
        for hdr in [false, true] {
            let source: URL
            if hdr {
                source = try #require(Bundle.module.url(forResource: "hlg.mkv", withExtension: nil, subdirectory: "Fixtures/Video"))
            } else {
                source = w.source.appendingPathComponent("source.mov")
                try await Fixtures.video(source, audio: true)
            }
            for quality in [0.01, 0.2, 0.95, 1.0] {
                let destination = w.destination.appendingPathComponent("\(hdr)-\(quality).mp4")
                try await FFmpegVideoConverter.convert(source: source, destination: destination, quality: quality, progress: { _ in })
                let probe = try await FFmpegProbe.read(destination)
                #expect(probe.video?.depth == (hdr ? 10 : 8))
                #expect(abs(probe.video?.rotation ?? 0) == (hdr ? 0 : 90))
                let frameTimes = try await Fixtures.frameTimes(AVURLAsset(url: destination))
                let expectedFrames = hdr ? 24 : 30
                // AVAssetReader emits a leading gap sample when audio begins before
                // the video track. The converter separately checks every encoded frame.
                let videoStart = probe.video?.startTime.flatMap(Double.init) ?? 0
                let videoFrames = frameTimes.filter { $0 + 0.000001 >= videoStart }
                #expect(videoFrames.count == expectedFrames)
            }
            #expect(try Data(contentsOf: w.destination.appendingPathComponent("\(hdr)-0.2.mp4")).count <
                    Data(contentsOf: w.destination.appendingPathComponent("\(hdr)-0.95.mp4")).count)
        }
    }
}
