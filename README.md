# Media Converter

An offline macOS app that converts images to **HEIC, JPEG, or PNG** and videos to **HEVC in MP4**. No accounts or network access; additional video formats use bundled FFmpeg.

## Run

Requires **macOS 15+** and **Xcode 16+**.

Run `bash Scripts/build-ffmpeg.sh` once, then open `MediaConverter.xcodeproj`, select **MediaConverter**, and click **Run**.

## Use

1. Drop a source folder and a separate destination folder.
2. Choose an image format and set image/video quality.
3. Click **Convert**.

- Preserves folder structure and leaves originals untouched.
- Supports common image formats, supported Canon CR3 files, and MOV/MP4/M4V videos.
- Keeps image dimensions and video resolution/frame rate. Unsupported conversions are skipped or reported.
- PNG is lossless; HEIC, JPEG, and video quality range from 1–100 (default: 95). A setting of 100 does not guarantee lossless output.
- Skips existing outputs. Use a fresh destination to convert again with different settings.
- Retains supported metadata, which may include location. Converted files can be larger than originals.
- Cancellation keeps completed files and removes unfinished output.

### Image size estimates

Choosing a source automatically measures up to 50 images, sampled reproducibly across formats, resolutions, and file sizes. Below image quality, the app shows the average converted size, overall size change, and the count of sampled files that became larger. Changing quality or format updates the estimate after a short pause; previously measured settings are cached in memory and checked against source content hashes.

These are actual trial encodings using the same converter. Skipped or failed samples are reported and excluded from averages. The rest of the folder may behave differently; this is not a guarantee that every output will be smaller. Estimates are for images only and do not change the existing-output or larger-file policies. PNG uses its lossless encoder.

Samples run with bounded workers, never write to the destination, and are deleted when finished or cancelled. Starting a full conversion stops sampling first. Use the refresh icon to resample a folder after adding or changing images. No sample media, source paths, or caches are saved in the repository.

## Test

```sh
swift test

# Include image/video encoder tests (run in a macOS terminal)
MEDIA_CONVERTER_CODEC_TESTS=1 swift test

# Also test a supported CR3 file
MEDIA_CONVERTER_CODEC_TESTS=1 MEDIA_CONVERTER_CR3_FIXTURE=/path/to/sample.CR3 swift test
```

## Distribution

The app is MIT licensed; bundled FFmpeg is LGPL-2.1-or-later (see its included license and notices).

Pushing a stable version tag builds and publishes a universal DMG, SHA-256 checksums, and matching FFmpeg source archive:

```sh
git tag -a v1.0.0 -m "Media Converter v1.0.0"
git push origin v1.0.0
```

Use a new `vMAJOR.MINOR.PATCH` tag for each release. The workflow runs on macOS 15 with Xcode 16.4, scans for secrets, tests, builds both architectures, and verifies the app and DMG before publication. App versions come from the tag; build numbers come from the workflow run. A failed run can be retried before publication; published assets are never replaced.

To package locally after building FFmpeg: `bash Scripts/package-release.sh v1.0.0 1`.

Releases use ad-hoc signatures and are **not notarized**. macOS may require an explicit security override to open a downloaded app. Developer ID signing and notarization are not configured.

Conversions use private temporary storage and publish through held directory handles to reject symlink redirection and overwrite races. Temporary storage must have enough free space for active conversions. Photos retain supported metadata, including location; no media or credentials are included in releases.

## Additional video formats

The FFmpeg backend inspects every source frame before encoding and verifies every output frame against an on-disk timestamp record before publishing the MP4. A common initial timestamp offset is normalized while retaining audio/video synchronization. This adds reading/decoding time, but keeps memory bounded and catches changing dimensions, dropped frames, and unsupported per-frame metadata. Compatible audio is copied; other mono/stereo audio uses AAC. Dimensions, frame timing, rotation, aspect ratio, supported color information, audio timing, compatible metadata, and chapters are checked before success.

The same preservation policy applies to new containers: incompatible subtitles, attachments, multichannel audio requiring transcoding, spatial/alpha/log video, interlaced video, unsupported display transforms, and video above 10-bit are skipped. Styled or bitmap subtitles are not flattened into plain text. SDR and 10-bit HLG/PQ can be retained; mastering-display, content-light, Dolby Vision, HDR10+, or other unsupported side metadata causes a skip rather than tone mapping or silent removal. An extension identifies a candidate input, not a promise that every codec or track combination can be converted. Native MOV/MP4/M4V behavior is unchanged.

The helpers use seekable file descriptors opened by the app, inherit its sandbox, and have networking disabled. Only the bundled helpers are used. The existing quality slider maps to VideoToolbox quality; machines without a compatible adjustable-quality HEVC encoder report that limitation rather than ignoring the setting.

`Scripts/build-ffmpeg.sh` verifies the pinned source SHA-256 and creates universal helpers in `Sources/MediaCore/Resources/FFmpeg`. Xcode embeds and signs them; Swift Package Manager copies them into its resource bundle. Re-run the script after changing its build configuration (remove only the generated architecture build directories first). Matching source and the recipe are staged in `build/ThirdPartySources`; distribute that directory alongside release binaries. License and attribution are included in both the package and app. Synthetic video fixtures are under `Tests/MediaCoreTests/Fixtures`; their optional maintainer-only generation script documents its encoder dependencies.
