import Foundation
import UniformTypeIdentifiers

public enum ImageFormat: String, CaseIterable, Sendable, Identifiable {
    case heic = "HEIC", jpeg = "JPEG", png = "PNG"
    public var id: Self { self }
    public var fileExtension: String {
        switch self {
        case .heic: "heic"
        case .jpeg: "jpg"
        case .png: "png"
        }
    }
    var typeIdentifier: String {
        switch self {
        case .heic: UTType.heic.identifier
        case .jpeg: UTType.jpeg.identifier
        case .png: UTType.png.identifier
        }
    }
}

public enum VideoFormat: String, CaseIterable, Sendable, Identifiable {
    case mp4 = "MP4"
    public var id: Self { self }
}

public struct ConversionOptions: Sendable {
    public let imageFormat: ImageFormat
    public let videoFormat: VideoFormat
    public let imageQuality: Double
    public let videoQuality: Double

    public init(imageFormat: ImageFormat = .heic, videoFormat: VideoFormat = .mp4,
                imageQuality: Double = 0.95, videoQuality: Double = 0.95) {
        self.imageFormat = imageFormat
        self.videoFormat = videoFormat
        self.imageQuality = imageQuality.isFinite ? min(1, max(0.01, imageQuality)) : 0.95
        self.videoQuality = videoQuality.isFinite ? min(1, max(0.01, videoQuality)) : 0.95
    }
}

public enum MediaKind: Sendable { case image, video }

public struct ConversionJob: Sendable, Identifiable {
    public let id: Int
    public let source: URL
    public let destination: URL
    public let relativePath: String
    public let kind: MediaKind
    public let sourceBytes: Int64
    public let estimatedMemory: UInt64
}

public struct ConversionIssue: Sendable, Identifiable {
    public var id: String { path + ":" + message }
    public let path: String
    public let message: String
    public init(path: String, message: String) { self.path = path; self.message = message }
}

public struct ConversionPlan: Sendable {
    public let source: URL
    public let destination: URL
    public let jobs: [ConversionJob]
    public let issues: [ConversionIssue]
}

public struct BatchSnapshot: Sendable {
    public enum Phase: Sendable { case scanning, converting, finished, cancelled }
    public var phase: Phase = .scanning
    public var totalImages = 0
    public var totalVideos = 0
    public var completedImages = 0
    public var completedVideos = 0
    public var converted = 0
    public var skipped = 0
    public var failed = 0
    public var sourceBytes: Int64 = 0
    public var outputBytes: Int64 = 0
    public var progress: Double = 0
    public var issues: [ConversionIssue] = []
    public init() {}
    public var total: Int { totalImages + totalVideos }
    public var completed: Int { completedImages + completedVideos }
}

public enum ConversionError: Error, LocalizedError, Sendable {
    case invalidFolders(String)
    case unsupported(String)
    case failed(String)
    case outputExists
    public var errorDescription: String? {
        switch self {
        case .invalidFolders(let text), .unsupported(let text), .failed(let text): text
        case .outputExists: "Output already exists."
        }
    }
}

public struct WorkerLimits: Sendable {
    public let images: Int
    public let videos: Int
    public let memoryBytes: UInt64
    public init(images: Int? = nil, videos: Int? = nil, memoryBytes: UInt64? = nil) {
        self.images = max(1, images ?? min(8, max(1, ProcessInfo.processInfo.activeProcessorCount - 1)))
        #if arch(arm64)
        self.videos = max(1, videos ?? 2)
        #else
        self.videos = max(1, videos ?? 1)
        #endif
        self.memoryBytes = max(1, memoryBytes ?? ProcessInfo.processInfo.physicalMemory / 4)
    }
}
