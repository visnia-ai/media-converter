import Foundation

struct FFmpegProbe: Decodable, Sendable {
    struct SideData: Decodable, Sendable {
        var sideDataType: String?
        var rotation: Double?
        var displaymatrix: String?
    }
    struct Stream: Decodable, Sendable {
        var index: Int
        var codecName: String?
        var codecTagString: String?
        var codecType: String?
        var width: Int?
        var height: Int?
        var pixFmt: String?
        var bitsPerRawSample: String?
        var channels: Int?
        var sampleRate: String?
        var channelLayout: String?
        var startTime: String?
        var duration: String?
        var sampleAspectRatio: String?
        var colorSpace: String?
        var colorTransfer: String?
        var colorPrimaries: String?
        var colorRange: String?
        var fieldOrder: String?
        var tags: [String: String]?
        var disposition: [String: Int]?
        var sideDataList: [SideData]?

        var depth: Int {
            if let bits = bitsPerRawSample.flatMap(Int.init), bits > 0 { return bits }
            let format = pixFmt ?? ""
            if format.contains("f32") { return 32 }
            if format.contains("f16") || format.hasPrefix("p016") || format.hasPrefix("p216") || format.hasPrefix("p416") { return 16 }
            if ["p012", "p212", "p412", "xyz12"].contains(where: format.hasPrefix) { return 12 }
            if ["p010", "p210", "p410", "x2rgb10", "x2bgr10", "v210", "v410"].contains(where: format.hasPrefix) { return 10 }
            for bits in [16, 14, 12, 10, 9] where format.contains("p\(bits)") || format.contains("gray\(bits)") { return bits }
            if format.contains("48") || format.contains("64") { return 16 }
            if format.hasPrefix("p010") { return 10 }
            return 8
        }
        var rotation: Double { sideDataList?.compactMap(\.rotation).first ?? tags?["rotate"].flatMap(Double.init) ?? 0 }
        var hdr: Bool { ["smpte2084", "arib-std-b67"].contains(colorTransfer ?? "") }
    }
    struct Chapter: Decodable, Sendable {
        var startTime: String
        var endTime: String
        var tags: [String: String]?
    }
    struct Format: Decodable, Sendable {
        var duration: String?
        var startTime: String?
        var tags: [String: String]?
    }
    var streams: [Stream]
    var chapters: [Chapter]?
    var format: Format?

    var video: Stream? { streams.first { $0.codecType == "video" } }
    var audio: [Stream] { streams.filter { $0.codecType == "audio" } }
    var duration: Double { format?.duration.flatMap(Double.init) ?? video?.duration.flatMap(Double.init) ?? 0 }

    static func read(_ url: URL) async throws -> Self {
        let result = try await FFmpegProcess.run(executable: FFmpegTools.executable("ffprobe"), arguments: [
            "-v", "error", "-protocol_whitelist", "fd", "-show_streams", "-show_format", "-show_chapters",
            "-of", "json", "-i", "fd:"
        ], source: url)
        guard result.status == 0 else { throw ConversionError.failed("The video could not be read or is corrupt.") }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        do { return try decoder.decode(Self.self, from: result.output) }
        catch { throw ConversionError.failed("The video metadata could not be read.") }
    }

    static let copyAudio: Set<String> = ["aac", "alac", "ac3", "eac3"]
    static let harmlessSideData: Set<String> = [
        "Display Matrix", "CPB properties", "H.26[45] User Data Unregistered SEI message",
        "H.264 User Data Unregistered SEI message", "H.265 User Data Unregistered SEI message",
        "Video encoding parameters", "Motion vectors", "Skip Samples", "3x3 displaymatrix"
    ]

