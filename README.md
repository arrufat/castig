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
- `castig cast <device> <url>` plays a URL the receiver can reach on the
  Default Media Receiver and follows playback until it ends. Optional
  `--title`, `--type <mime>` and `--subs <webvtt-url>`.
- `castig stop <device>` stops the running app.

`<device>` is an IP, `ip:port`, or any part of a name shown by `ls`.
Set `CASTIG_DEBUG=1` to see every message exchanged with the receiver.

Roadmap, in order: direct play of local files over a built-in HTTP server →
audio remux to fragmented MP4 → subtitles → software video transcode.

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
src/http/server.zig     media server the receiver pulls from (planned)
src/media/pipeline.zig  direct / remux / transcode decision and libav driver (planned)
```

## License

MIT.
