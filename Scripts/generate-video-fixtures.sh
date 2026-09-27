#!/bin/bash
# Maintainer-only; requires FFmpeg with libvpx, libtheora, libvorbis, and libmp3lame.
# The app and test suite never discover or execute system FFmpeg.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENCODER="${FFMPEG_FIXTURE_ENCODER:-ffmpeg}"
DEST="$ROOT/Tests/MediaCoreTests/Fixtures/Video"
mkdir -p "$DEST"
make_fixture() {
    local NAME="$1"; shift
    "$ENCODER" -hide_banner -loglevel error -nostdin -y \
        -f lavfi -i 'testsrc2=size=176x144:rate=24:duration=1' \
        -f lavfi -i 'sine=frequency=440:sample_rate=44100:duration=1' \
        -map_metadata -1 -threads 2 "$@" "$DEST/$NAME"
}
make_fixture h264.mkv -c:v libx264 -pix_fmt yuv420p -c:a aac
make_fixture mpeg4.avi -c:v mpeg4 -q:v 4 -c:a pcm_s16le
make_fixture vp8.webm -c:v libvpx -b:v 200k -c:a libvorbis
make_fixture vp9.webm -c:v libvpx-vp9 -b:v 200k -c:a libopus
make_fixture mpeg2.ts -c:v mpeg2video -q:v 4 -c:a mp2 -b:a 128k
make_fixture mpeg2.mpg -c:v mpeg2video -q:v 4 -c:a mp2 -b:a 128k -f mpeg
make_fixture mpeg2.vob -c:v mpeg2video -q:v 4 -c:a mp2 -b:a 128k -f vob
make_fixture wmv2.asf -c:v wmv2 -b:v 200k -c:a wmav2 -b:a 128k
make_fixture sorenson.flv -c:v flv -b:v 200k -c:a libmp3lame -b:a 128k
make_fixture h263.3gp -c:v h263 -b:v 200k -c:a aac -f 3gp
make_fixture h263.3g2 -c:v h263 -b:v 200k -c:a aac -f 3g2
make_fixture theora.ogv -c:v libtheora -q:v 5 -c:a libvorbis
make_fixture variable.mkv -vf 'select=not(eq(mod(n\,3)\,1))' -vsync vfr -c:v libx264 -c:a aac
make_fixture hlg.mkv -c:v libx265 -x265-params 'pools=1:frame-threads=1:log-level=error' -pix_fmt yuv420p10le -color_primaries bt2020 -color_trc arib-std-b67 -colorspace bt2020nc -c:a aac
make_fixture pq.mkv -c:v libx265 -x265-params 'pools=1:frame-threads=1:log-level=error' -pix_fmt yuv420p10le -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc -c:a aac
TEMP="$(mktemp -d)"
trap 'rm -rf "$TEMP"' EXIT
printf '1\n00:00:00,100 --> 00:00:00,800\nSynthetic subtitle\n' > "$TEMP/subtitle.srt"
printf ';FFMETADATA1\ntitle=Synthetic chapters\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=0\nEND=500\ntitle=First\n[CHAPTER]\nTIMEBASE=1/1000\nSTART=500\nEND=1000\ntitle=Second\n' > "$TEMP/chapters.txt"
"$ENCODER" -v error -nostdin -y -i "$DEST/h264.mkv" -map 0:v -map 0:a -map 0:a -c copy "$DEST/multiple-audio.mkv"
"$ENCODER" -v error -nostdin -y -i "$DEST/h264.mkv" -i "$TEMP/subtitle.srt" -map 0 -map 1 -c copy -c:s ass "$DEST/styled-subtitle.mkv"
"$ENCODER" -v error -nostdin -y -i "$DEST/h263.3gp" -i "$TEMP/subtitle.srt" -map 0 -map 1 -c copy -c:s mov_text "$DEST/text-subtitle.3gp"
"$ENCODER" -v error -nostdin -y -i "$DEST/h264.mkv" -i "$TEMP/chapters.txt" -map 0 -map_metadata 1 -map_chapters 1 -c copy "$DEST/chapters.mkv"
