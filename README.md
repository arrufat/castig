# castig

Cast a local video to a Chromecast from the command line, as a single static
binary. ffmpeg is compiled in, so unsupported audio (DTS, TrueHD, ...) is
transcoded on the fly and text subtitles are served as WebVTT without any
runtime dependency.

*castig* is Catalan for "punishment". It is also cast + zig.

## Status

Early. What works today:

- `castig ls` finds Cast receivers on the LAN through mDNS.
- `castig probe <file>` lists the streams of a file and says whether a
  default receiver can play them directly.
- `castig status <device>` shows the running app and volume.
- `castig cast <device> <file|url>` plays a local file or a URL on the
  Default Media Receiver and follows playback until it ends. Local files are
  served from a built-in HTTP server with Range support, so seeking works.
  Optional `--title`, `--type <mime>` and `--subs <file|url>`; an `.srt`
  file is converted to WebVTT on the fly. When the audio codec is one the
  receiver cannot decode (AC3, DTS, TrueHD, ...), castig remuxes on the fly:
  the video is copied and the audio is transcoded to AAC in a fragmented MP4,
  with ffmpeg compiled in, no external process. The remux is served as
  on-demand HLS (a VOD playlist plus MPEG-TS segments transcoded as the
  receiver asks for them), so playback starts at once and seeking is native
  with a correct progress bar.
- `castig pause`, `play`, `seek <pos>` and `rate <x>` control whatever is
  playing, whoever started it. Positions are seconds, `m:ss`, `h:mm:ss`, or
  `+N` / `-N` relative to the current time. Rates go from 0.5 to 2.0.
- `castig stop <device>` stops the running app.

`<device>` is an IP, `ip:port`, or any part of a name shown by `ls`.
Set `CASTIG_DEBUG=1` to see every message exchanged with the receiver.

Video must already be in a codec the receiver decodes (H.264, VP8, VP9 or
AV1); unplayable audio is remuxed. Software video transcoding (for HEVC or
other video) is not implemented.

Device note: the remux uses HLS with MPEG-TS segments. The Chromecast tested
(Pixel Tablet) accepts HLS-TS only up to 720p; a 1080p remux is refused by its
HLS pipeline (though it plays 1080p over direct MP4).
1080p files with unplayable audio are the open case; the planned fix is a
pre-transcoded MP4 fallback.

Some receivers, the Pixel Tablet among them, may show an "allow this cast?"
prompt on screen. castig waits for it and says so.

## Building

The project pins a Zig version in `build.zig.zon`; with
[anyzig](https://github.com/marler8997/anyzig) the right compiler is picked
up automatically.

```sh
zig build                 # debug build, compiles ffmpeg from source the first time
zig build test            # unit tests
zig build run -- ls
zig build run -- probe movie.mkv
zig build run -- cast "living room" https://example.com/clip.mp4
```

Static release binary:

```sh
zig build -Doptimize=ReleaseFast -Dtarget=x86_64-linux-musl
```

To link against the ffmpeg installed on the system instead of building it
(faster builds, hardware codecs available, not static):

```sh
zig build -fsys=ffmpeg
```

This uses pkg-config to find libavformat, libavcodec, libavutil, libavfilter,
libswresample and libswscale. The bindings are written for ffmpeg 8.1. The
struct layouts checked so far (AVFormatContext, AVStream, AVCodecParameters)
are identical in ffmpeg 9.0, but ffmpeg 9 renumbered the video codec ids, so
castig never compares `av.Codec.ID` values and identifies codecs by name
instead. Keep that rule when adding code, or the system build silently
misbehaves.

## Layout

```
src/main.zig            command-line entry point
src/probe.zig           `probe`: stream listing and cast verdict
src/discovery.zig       `ls`: mDNS discovery
src/dns.zig             DNS wire format (query builder, record parser)
src/commands.zig        `status`, `cast`, `stop`
src/av_extra.zig        libav declarations missing from the bindings
src/cast/proto.zig      Cast channel framing (length prefix + protobuf CastMessage)
src/cast/channel.zig    Cast v2 protocol over TLS: receiver and media namespaces
src/http/server.zig     media server the receiver pulls from: files with Range, in-memory bodies
src/media/subtitles.zig SubRip to WebVTT
src/media/pipeline.zig  remux decision and remuxWindow (copy video, AC3/DTS/... to AAC, MPEG-TS)
src/media/hls.zig       on-demand HLS: keyframe segmenter, master+media playlists, per-segment TS
src/media/pipeline.zig  direct / remux / transcode decision and libav driver (planned)
```

## License

MIT.
