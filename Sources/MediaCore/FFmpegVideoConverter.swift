import Foundation
import VideoToolbox

enum FFmpegVideoConverter {
    static func convert(source: URL, destination: URL, quality: Double,
                        progress: @escaping @Sendable (Double) async -> Void) async throws {
        try Task.checkCancellation()
        let info = try await FFmpegProbe.read(source)
        try info.validateInput()
        let video = info.video!
        let normalizedQuality = quality.isFinite ? min(1, max(0.01, quality)) : 0.95
        let encoder = try VideoConverter.qualityEncoder(width: Int32(video.width!), height: Int32(video.height!), quality: normalizedQuality)
        let hardware = encoder[kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String] as? Bool ?? true
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("MediaConverterAudit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: temporary) }
        let timeline = temporary.appendingPathComponent("frames")
        guard FileManager.default.createFile(atPath: timeline.path, contents: nil) else {
            throw ConversionError.failed("Unable to create video validation data.")
        }
        let recorded = try FileHandle(forUpdating: timeline)
        defer { try? recorded.close() }
        let sourceAudit = FrameAudit(video: video, timeline: recorded, comparing: false)
        try await sourceAudit.read(source)
        var sourceAudio: [AudioTiming] = []
        for (index, stream) in info.audio.enumerated() { sourceAudio.append(try await AudioTiming.read(source, index: index, stream: stream)) }
        try recorded.seek(toOffset: 0)
        await progress(0.1)

        var arguments = [
            "-hide_banner", "-nostdin", "-nostats", "-v", "error", "-xerror",
            "-filter_threads", "1", "-threads", "2", "-err_detect", "explode",
            "-protocol_whitelist", "fd,pipe", "-noautorotate",
            "-copyts", "-start_at_zero", "-i", "fd:",
            "-map", "0", "-map_metadata", "0", "-map_chapters", "0", "-c", "copy",
            "-c:v:0", "hevc_videotoolbox", "-global_quality:v:0", String(Int((normalizedQuality * 100).rounded())),
            "-allow_sw", hardware ? "0" : "1", "-require_sw", hardware ? "0" : "1",
            "-pix_fmt:v:0", video.depth > 8 ? "p010le" : "nv12", "-profile:v:0", video.depth > 8 ? "main10" : "main",
            "-tag:v:0", "hvc1", "-fps_mode:v:0", "passthrough", "-enc_time_base:v:0", "demux",
            "-avoid_negative_ts", "disabled", "-threads", "2"
        ]
        for (option, value) in [("-color_primaries", video.colorPrimaries), ("-color_trc", video.colorTransfer),
                                ("-colorspace", video.colorSpace), ("-color_range", video.colorRange)] {
            if let value, value != "unknown", value != "unspecified" { arguments += [option, value] }
        }
        for (index, stream) in info.audio.enumerated() where !FFmpegProbe.copyAudio.contains(stream.codecName ?? "") {
            arguments += ["-c:a:\(index)", "aac", "-b:a:\(index)", stream.channels == 1 ? "128k" : "256k"]
        }
        arguments += ["-movflags", "use_metadata_tags", "-progress", "pipe:2", "-f", "mp4", "fd:"]
        var lastProgress = ContinuousClock.now
        let result = try await FFmpegProcess.run(executable: FFmpegTools.executable("ffmpeg"), arguments: arguments,
                                                source: source, destination: destination) { line in
            if line.hasPrefix("out_time_us="), let time = Double(line.dropFirst(12)), lastProgress.duration(to: .now) >= .milliseconds(100) {
                await progress(0.1 + 0.75 * min(1, max(0, time / 1_000_000 / max(sourceAudit.duration, 0.001))))
                lastProgress = .now
            }
        }
        guard result.status == 0 else { throw conversionFailure(result.diagnostic) }
        // VideoToolbox does not propagate FFmpeg frame display matrices. Restore the
        // display rotation by stream-copying, without a second lossy encode.
        if abs(video.rotation) > 0.001 {
            let rotated = destination.deletingLastPathComponent().appendingPathComponent(".mediaconverter-rotation-\(UUID().uuidString).mp4")
            defer { try? FileManager.default.removeItem(at: rotated) }
            let remux = try await FFmpegProcess.run(executable: FFmpegTools.executable("ffmpeg"), arguments: [
                "-v", "error", "-nostdin", "-protocol_whitelist", "fd", "-noautorotate",
                "-display_rotation:v:0", String(video.rotation), "-copyts", "-i", "fd:",
                "-map", "0", "-map_metadata", "0", "-map_chapters", "0", "-c", "copy",
                "-avoid_negative_ts", "disabled", "-movflags", "use_metadata_tags", "-f", "mp4", "fd:"
            ], source: destination, destination: rotated)
            guard remux.status == 0 else { throw conversionFailure(remux.diagnostic) }
            try Task.checkCancellation()
            try FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: rotated, to: destination)
        }
        await progress(0.85)
        let output = try await FFmpegProbe.read(destination)
        try validateOutput(source: info, output: output)
        let outputAudit = FrameAudit(video: output.video!, timeline: recorded, comparing: true)
        try await outputAudit.read(destination)
        guard sourceAudit.count == outputAudit.count, try recorded.read(upToCount: 1)?.isEmpty != false else {
            throw ConversionError.failed("The converted video lost or duplicated frames.")
        }
        for (index, stream) in output.audio.enumerated() {
            let after = try await AudioTiming.read(destination, index: index, stream: stream)
            let before = sourceAudio[index]
            guard abs((before.start - sourceAudit.firstTime!) - (after.start - outputAudit.firstTime!)) < 0.05,
                  abs(before.duration - after.duration) < 0.05 else {
                throw ConversionError.failed("The converted audio’s timing or duration changed unexpectedly.")
            }
        }
        try Task.checkCancellation()
        await progress(1)
    }

