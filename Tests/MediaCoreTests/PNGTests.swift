import Foundation
import Testing
import ImageIO
import CoreGraphics
@testable import MediaCore

@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["MEDIA_CONVERTER_CODEC_TESTS"] == "1"))
struct PNGTests {
    @Test(arguments: [false, true])
    func losslessPixelsAndTransparency(alpha: Bool) throws {
        let w = try Workspace(); defer { w.clean() }
        let source = w.source.appendingPathComponent("original.png")
        try Fixtures.image(source, alpha: alpha)
        var outputs: [Data] = []
        for quality in [0.01, 1.0] {
            let output = w.destination.appendingPathComponent("quality-\(quality).png")
            try ImageConverter.convert(source: source, destination: output,
                options: .init(imageFormat: .png, imageQuality: quality))
            let imageSource = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
            #expect(CGImageSourceGetType(imageSource) as String? == "public.png")
            let decoded = try #require(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
            #expect(decoded.width == 512 && decoded.height == 384)
            #expect(decoded.colorSpace?.name == CGColorSpace.displayP3)
            let properties = try #require(CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any])
            #expect(properties[kCGImagePropertyOrientation] as? Int == 6)
            let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
            #expect(exif?[kCGImagePropertyExifDateTimeOriginal] as? String == "2020:01:02 03:04:05")
            if alpha { #expect(![.none, .noneSkipFirst, .noneSkipLast].contains(decoded.alphaInfo)) }
            #expect(try rgbaPixels(output) == rgbaPixels(source))
            outputs.append(try Data(contentsOf: output))
        }
        #expect(outputs[0] == outputs[1])
    }

    @Test func preservesSixteenBitPixels() throws {
        let w = try Workspace(); defer { w.clean() }
        let pixels = (0..<(16 * 16 * 4)).map { UInt16(($0 * 61) % 65_536) }
        let data = pixels.withUnsafeBytes { Data($0) }
        let provider = try #require(CGDataProvider(data: data as CFData))
        let image = try #require(CGImage(width: 16, height: 16, bitsPerComponent: 16, bitsPerPixel: 64,
            bytesPerRow: 16 * 8, space: CGColorSpace(name: CGColorSpace.linearSRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue).union(.byteOrder16Little),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let source = w.source.appendingPathComponent("high-depth.png")
        let encoder = try #require(CGImageDestinationCreateWithURL(source as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(encoder, image, nil)
        try #require(CGImageDestinationFinalize(encoder))
        let output = w.destination.appendingPathComponent("high-depth.png")
        try ImageConverter.convert(source: source, destination: output, options: .init(imageFormat: .png))
        let inputSource = try #require(CGImageSourceCreateWithURL(source as CFURL, nil))
        let outputSource = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
        let original = try #require(CGImageSourceCreateImageAtIndex(inputSource, 0, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(outputSource, 0, nil))
        #expect(decoded.bitsPerComponent == 16)
        #expect(decoded.width == original.width && decoded.height == original.height)
        let originalPixels = try #require(original.dataProvider?.data) as Data
        let decodedPixels = try #require(decoded.dataProvider?.data) as Data
        #expect(decodedPixels == originalPixels)
    }

    @Test func batchConvertsJPEGHEICAndPNGWithoutLosingPixels() async throws {
        let w = try Workspace(); defer { w.clean() }
        let fixture = w.root.appendingPathComponent("fixture.png")
        try Fixtures.image(fixture)
        let nested = w.source.appendingPathComponent("Nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        for format in ImageFormat.allCases {
            let source = nested.appendingPathComponent("photo.\(format.fileExtension)")
            try ImageConverter.convert(source: fixture, destination: source, options: .init(imageFormat: format))
        }
        let result = try await BatchCoordinator().run(source: w.source, destination: w.destination,
            options: .init(imageFormat: .png, imageQuality: 0.01), onProgress: { _ in })
        #expect(result.converted == 3 && result.failed == 0 && result.skipped == 0)
        for format in ImageFormat.allCases {
            let source = nested.appendingPathComponent("photo.\(format.fileExtension)")
            let output = w.destination.appendingPathComponent("Nested/photo.\(format.fileExtension).png")
            let imageSource = try #require(CGImageSourceCreateWithURL(output as CFURL, nil))
            #expect(CGImageSourceGetType(imageSource) as String? == "public.png")
            let decoded = try #require(CGImageSourceCreateImageAtIndex(imageSource, 0, nil))
            #expect(decoded.colorSpace?.name == CGColorSpace.displayP3)
            #expect(try rgbaPixels(output) == rgbaPixels(source))
        }
    }

    private func rgbaPixels(_ url: URL) throws -> Data {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.displayP3)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: try #require(context.data), count: image.width * image.height * 4)
    }
}
