# Media Converter

Offline image and video conversion for macOS 15+, on Apple Silicon and Intel.

[Download the latest release](https://github.com/visnia-ai/media-converter/releases/latest). The app is not notarized.

## Supported formats

| Type | Input | Output |
| --- | --- | --- |
| Images | JPEG, PNG, TIFF, WebP, BMP, HEIC, HEIF, single-frame GIF, macOS-supported Canon CR3 | HEIC, JPEG, PNG |
| Videos | MOV, MP4, M4V, MKV, AVI, WebM, MTS, M2TS, TS, MPG, MPEG, WMV, ASF, FLV, 3GP, 3G2, OGV, VOB | MP4 (HEVC) |

## Use

Choose separate source and destination folders, select a format and quality, then click **Convert**. Originals are preserved and existing outputs are skipped.

## Development

Requires Xcode 16+.

```sh
bash Scripts/build-ffmpeg.sh
open MediaConverter.xcodeproj
```

Build and run the **MediaConverter** scheme. Run tests with `swift test`, or `MEDIA_CONVERTER_CODEC_TESTS=1 swift test` to include codec tests.

Push a new `vMAJOR.MINOR.PATCH` tag to automatically publish a universal DMG, checksums, and matching FFmpeg source.

## License

[MIT](LICENSE). Bundled FFmpeg uses [LGPL-2.1-or-later](Sources/MediaCore/Resources/FFmpeg/LICENSE.txt).
