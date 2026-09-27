import Foundation
import Testing
import ImageIO
import CoreGraphics
import CoreImage
@preconcurrency import AVFoundation
import VideoToolbox
import AudioToolbox
@testable import MediaCore

// Codec tests need the host's native media services, which command sandboxes can restrict.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MEDIA_CONVERTER_CODEC_TESTS"] == "1"))
struct CodecTests {
    @Test func estimatedSizesMatchTheRealImageConverter() async throws {
        let w = try Workspace(); defer { w.clean() }
        let source = w.source.appendingPathComponent("photo.png")
        try Fixtures.image(source)
        let estimator = ImageSizeEstimator()
        for format in ImageFormat.allCases {
            for quality in [25, 95] {
                let estimate = try await estimator.estimate(source: w.source, format: format, quality: quality)
                let output = w.destination.appendingPathComponent("\(quality).\(format.fileExtension)")
                try ImageConverter.convert(source: source, destination: output,
                    options: .init(imageFormat: format, imageQuality: Double(quality) / 100))
                let bytes = Int64(try Data(contentsOf: output).count)
                let inputBytes = Int64(try Data(contentsOf: source).count)
                #expect(estimate.measuredCount == 1 && estimate.failedCount == 0)
                #expect(estimate.averageOutputBytes == bytes && estimate.outputBytes == bytes)
                #expect(estimate.sourceBytes == inputBytes)
                #expect(estimate.largerCount == (bytes > inputBytes ? 1 : 0))
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MEDIA_CONVERTER_CR3_FIXTURE"] != nil))
    func cr3FullResolutionQualityAndMetadata() async throws {
        let fixture = try #require(ProcessInfo.processInfo.environment["MEDIA_CONVERTER_CR3_FIXTURE"])
        let w = try Workspace(); defer { w.clean() }
        let source = w.source.appendingPathComponent("camera.CR3")
        try FileManager.default.copyItem(at: URL(fileURLWithPath: fixture), to: source)
        let sourceData = try Data(contentsOf: source)
        let input = try #require(CGImageSourceCreateWithURL(source as CFURL, nil))
        #expect(CGImageSourceGetType(input) as String? == "com.canon.cr3-raw-image")
        let inputProperties = try #require(CGImageSourceCopyPropertiesAtIndex(input, 0, nil) as? [CFString: Any])
        let raw = try #require(CIRAWFilter(imageURL: source))
        let size = raw.nativeSize
        let orientation = raw.orientation.rawValue
        for format in ImageFormat.allCases {
            var sizes: [Int64] = []
            for quality in [0.2, 0.95] {
                let destination = w.root.appendingPathComponent("\(format.fileExtension)-\(quality)")
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                let options = ConversionOptions(imageFormat: format, imageQuality: quality)
                let plan = try FolderScanner.scan(source: w.source, destination: destination, options: options)
                #expect(plan.jobs.first?.estimatedMemory == UInt64(size.width * size.height * 64))
                let result = try await BatchCoordinator().run(source: w.source, destination: destination,
                                                             options: options, onProgress: { _ in })
                try #require(result.converted == 1, "CR3 conversion issues: \(result.issues.map(\.message))")
                #expect(result.failed == 0 && result.skipped == 0)
                sizes.append(result.outputBytes)
                let output = try #require(CGImageSourceCreateWithURL(
                    destination.appendingPathComponent("camera.\(format.fileExtension)") as CFURL, nil))
                let expectedType: String = switch format {
                case .heic: "public.heic"
                case .jpeg: "public.jpeg"
                case .png: "public.png"
                }
                #expect(CGImageSourceGetType(output) as String? == expectedType)
                let image = try #require(CGImageSourceCreateImageAtIndex(output, 0, nil))
                #expect(image.width == Int(size.width) && image.height == Int(size.height))
                #expect(image.colorSpace?.name == CGColorSpace.displayP3)
                switch format {
                case .jpeg: #expect(image.bitsPerComponent == 8)
                case .png: #expect(image.bitsPerComponent == 16)
                case .heic: #expect(image.bitsPerComponent > 8)
                }
                let properties = try #require(CGImageSourceCopyPropertiesAtIndex(output, 0, nil) as? [CFString: Any])
                #expect((properties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value == orientation)
                for (dictionary, key) in [(kCGImagePropertyExifDictionary, kCGImagePropertyExifDateTimeOriginal),
                                           (kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFModel)] {
                    let expected = (inputProperties[dictionary] as? [CFString: Any])?[key] as? String
                    #expect((properties[dictionary] as? [CFString: Any])?[key] as? String == expected)
                }
            }
            if format == .png { #expect(sizes[0] == sizes[1]) }
            else { #expect(sizes[0] < sizes[1]) }
        }
        #expect(try Data(contentsOf: source) == sourceData)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MEDIA_CONVERTER_UI_FIXTURES"] != nil))
    func prepareManualFixtures() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["MEDIA_CONVERTER_UI_FIXTURES"])
        let root = URL(fileURLWithPath: path)
        let source = root.appendingPathComponent("Source/Nested")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Destination"), withIntermediateDirectories: true)
        try imageFixturesForUI(source)
        try await Fixtures.video(source.appendingPathComponent("Sample.mov"), audio: true)
    }

    private func imageFixturesForUI(_ source: URL) throws {
        for index in 0..<24 { try Fixtures.image(source.appendingPathComponent("Sample-\(index).png")) }
    }

    @Test func imageFormatsQualityAndMetadata() throws {
        let w = try Workspace(); defer { w.clean() }
        let source = w.source.appendingPathComponent("synthetic.png")
        try Fixtures.image(source)
        for format in ImageFormat.allCases {
            let low = w.destination.appendingPathComponent("low.\(format.fileExtension)")
            let high = w.destination.appendingPathComponent("high.\(format.fileExtension)")
            try ImageConverter.convert(source: source, destination: low, options: .init(imageFormat: format, imageQuality: 0.2))
            try ImageConverter.convert(source: source, destination: high, options: .init(imageFormat: format, imageQuality: 0.95))
            let lowBytes = try Data(contentsOf: low).count, highBytes = try Data(contentsOf: high).count
            if format == .png { #expect(try Data(contentsOf: low) == Data(contentsOf: high)) }
            else { #expect(lowBytes < highBytes) }
            let result = try #require(CGImageSourceCreateWithURL(high as CFURL, nil))
            let properties = try #require(CGImageSourceCopyPropertiesAtIndex(result, 0, nil) as? [CFString: Any])
            #expect((properties[kCGImagePropertyPixelWidth] as? Int) == 512)
            #expect((properties[kCGImagePropertyPixelHeight] as? Int) == 384)
            #expect((properties[kCGImagePropertyOrientation] as? Int) == 6)
            let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
            #expect(exif?[kCGImagePropertyExifDateTimeOriginal] as? String == "2020:01:02 03:04:05")
            #expect(CGImageSourceCreateImageAtIndex(result, 0, nil)?.colorSpace != nil)
            // Matching formats are re-encoded; quality affects only lossy formats.
            let recompressed = w.destination.appendingPathComponent("again.\(format.fileExtension)")
            try ImageConverter.convert(source: high, destination: recompressed, options: .init(imageFormat: format, imageQuality: 0.2))
            if format != .png { #expect(try Data(contentsOf: recompressed).count < highBytes) }
            else { #expect(try Data(contentsOf: recompressed).count > 0) }
            for quality in [0.01, 1.0] {
                let endpoint = w.destination.appendingPathComponent("endpoint-\(quality).\(format.fileExtension)")
                try ImageConverter.convert(source: source, destination: endpoint, options: .init(imageFormat: format, imageQuality: quality))
                #expect(try Data(contentsOf: endpoint).count > 0)
            }
        }
    }

    @Test func transparencyAndAnimation() throws {
        let w = try Workspace(); defer { w.clean() }
        let source = w.source.appendingPathComponent("alpha.png")
        try Fixtures.image(source, alpha: true)
        #expect(throws: ConversionError.self) {
            try ImageConverter.convert(source: source, destination: w.destination.appendingPathComponent("alpha.jpg"), options: .init(imageFormat: .jpeg))
        }
        let heic = w.destination.appendingPathComponent("alpha.heic")
        try ImageConverter.convert(source: source, destination: heic, options: .init())
        let decodedSource = try #require(CGImageSourceCreateWithURL(heic as CFURL, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(decodedSource, 0, nil))
        #expect(![.none, .noneSkipFirst, .noneSkipLast].contains(decoded.alphaInfo))
        let animation = w.source.appendingPathComponent("animated.gif")
        let imageSource = try #require(CGImageSourceCreateWithURL(source as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
        let output = try #require(CGImageDestinationCreateWithURL(animation as CFURL, "com.compuserve.gif" as CFString, 2, nil))
        CGImageDestinationAddImage(output, image, nil); CGImageDestinationAddImage(output, image, nil)
        #expect(CGImageDestinationFinalize(output))
        #expect(throws: ConversionError.self) {
            try ImageConverter.convert(source: animation, destination: w.destination.appendingPathComponent("animation.heic"), options: .init())
        }
    }

    @Test func jpegRejectsHighBitDepth() throws {
        let w = try Workspace(); defer { w.clean() }
        let pixels = [UInt16](repeating: 32_768, count: 16 * 16 * 4)
        let data = pixels.withUnsafeBytes { Data($0) }
        let provider = try #require(CGDataProvider(data: data as CFData))
        let image = try #require(CGImage(width: 16, height: 16, bitsPerComponent: 16, bitsPerPixel: 64,
            bytesPerRow: 16 * 8, space: CGColorSpace(name: CGColorSpace.linearSRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue).union(.byteOrder16Little),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let source = w.source.appendingPathComponent("high-depth.png")
        let destination = try #require(CGImageDestinationCreateWithURL(source as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        #expect(throws: ConversionError.self) {
            try ImageConverter.convert(source: source, destination: w.destination.appendingPathComponent("high-depth.jpg"), options: .init(imageFormat: .jpeg))
        }
        // An extension must not bypass the checks for the actual encoded image format.
        let renamed = w.source.appendingPathComponent("high-depth.CR3")
        try FileManager.default.copyItem(at: source, to: renamed)
        #expect(throws: ConversionError.self) {
            try ImageConverter.convert(source: renamed, destination: w.destination.appendingPathComponent("renamed.jpg"), options: .init(imageFormat: .jpeg))
        }
    }

    @Test func videoQualityTimingRotationAndAudio() async throws {
        let w = try Workspace(); defer { w.clean() }
        let source = w.source.appendingPathComponent("clip.mov")
        try await Fixtures.video(source, audio: true)
        let low = w.destination.appendingPathComponent("low.mp4")
        let high = w.destination.appendingPathComponent("high.mp4")
        try await VideoConverter.convert(source: source, destination: low, quality: 0.2)
        try await VideoConverter.convert(source: source, destination: high, quality: 0.95)
        #expect(try Data(contentsOf: low).count < Data(contentsOf: high).count)
        let asset = AVURLAsset(url: high)
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let format = try #require(try await track.load(.formatDescriptions).first)
        #expect(CMFormatDescriptionGetMediaSubType(format) == kCMVideoCodecType_HEVC)
        #expect(try await track.load(.preferredTransform) == Fixtures.rotation)
        #expect(try await asset.loadTracks(withMediaType: .audio).count == 1)
        #expect(abs(try await asset.load(.duration).seconds - 1) < 0.04)
        let samples = try await Fixtures.frameTimes(asset)
        #expect(samples.count == 30)
        #expect(samples == (try await Fixtures.frameTimes(AVURLAsset(url: source))))
        let recompressed = w.destination.appendingPathComponent("again.mp4")
        try await VideoConverter.convert(source: high, destination: recompressed, quality: 0.2)
        #expect(try Data(contentsOf: recompressed).count < Data(contentsOf: high).count)
        for quality in [0.01, 1.0] {
            let endpoint = w.destination.appendingPathComponent("endpoint-\(quality).mp4")
            try await VideoConverter.convert(source: source, destination: endpoint, quality: quality)
            #expect(try await Fixtures.frameTimes(AVURLAsset(url: endpoint)).count == 30)
        }
    }

    @Test func hdrVideoPreservesTransferAndDepth() async throws {
        let w = try Workspace(); defer { w.clean() }
        let source = w.source.appendingPathComponent("hdr.mov")
        try await Fixtures.video(source, hdr: true)
        let output = w.destination.appendingPathComponent("hdr.mp4")
        try await VideoConverter.convert(source: source, destination: output, quality: 0.8)
        let track = try #require(try await AVURLAsset(url: output).loadTracks(withMediaType: .video).first)
        let format = try #require(try await track.load(.formatDescriptions).first)
        let properties = try #require(CMFormatDescriptionGetExtensions(format) as? [String: Any])
        #expect(properties[kCMFormatDescriptionExtension_TransferFunction as String] as? String == kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
        #expect(properties[kCMFormatDescriptionExtension_BitsPerComponent as String] as? Int == 10)
        #expect(try await Fixtures.frameTimes(AVURLAsset(url: output)).count == 30)
    }

    @Test func mixedBatchAndParallelThroughput() async throws {
        let w = try Workspace(); defer { w.clean() }
        let nested = w.source.appendingPathComponent("Nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        for i in 0..<12 { try Fixtures.image(nested.appendingPathComponent("\(i).png")) }
        let clock = ContinuousClock()
        let serialStart = clock.now
        let serial = try await BatchCoordinator().run(source: w.source, destination: w.destination,
            options: .init(), limits: .init(images: 1), onProgress: { _ in })
        let serialTime = serialStart.duration(to: clock.now)
        let parallelFolder = w.root.appendingPathComponent("Parallel")
        try FileManager.default.createDirectory(at: parallelFolder, withIntermediateDirectories: true)
        let parallelStart = clock.now
        let parallel = try await BatchCoordinator().run(source: w.source, destination: parallelFolder,
            options: .init(), onProgress: { _ in })
        let parallelTime = parallelStart.duration(to: clock.now)
        #expect(serial.converted == 12 && parallel.converted == 12)
        #expect(serial.failed == 0 && parallel.failed == 0)
        print("Synthetic HEIC batch: serial \(serialTime), parallel \(parallelTime)")
    }
}

enum Fixtures {
    static let rotation = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 240, ty: 0)

    static func image(_ url: URL, alpha: Bool = false) throws {
        let width = 512, height = 384
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var seed: UInt64 = 42
        for y in 0..<height { for x in 0..<width {
            seed = seed &* 6364136223846793005 &+ 1
            let noise = Int((seed >> 32) & 31)
            let i = (y * width + x) * 4
            pixels[i] = UInt8((x / 3 + noise) % 256)
            pixels[i + 1] = UInt8((y / 2 + noise) % 256)
            pixels[i + 2] = UInt8((x / 4 + y / 4 + noise) % 256)
            pixels[i + 3] = alpha ? 128 : 255
            if alpha { pixels[i] /= 2; pixels[i + 1] /= 2; pixels[i + 2] /= 2 }
        }}
        let data = Data(pixels)
        let provider = try #require(CGDataProvider(data: data as CFData))
        let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.displayP3)!,
            bitmapInfo: CGBitmapInfo(rawValue: alpha ? CGImageAlphaInfo.premultipliedLast.rawValue : CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let output = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(output, image, [kCGImagePropertyOrientation: 6,
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifDateTimeOriginal: "2020:01:02 03:04:05"]] as CFDictionary)
        #expect(CGImageDestinationFinalize(output))
    }

    static func video(_ url: URL, hdr: Bool = false, audio: Bool = false) async throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        var settings: [String: Any] = [AVVideoCodecKey: hdr ? AVVideoCodecType.hevc : .h264,
                                      AVVideoWidthKey: 320, AVVideoHeightKey: 240]
        if hdr {
            settings[AVVideoCompressionPropertiesKey] = [AVVideoProfileLevelKey: kVTProfileLevel_HEVC_Main10_AutoLevel]
            settings[AVVideoColorPropertiesKey] = [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_2100_HLG, AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020]
        }
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.transform = rotation
        let pixelFormat = hdr ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_32ARGB
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
            kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 240])
        writer.add(input)
        let audioInput = audio ? AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false]) : nil
        if let audioInput { writer.add(audioInput) }
        guard writer.startWriting() else { throw writer.error! }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<30 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
            var pixel: CVPixelBuffer?
            CVPixelBufferCreate(kCFAllocatorDefault, 320, 240, pixelFormat,
                                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pixel)
            let buffer = try #require(pixel)
            CVPixelBufferLockBaseAddress(buffer, [])
            if hdr {
                CVBufferSetAttachments(buffer, [kCVImageBufferColorPrimariesKey: kCVImageBufferColorPrimaries_ITU_R_2020,
                    kCVImageBufferTransferFunctionKey: kCVImageBufferTransferFunction_ITU_R_2100_HLG,
                    kCVImageBufferYCbCrMatrixKey: kCVImageBufferYCbCrMatrix_ITU_R_2020] as CFDictionary, .shouldPropagate)
                for plane in 0..<2 {
                    let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane)!.assumingMemoryBound(to: UInt16.self)
                    let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane) / 2
                    for y in 0..<CVPixelBufferGetHeightOfPlane(buffer, plane) { for x in 0..<stride {
                        base[y * stride + x] = UInt16(plane == 0 ? 64 + ((x + y + frame * 3) % 876) : 512) << 6
                    }}
                }
            } else {
                let base = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
                let stride = CVPixelBufferGetBytesPerRow(buffer)
                for y in 0..<240 { for x in 0..<320 {
                    let i = y * stride + x * 4
                    base[i] = 255
                    base[i + 1] = UInt8((x + frame * 7 + y % 13) % 256)
                    base[i + 2] = UInt8((y + frame * 3 + x % 7) % 256)
                    base[i + 3] = UInt8((x + y + frame * 11) % 256)
                }}
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 30)) else {
                throw ConversionError.failed("Fixture frame \(frame): \(String(describing: writer.error))")
            }
            if let audioInput {
                while !audioInput.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(2)) }
                guard audioInput.append(try audioSample(frame)) else { throw writer.error! }
            }
        }
        input.markAsFinished(); audioInput?.markAsFinished()
        writer.endSession(atSourceTime: CMTime(value: 1, timescale: 1))
        await writer.finishWriting()
        #expect(writer.status == .completed)
    }

    private static func audioSample(_ frame: Int) throws -> CMSampleBuffer {
        var description = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 2, mFramesPerPacket: 1, mBytesPerFrame: 2, mChannelsPerFrame: 1, mBitsPerChannel: 16, mReserved: 0)
        var format: CMAudioFormatDescription?
        CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &description,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
        var block: CMBlockBuffer?
        CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: 3200,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0, dataLength: 3200, flags: 0, blockBufferOut: &block)
        let samples = (0..<1600).map { index in Int16(sin(Double(frame * 1600 + index) * 440 * 2 * .pi / 48_000) * 1000) }
        samples.withUnsafeBytes { data in _ = CMBlockBufferReplaceDataBytes(with: data.baseAddress!, blockBuffer: block!, offsetIntoDestination: 0, dataLength: data.count) }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
            presentationTimeStamp: CMTime(value: Int64(frame * 1600), timescale: 48_000), decodeTimeStamp: .invalid)
        var size = 2
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
            sampleCount: 1600, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        return try #require(sample)
    }

    static func frameTimes(_ asset: AVAsset) async throws -> [Double] {
        let track = try #require(try await asset.loadTracks(withMediaType: .video).first)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        reader.add(output)
        #expect(reader.startReading())
        var times: [Double] = []
        while let sample = output.copyNextSampleBuffer() { times.append(sample.presentationTimeStamp.seconds) }
        #expect(reader.status == .completed)
        return times
    }
}