    static func conversionFailure(_ diagnostic: String) -> ConversionError {
        let text = diagnostic.lowercased()
        if ["not supported", "unsupported", "could not find tag", "not currently supported in container", "decoder not found",
            "unknown decoder", "encoder not found", "error setting bitrate property", "cannot create compression session"].contains(where: text.contains) {
            return .unsupported("A source track or encoder feature cannot be preserved in MP4.")
        }
        // Never expose raw stderr, which can include source metadata or filesystem paths.
        return .failed("Video conversion failed. The source may be corrupt or unreadable.")
    }

    static func validateOutput(source: FFmpegProbe, output: FFmpegProbe) throws {
        guard let before = source.video, let after = output.video, after.codecName == "hevc",
              before.width == after.width, before.height == after.height, before.depth <= after.depth,
              abs(before.rotation - after.rotation) < 0.01,
              aspect(before.sampleAspectRatio) == aspect(after.sampleAspectRatio),
              source.audio.count == output.audio.count else {
            throw ConversionError.failed("The converted video’s dimensions, orientation, depth, or audio changed unexpectedly.")
        }
        for (original, converted) in [(before.colorPrimaries, after.colorPrimaries), (before.colorTransfer, after.colorTransfer),
                                      (before.colorSpace, after.colorSpace), (before.colorRange, after.colorRange)] {
            if let original, !["unknown", "unspecified"].contains(original), original != converted {
                throw ConversionError.unsupported("The encoder could not retain the source color information.")
            }
        }
        let videoStart = before.startTime.flatMap(Double.init) ?? 0
        let outputStart = after.startTime.flatMap(Double.init) ?? 0
        for (input, result) in zip(source.audio, output.audio) {
            guard input.channels == result.channels, input.sampleRate == result.sampleRate,
                  input.channelLayout == nil || input.channelLayout == "unknown" || input.channelLayout == result.channelLayout else {
                throw ConversionError.failed("An audio track’s channels or sample rate changed unexpectedly.")
            }
            if FFmpegProbe.copyAudio.contains(input.codecName ?? ""), input.codecName != result.codecName {
                throw ConversionError.failed("An audio track was not preserved.")
            }
            try validateTags(input.tags, result.tags)
        }
        let auxiliary = source.streams.filter { !["video", "audio"].contains($0.codecType ?? "") }
        var remaining = output.streams.filter { !["video", "audio"].contains($0.codecType ?? "") }
        for original in auxiliary {
            guard let index = remaining.firstIndex(where: { $0.codecType == original.codecType && $0.codecName == original.codecName }) else {
                throw ConversionError.unsupported("An auxiliary track could not be retained in MP4.")
            }
            try validateTags(original.tags, remaining[index].tags)
            remaining.remove(at: index)
        }
        let chapters = source.chapters ?? [], converted = output.chapters ?? []
        guard chapters.count == converted.count else { throw ConversionError.unsupported("The source chapters could not be retained.") }
        for (input, result) in zip(chapters, converted) {
            guard let start = Double(input.startTime), let end = Double(input.endTime),
                  let resultStart = Double(result.startTime), let resultEnd = Double(result.endTime),
                  abs((start - videoStart) - (resultStart - outputStart)) < 0.05,
                  abs((end - videoStart) - (resultEnd - outputStart)) < 0.05 else {
                throw ConversionError.unsupported("The source chapter timing could not be retained.")
            }
            try validateTags(input.tags, result.tags)
        }
        try validateTags(source.format?.tags, output.format?.tags)
        try validateTags(before.tags, after.tags)
    }

