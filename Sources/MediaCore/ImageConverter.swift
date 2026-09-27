import Foundation
import CoreGraphics
import CoreImage
import ImageIO

public enum ImageConverter {
    public static func convert(source url: URL, destination: URL, options: ConversionOptions) throws {
        try autoreleasepool {
            try Task.checkCancellation()
            guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
                  let typeID = CGImageSourceGetType(source) else {
                if url.pathExtension.lowercased() == "cr3" {
                    throw ConversionError.unsupported("macOS could not decode this CR3 file. Its camera or RAW variant may be unsupported, or the file may be damaged.")
                }
                throw ConversionError.failed("The image could not be decoded.")
            }
            if typeID as String == "com.canon.cr3-raw-image" {
                try convertCR3(source: url, imageSource: source, destination: destination, options: options)
                return
            }
            let allowed: Set<String> = ["public.jpeg", "public.png", "public.tiff", "org.webmproject.webp",
                                        "com.microsoft.bmp", "public.heic", "public.heif", "com.compuserve.gif"]
            guard allowed.contains(typeID as String) else {
                throw ConversionError.unsupported("This image format is not supported. CR3 is the only supported camera RAW format.")
            }
            guard CGImageSourceGetCount(source) == 1 else {
                throw ConversionError.unsupported("Animated, multipage, and spatial images are not converted.")
            }
            guard let original = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) else {
                throw ConversionError.failed("The image could not be decoded.")
            }
            let alpha = ![CGImageAlphaInfo.none, .noneSkipFirst, .noneSkipLast].contains(original.alphaInfo)
            let auxiliaryTypes: [CFString] = [kCGImageAuxiliaryDataTypeHDRGainMap, kCGImageAuxiliaryDataTypeISOGainMap,
                kCGImageAuxiliaryDataTypeDepth, kCGImageAuxiliaryDataTypeDisparity, kCGImageAuxiliaryDataTypePortraitEffectsMatte,
                kCGImageAuxiliaryDataTypeSemanticSegmentationSkinMatte, kCGImageAuxiliaryDataTypeSemanticSegmentationHairMatte,
                kCGImageAuxiliaryDataTypeSemanticSegmentationTeethMatte, kCGImageAuxiliaryDataTypeSemanticSegmentationGlassesMatte,
                kCGImageAuxiliaryDataTypeSemanticSegmentationSkyMatte]
            let auxiliary = auxiliaryTypes.compactMap { type -> (CFString, CFDictionary)? in
                CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, type).map { (type, $0) }
            }
            let hasHDR = original.contentHeadroom > 1 || original.colorSpace?.isHDR() == true ||
                auxiliary.contains { $0.0 == kCGImageAuxiliaryDataTypeHDRGainMap || $0.0 == kCGImageAuxiliaryDataTypeISOGainMap }
            if options.imageFormat == .jpeg {
                guard !alpha else { throw ConversionError.unsupported("JPEG cannot preserve this image’s alpha channel. Choose HEIC or PNG.") }
                guard !hasHDR, original.bitsPerComponent <= 8 else {
                    throw ConversionError.unsupported("JPEG cannot preserve this image’s HDR or high bit depth. Choose HEIC.")
                }
                guard auxiliary.isEmpty else { throw ConversionError.unsupported("JPEG cannot preserve the auxiliary image data. Choose HEIC.") }
            }
            if options.imageFormat == .png {
                guard auxiliary.isEmpty else {
                    throw ConversionError.unsupported("PNG cannot preserve the auxiliary image data. Choose HEIC.")
                }
                guard original.bitsPerComponent <= 16, !original.bitmapInfo.contains(.floatComponents) else {
                    throw ConversionError.unsupported("PNG cannot preserve this image’s floating-point or greater-than-16-bit channels.")
                }
            }
            let outputType = options.imageFormat.typeIdentifier
            guard let output = CGImageDestinationCreateWithURL(destination as CFURL, outputType as CFString, 1, nil) else {
                throw ConversionError.failed("The selected image encoder is unavailable.")
            }
            var properties: [CFString: Any] = [
                kCGImageDestinationPreserveGainMap: true,
                kCGImageDestinationEmbedThumbnail: true
            ]
            if options.imageFormat != .png {
                properties[kCGImageDestinationLossyCompressionQuality] = options.imageQuality
            }
            CGImageDestinationAddImageFromSource(output, source, 0, properties as CFDictionary)
            if options.imageFormat == .heic {
                for (type, data) in auxiliary {
                    // Gain maps are copied by Image I/O's preservation option.
                    if type != kCGImageAuxiliaryDataTypeHDRGainMap && type != kCGImageAuxiliaryDataTypeISOGainMap {
                        CGImageDestinationAddAuxiliaryDataInfo(output, type, data)
                    }
                }
            }
            guard CGImageDestinationFinalize(output) else { throw ConversionError.failed("Image encoding failed.") }
            try Task.checkCancellation()
            guard let check = CGImageSourceCreateWithURL(destination as CFURL, nil),
                  CGImageSourceGetStatus(check) == .statusComplete,
                  let decoded = CGImageSourceCreateImageAtIndex(check, 0, nil),
                  decoded.width == original.width, decoded.height == original.height else {
                throw ConversionError.failed("The converted image failed validation.")
            }
            if alpha && [.none, .noneSkipFirst, .noneSkipLast].contains(decoded.alphaInfo) {
                throw ConversionError.unsupported("The encoder could not retain transparency.")
            }
            if options.imageFormat == .png && decoded.bitsPerComponent < original.bitsPerComponent {
                throw ConversionError.unsupported("The encoder could not retain the image’s bit depth.")
            }
            for (type, _) in auxiliary where CGImageSourceCopyAuxiliaryDataInfoAtIndex(check, 0, type) == nil {
                throw ConversionError.unsupported("The encoder could not retain auxiliary image data or HDR.")
            }
            if hasHDR && auxiliary.isEmpty && decoded.contentHeadroom <= 1 && decoded.colorSpace?.isHDR() != true {
                throw ConversionError.unsupported("The encoder could not retain HDR.")
            }
        }
    }

    private static func convertCR3(source url: URL, imageSource: CGImageSource,
                                   destination: URL, options: ConversionOptions) throws {
        guard CGImageSourceGetCount(imageSource) == 1 else {
            throw ConversionError.unsupported("Multi-image CR3 files are not converted.")
        }
        // Decode the sensor data explicitly; an embedded JPEG preview is not a RAW conversion.
        guard let raw = CIRAWFilter(imageURL: url) else {
            throw ConversionError.unsupported("macOS does not support this CR3 camera or RAW variant.")
        }
        let orientation = raw.orientation
        raw.orientation = .up // Keep native pixel dimensions and store orientation in metadata once.
        raw.scaleFactor = 1
        raw.isDraftModeEnabled = false
        raw.extendedDynamicRangeAmount = 0
        guard let developed = raw.outputImage,
              developed.extent.width == raw.nativeSize.width,
              developed.extent.height == raw.nativeSize.height else {
            throw ConversionError.failed("The CR3 image could not be developed at full resolution.")
        }
        try Task.checkCancellation()
        let colorSpace = CGColorSpace(name: CGColorSpace.displayP3)!
        let context = CIContext(options: [.cacheIntermediates: false])
        defer { context.clearCaches() }
        // RAW must be developed into an output color space and bit depth. JPEG is 8-bit;
        // supply 16-bit pixels to HEIC and PNG to retain higher precision.
        guard let rendered = context.createCGImage(developed, from: developed.extent,
                format: options.imageFormat == .jpeg ? .RGBA8 : .RGBA16, colorSpace: colorSpace) else {
            throw ConversionError.failed("The CR3 image could not be rendered.")
        }
        try Task.checkCancellation()
        let outputType = options.imageFormat.typeIdentifier
        guard let output = CGImageDestinationCreateWithURL(destination as CFURL, outputType as CFString, 1, nil) else {
            throw ConversionError.failed("The selected image encoder is unavailable.")
        }
        let originalProperties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, nil) as? [CFString: Any] ?? [:]
        // Copy photographic metadata, leaving RAW storage/profile fields to the output encoder.
        var properties: [CFString: Any] = [:]
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyExifAuxDictionary,
                    kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary,
                    kCGImagePropertyTIFFDictionary, kCGImagePropertyMakerCanonDictionary,
                    kCGImagePropertyDPIWidth, kCGImagePropertyDPIHeight] {
            properties[key] = originalProperties[key]
        }
        var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        exif[kCGImagePropertyExifColorSpace] = 65535 // Display P3 is described by the embedded ICC profile.
        exif[kCGImagePropertyExifPixelXDimension] = rendered.width
        exif[kCGImagePropertyExifPixelYDimension] = rendered.height
        properties[kCGImagePropertyExifDictionary] = exif
        properties[kCGImagePropertyOrientation] = orientation.rawValue
        if options.imageFormat != .png {
            properties[kCGImageDestinationLossyCompressionQuality] = options.imageQuality
        }
        properties[kCGImageDestinationEmbedThumbnail] = true
        CGImageDestinationAddImage(output, rendered, properties as CFDictionary)
        guard CGImageDestinationFinalize(output) else { throw ConversionError.failed("Image encoding failed.") }
        try Task.checkCancellation()
        guard let check = CGImageSourceCreateWithURL(destination as CFURL, nil),
              CGImageSourceGetStatus(check) == .statusComplete,
              let decoded = CGImageSourceCreateImageAtIndex(check, 0, nil),
              decoded.width == rendered.width, decoded.height == rendered.height,
              options.imageFormat != .png || decoded.bitsPerComponent == rendered.bitsPerComponent,
              let savedProperties = CGImageSourceCopyPropertiesAtIndex(check, 0, nil) as? [CFString: Any],
              (savedProperties[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value == orientation.rawValue else {
            throw ConversionError.failed("The converted CR3 image failed validation.")
        }
    }
}
