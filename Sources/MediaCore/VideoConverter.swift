import Foundation
@preconcurrency import AVFoundation
import VideoToolbox
import AudioToolbox

public enum VideoConverter {
    public static func convert(source: URL, destination: URL, quality: Double,
                               progress: @escaping @Sendable (Double) async -> Void = { _ in }) async throws {
        let sourceExtension = source.pathExtension.lowercased()
        if VideoSourceTypes.additional.contains(sourceExtension) {
            try await FFmpegVideoConverter.convert(source: source, destination: destination, quality: quality, progress: progress)
            return
        }
        guard VideoSourceTypes.native.contains(sourceExtension) else {
            throw ConversionError.unsupported("This video container is not supported.")
        }
        try Task.checkCancellation()
        let asset = AVURLAsset(url: source)
        guard try await !asset.load(.hasProtectedContent) else { throw ConversionError.unsupported("Protected video cannot be converted.") }
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard tracks.count == 1, let video = tracks.first else {
            throw ConversionError.unsupported("A single ordinary video track is required.")
        }
        let formats = try await video.load(.formatDescriptions)
        guard let format = formats.first else { throw ConversionError.failed("The video format could not be read.") }
        let ext = (CMFormatDescriptionGetExtensions(format) as NSDictionary?) ?? [:]
        guard ext[kCMFormatDescriptionExtension_ContainsAlphaChannel] as? Bool != true,
              ext[kCMFormatDescriptionExtension_HasLeftStereoEyeView] as? Bool != true,
              ext[kCMFormatDescriptionExtension_HasRightStereoEyeView] as? Bool != true,
              ext[kCMFormatDescriptionExtension_LogTransferFunction] == nil else {
            throw ConversionError.unsupported("Alpha, spatial, and log video are not supported.")
        }
        let size = CMVideoFormatDescriptionGetDimensions(format)
        let transfer = ext[kCMFormatDescriptionExtension_TransferFunction] as? String
        let hdr = transfer == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String) ||
                  transfer == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
        let depth = (ext[kCMFormatDescriptionExtension_BitsPerComponent] as? NSNumber)?.intValue ?? (hdr ? 10 : 8)
        guard depth <= 10 else { throw ConversionError.unsupported("Video above 10 bits per channel is not supported.") }
        let tenBit = hdr || depth > 8
        let encoderSpec = try qualityEncoder(width: size.width, height: size.height, quality: quality)
        var compression: [String: Any] = [
            kVTCompressionPropertyKey_Quality as String: quality,
            AVVideoProfileLevelKey: tenBit ? kVTProfileLevel_HEVC_Main10_AutoLevel : kVTProfileLevel_HEVC_Main_AutoLevel
        ]
        if hdr {
            compression[kVTCompressionPropertyKey_HDRMetadataInsertionMode as String] = kVTHDRMetadataInsertionMode_Auto
            compression[kVTCompressionPropertyKey_PreserveDynamicHDRMetadata as String] = true
            for key in [kCMFormatDescriptionExtension_MasteringDisplayColorVolume, kCMFormatDescriptionExtension_ContentLightLevelInfo] {
                if let value = ext[key] { compression[key as String] = value }
            }
        }
        var settings: [String: Any] = [AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(size.width), AVVideoHeightKey: Int(size.height),
            AVVideoCompressionPropertiesKey: compression,
            AVVideoEncoderSpecificationKey: encoderSpec]
        var color: [String: Any] = [:]
        for (sourceKey, targetKey) in [(kCMFormatDescriptionExtension_ColorPrimaries, AVVideoColorPrimariesKey),
                                       (kCMFormatDescriptionExtension_TransferFunction, AVVideoTransferFunctionKey),
                                       (kCMFormatDescriptionExtension_YCbCrMatrix, AVVideoYCbCrMatrixKey)] {
            if let value = ext[sourceKey] { color[targetKey] = value }
        }
        if !color.isEmpty { settings[AVVideoColorPropertiesKey] = color }
        if let aperture = ext[kCMFormatDescriptionExtension_CleanAperture] as? NSDictionary {
            var mapped: [String: Any] = [:]
            for (from, to) in [(kCMFormatDescriptionKey_CleanApertureWidth, AVVideoCleanApertureWidthKey),
                               (kCMFormatDescriptionKey_CleanApertureHeight, AVVideoCleanApertureHeightKey),
                               (kCMFormatDescriptionKey_CleanApertureHorizontalOffset, AVVideoCleanApertureHorizontalOffsetKey),
                               (kCMFormatDescriptionKey_CleanApertureVerticalOffset, AVVideoCleanApertureVerticalOffsetKey)] {
                mapped[to] = aperture[from]
            }
            settings[AVVideoCleanApertureKey] = mapped
        }
        if let aspect = ext[kCMFormatDescriptionExtension_PixelAspectRatio] as? NSDictionary {
            settings[AVVideoPixelAspectRatioKey] = [
                AVVideoPixelAspectRatioHorizontalSpacingKey: aspect[kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing] ?? 1,
                AVVideoPixelAspectRatioVerticalSpacingKey: aspect[kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing] ?? 1]
        }
        let reader = try AVAssetReader(asset: asset)
        let writer = try AVAssetWriter(outputURL: destination, fileType: .mp4)
        writer.metadata = try await asset.load(.metadata)
        writer.shouldOptimizeForNetworkUse = true
        guard writer.canApply(outputSettings: settings, forMediaType: .video) else {
            throw ConversionError.unsupported("The video encoder does not support this format and quality.")
        }
        let output = AVAssetReaderTrackOutput(track: video, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: tenBit ? kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:]
        ])
        output.alwaysCopiesSampleData = false
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.transform = try await video.load(.preferredTransform)
        input.metadata = try await video.load(.metadata)
        var channels: [(output: AVAssetReaderOutput, input: AVAssetWriterInput)] = [(output, input)]
        for track in try await asset.loadTracks(withMediaType: .audio) {
            guard let hint = try await track.load(.formatDescriptions).first,
                  let description = CMAudioFormatDescriptionGetStreamBasicDescription(hint)?.pointee else {
                throw ConversionError.unsupported("An audio track could not be read.")
            }
            let passthrough = [kAudioFormatMPEG4AAC, kAudioFormatMPEG4AAC_HE, kAudioFormatMPEG4AAC_HE_V2,
                               kAudioFormatAppleLossless, kAudioFormatAC3, kAudioFormatEnhancedAC3].contains(description.mFormatID)
            if !passthrough && description.mChannelsPerFrame > 2 {
                throw ConversionError.unsupported("This multichannel audio format cannot be preserved in MP4.")
            }
            let audioOutput = AVAssetReaderTrackOutput(track: track, outputSettings: passthrough ? nil : [
                AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false])
            audioOutput.alwaysCopiesSampleData = false
            let audioSettings: [String: Any]? = passthrough ? nil : [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: description.mSampleRate,
                AVNumberOfChannelsKey: Int(description.mChannelsPerFrame),
                AVEncoderBitRateKey: description.mChannelsPerFrame == 1 ? 128_000 : 256_000]
            let audioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings,
                                                sourceFormatHint: passthrough ? hint : nil)
            audioInput.metadata = try await track.load(.metadata)
            channels.append((audioOutput, audioInput))
        }
        // Text, subtitle, and timed-metadata tracks are preserved only if MP4 can carry them.
        for track in try await asset.load(.tracks) where track.mediaType != .video && track.mediaType != .audio {
            guard [AVMediaType.metadata, .text, .subtitle, .closedCaption].contains(track.mediaType) else {
                throw ConversionError.unsupported("An auxiliary video track cannot be preserved in MP4.")
            }
            guard let hint = try await track.load(.formatDescriptions).first else {
                throw ConversionError.unsupported("An auxiliary video track cannot be preserved.")
            }
            channels.append((AVAssetReaderTrackOutput(track: track, outputSettings: nil),
                             AVAssetWriterInput(mediaType: track.mediaType, outputSettings: nil, sourceFormatHint: hint)))
        }
        for channel in channels {
            guard reader.canAdd(channel.output), writer.canAdd(channel.input) else {
                throw ConversionError.unsupported("A source track cannot be preserved in MP4.")
            }
            reader.add(channel.output); writer.add(channel.input)
        }
        let duration = try await asset.load(.duration)
        do {
            guard writer.startWriting(), reader.startReading() else {
                throw writer.error ?? reader.error ?? ConversionError.failed("Unable to start video conversion.")
            }
            writer.startSession(atSourceTime: .zero)
            var finished = Set<Int>()
            var videoSamples = 0
            var lastUpdate = ContinuousClock.now
            while finished.count < channels.count {
                try Task.checkCancellation()
                if writer.status == .failed || reader.status == .failed {
                    throw writer.error ?? reader.error ?? ConversionError.failed("Video conversion failed.")
                }
                var advanced = false
                for (index, channel) in channels.enumerated() where !finished.contains(index) && channel.input.isReadyForMoreMediaData {
                    let time: Double? = try autoreleasepool {
                        guard let sample = channel.output.copyNextSampleBuffer() else {
                            channel.input.markAsFinished(); finished.insert(index)
                            return nil
                        }
                        guard channel.input.append(sample) else {
                            throw writer.error ?? ConversionError.failed("Unable to write a media sample.")
                        }
                        if index == 0 { videoSamples += 1 }
                        return index == 0 ? sample.presentationTimeStamp.seconds : nil
                    }
                    advanced = true
                    if let time, duration.seconds > 0, lastUpdate.duration(to: .now) >= .milliseconds(100) {
                        await progress(min(0.99, max(0, time / duration.seconds)))
                        lastUpdate = .now
                    }
                }
                if !advanced { try await Task.sleep(for: .milliseconds(2)) }
            }
            guard videoSamples > 0, reader.status != .failed else {
                throw reader.error ?? ConversionError.failed("The video contains no decodable frames.")
            }
            await writer.finishWriting()
            try Task.checkCancellation()
            guard writer.status == .completed else { throw writer.error ?? ConversionError.failed("Unable to finish the MP4 file.") }
            let result = AVURLAsset(url: destination)
            guard let resultTrack = try await result.loadTracks(withMediaType: .video).first,
                  let resultFormat = try await resultTrack.load(.formatDescriptions).first else {
                throw ConversionError.failed("The converted video failed validation.")
            }
            let resultSize = CMVideoFormatDescriptionGetDimensions(resultFormat)
            let resultDuration = try await result.load(.duration)
            guard resultSize.width == size.width, resultSize.height == size.height,
                  abs(resultDuration.seconds - duration.seconds) < 0.15,
                  try await result.loadTracks(withMediaType: .audio).count == asset.loadTracks(withMediaType: .audio).count else {
                throw ConversionError.failed("The converted video’s dimensions, duration, or audio changed unexpectedly.")
            }
            if hdr {
                let resultExt = (CMFormatDescriptionGetExtensions(resultFormat) as NSDictionary?) ?? [:]
                guard resultExt[kCMFormatDescriptionExtension_TransferFunction] as? String == transfer else {
                    throw ConversionError.unsupported("The encoder could not retain HDR.")
                }
            }
            await progress(1)
        } catch {
            reader.cancelReading(); writer.cancelWriting()
            throw error
        }
    }

    static func qualityEncoder(width: Int32, height: Int32, quality: Double) throws -> [String: Any] {
        // Probe the actual encoder so a quality setting can never be silently ignored.
        for hardware in [true, false] {
            let spec: [String: Any] = [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: hardware]
            var session: VTCompressionSession?
            let status = VTCompressionSessionCreate(allocator: kCFAllocatorDefault, width: width, height: height,
                codecType: kCMVideoCodecType_HEVC, encoderSpecification: spec as CFDictionary,
                imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
                compressionSessionOut: &session)
            guard status == noErr, let session else { continue }
            defer { VTCompressionSessionInvalidate(session) }
            var supported: CFDictionary?
            guard VTSessionCopySupportedPropertyDictionary(session, supportedPropertyDictionaryOut: &supported) == noErr,
                  (supported as? [String: Any])?[kVTCompressionPropertyKey_Quality as String] != nil,
                  VTSessionSetProperty(session, key: kVTCompressionPropertyKey_Quality, value: NSNumber(value: quality)) == noErr else { continue }
            return spec
        }
        throw ConversionError.unsupported("No native HEVC encoder with adjustable quality is available.")
    }
}