    private static func aspect(_ value: String?) -> Double {
        let parts = (value ?? "1:1").split(separator: ":").compactMap { Double($0) }
        return parts.count == 2 && parts[0] > 0 && parts[1] > 0 ? parts[0] / parts[1] : 1
    }

    private static func validateTags(_ original: [String: String]?, _ converted: [String: String]?) throws {
        let ignored: Set<String> = ["encoder", "duration", "major_brand", "minor_version", "compatible_brands", "handler_name", "vendor_id"]
        let normalized = Dictionary((converted ?? [:]).map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        for (key, value) in original ?? [:] where !ignored.contains(key.lowercased()) && !key.hasPrefix("_") {
            // Matroska stream statistics describe the old encoding and must not be copied as new statistics.
            if ["bps", "number_of_frames", "number_of_bytes"].contains(where: key.lowercased().hasPrefix) { continue }
            if key.lowercased() == "language" && value == "und" { continue }
            guard normalized[key.lowercased()] == value else {
                throw ConversionError.unsupported("Source metadata cannot be retained in MP4.")
            }
        }
    }
}

private struct AudioTiming {
    let start: Double
    let duration: Double

    static func read(_ source: URL, index: Int, stream: FFmpegProbe.Stream) async throws -> Self {
        var first: Double?, last = 0.0
        let rate = stream.sampleRate.flatMap(Double.init) ?? 0
        guard rate > 0 else { throw ConversionError.unsupported("An audio sample rate is not supported.") }
        let result = try await FFmpegProcess.run(executable: FFmpegTools.executable("ffprobe"), arguments: [
            "-v", "error", "-threads", "2", "-err_detect", "explode", "-protocol_whitelist", "fd", "-select_streams", "a:\(index)",
            "-show_frames", "-show_entries", "frame=best_effort_timestamp_time,nb_samples", "-of", "compact=p=0", "-i", "fd:"
        ], source: source, captureOutput: false) { line in
            let fields = line.split(separator: "|").map { $0.split(separator: "=", maxSplits: 1).map(String.init) }.filter { $0.count == 2 }
            let values = Dictionary(fields.map { ($0[0], $0[1]) }, uniquingKeysWith: { a, _ in a })
            guard let samples = values["nb_samples"].flatMap(Double.init) else { return }
            // Some delayed decoders (notably WMA) flush their last samples without
            // a timestamp; they continue immediately after the previous frame.
            guard let time = values["best_effort_timestamp_time"].flatMap(Double.init) ?? (first == nil ? nil : last) else { return }
            if first == nil { first = time }
            last = time + samples / rate
        }
        guard result.status == 0, result.diagnostic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let first, first.isFinite, last.isFinite, last > first else {
            throw ConversionError.failed("An audio track contains unreadable samples.")
        }
        return .init(start: first, duration: last - first)
    }
}

/// Frame timestamps live on disk, not in an unbounded array. Every decoded output frame
/// is compared with the corresponding source frame after a common timeline offset.
private final class FrameAudit {
    let video: FFmpegProbe.Stream
    let timeline: FileHandle
    let comparing: Bool
    var count = 0
    var firstTime: Double?
    var lastTime = 0.0
    var duration: Double { max(0.001, lastTime - (firstTime ?? 0)) }