    func validateInput() throws {
        guard streams.filter({ $0.codecType == "video" }).count == 1, let video,
              let width = video.width, let height = video.height, width > 0, height > 0,
              width <= Int(Int32.max), height <= Int(Int32.max), video.pixFmt != nil else {
            throw ConversionError.unsupported("A single decodable video track is required.")
        }
        guard video.depth <= 10 else { throw ConversionError.unsupported("Video above 10 bits per channel is not supported.") }
        try Self.validatePixels(video.pixFmt ?? "")
        guard video.rotation.isFinite else { throw ConversionError.unsupported("The video display transform is not supported.") }
        for side in video.sideDataList ?? [] {
            if let matrix = side.displaymatrix {
                let values = matrix.split(separator: "\n").flatMap { row -> [Double] in
                    guard let colon = row.firstIndex(of: ":") else { return [] }
                    return row[row.index(after: colon)...].split(whereSeparator: \.isWhitespace).compactMap { Double($0) }
                }
                guard values.count == 9 else { throw ConversionError.unsupported("The video display transform could not be read.") }
                let a = values[0] / 65536, b = values[1] / 65536, c = values[3] / 65536, d = values[4] / 65536
                // Rotation is restored by remuxing. Reject flips, shear, scaling, and
                // nonstandard offsets rather than collapsing them into an angle.
                let tx = -min(0, a * Double(width), c * Double(height), a * Double(width) + c * Double(height))
                let ty = -min(0, b * Double(width), d * Double(height), b * Double(width) + d * Double(height))
                let naturalOffset = abs(values[6] / 65536 - tx) < 0.01 && abs(values[7] / 65536 - ty) < 0.01
                guard abs(a * a + b * b - 1) < 0.001, abs(c * c + d * d - 1) < 0.001,
                      abs(a * d - b * c - 1) < 0.001, values[2] == 0, values[5] == 0, values[8] == 1073741824,
                      naturalOffset || (values[6] == 0 && values[7] == 0) else {
                    throw ConversionError.unsupported("This video display transform cannot be preserved.")
                }
            }
        }
        guard !["log", "log_sqrt"].contains(video.colorTransfer ?? "") else {
            throw ConversionError.unsupported("Log video is not supported.")
        }
        if video.hdr && (video.depth != 10 || video.colorPrimaries != "bt2020") {
            throw ConversionError.unsupported("This HDR representation cannot be preserved.")
        }
        for stream in streams {
            if ["encv", "enca", "drmi", "drms"].contains(stream.codecTagString ?? "") {
                throw ConversionError.unsupported("Protected video cannot be converted.")
            }
            guard stream.codecName != nil, stream.codecName != "unknown" else {
                throw ConversionError.unsupported("A source codec is not supported.")
            }
            for side in stream.sideDataList ?? [] { try Self.validateSideData(side.sideDataType ?? "") }
            let tags = stream.tags ?? [:]
            if tags.keys.contains(where: { $0.lowercased().contains("encrypt") || $0.lowercased().contains("stereo") }) ||
                stream.disposition?["attached_pic"] == 1 || stream.disposition?["multilayer"] == 1 {
                throw ConversionError.unsupported("Protected, spatial, and attached-picture video are not supported.")
            }
            switch stream.codecType {
            case "video": break
            case "audio":
                guard let channels = stream.channels, channels > 0, stream.sampleRate.flatMap(Int.init) != nil else {
                    throw ConversionError.unsupported("An audio track could not be read.")
                }
                if !Self.copyAudio.contains(stream.codecName ?? "") && channels > 2 {
                    throw ConversionError.unsupported("This multichannel audio format cannot be preserved in MP4.")
                }
            case "subtitle", "data":
                // Converting styled/bitmap subtitles to mov_text could silently discard content.
                guard ["mov_text", "bin_data"].contains(stream.codecName ?? "") else {
                    throw ConversionError.unsupported("A subtitle or auxiliary track cannot be copied into MP4.")
                }
            default:
                throw ConversionError.unsupported("An attachment or auxiliary track cannot be preserved in MP4.")
            }
        }
    }

    static func validatePixels(_ format: String) throws {
        if ["yuva", "gbrap", "rgba", "bgra", "argb", "abgr", "ya", "pal8"].contains(where: format.hasPrefix) {
            throw ConversionError.unsupported("Alpha-channel video is not supported.")
        }
    }

    static func validateSideData(_ type: String) throws {
        guard type.isEmpty || harmlessSideData.contains(type) else {
            throw ConversionError.unsupported("Video side metadata (\(type.prefix(100))) cannot be preserved by this converter.")
        }
    }
}