    init(video: FFmpegProbe.Stream, timeline: FileHandle, comparing: Bool) {
        self.video = video; self.timeline = timeline; self.comparing = comparing
    }

    func read(_ source: URL) async throws {
        let result = try await FFmpegProcess.run(executable: FFmpegTools.executable("ffprobe"), arguments: [
            "-v", "error", "-threads", "2", "-err_detect", "explode", "-protocol_whitelist", "fd",
            "-select_streams", "v:0", "-show_frames", "-show_entries",
            "frame=best_effort_timestamp_time,width,height,pix_fmt,interlaced_frame,color_space,color_primaries,color_transfer:frame_side_data=side_data_type",
            "-of", "compact=p=0", "-i", "fd:"
        ], source: source, captureOutput: false) { line in
            let fields = line.split(separator: "|").map { $0.split(separator: "=", maxSplits: 1).map(String.init) }.filter { $0.count == 2 }
            for field in fields where field[0] == "side_data_type" { try FFmpegProbe.validateSideData(field[1]) }
            let values = Dictionary(fields.map { ($0[0], $0[1]) }, uniquingKeysWith: { a, _ in a })
            guard let time = values["best_effort_timestamp_time"].flatMap(Double.init) else {
                if values["width"] != nil { throw ConversionError.unsupported("A video frame has no usable timestamp.") }
                return
            }
            guard time.isFinite, Int(values["width"] ?? "") == self.video.width,
                  Int(values["height"] ?? "") == self.video.height, values["interlaced_frame"] != "1" else {
                throw ConversionError.unsupported("Interlaced video or changing frame dimensions cannot be preserved.")
            }
            try FFmpegProbe.validatePixels(values["pix_fmt"] ?? "")
            if let format = values["pix_fmt"], format != self.video.pixFmt {
                throw ConversionError.unsupported("Changing video pixel formats cannot be preserved.")
            }
            for (name, original) in [("color_space", self.video.colorSpace), ("color_transfer", self.video.colorTransfer),
                                      ("color_primaries", self.video.colorPrimaries)] {
                if let value = values[name], let original, value != "unknown", original != "unknown", value != original {
                    throw ConversionError.unsupported("Changing video color information cannot be preserved.")
                }
            }
            if self.firstTime == nil { self.firstTime = time }
            let relative = time - self.firstTime!
            if self.comparing {
                guard let data = try self.timeline.read(upToCount: MemoryLayout<Double>.size), data.count == MemoryLayout<Double>.size else {
                    throw ConversionError.failed("The converted video gained frames.")
                }
                let expected = data.withUnsafeBytes { $0.loadUnaligned(as: Double.self) }
                guard abs(relative - expected) < 0.001 else { throw ConversionError.failed("The converted video’s frame timing changed.") }
            } else {
                var value = relative
                try withUnsafeBytes(of: &value) { try self.timeline.write(contentsOf: $0) }
            }
            self.lastTime = time
            self.count += 1
        }
        guard result.status == 0, result.diagnostic.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, count > 0 else {
            throw ConversionError.failed("The video contains unreadable frames.")
        }
    }
}
