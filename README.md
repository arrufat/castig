# castig

Cast a local video to a Chromecast from the command line, as a single static
binary. ffmpeg is compiled in, so unsupported audio (DTS, TrueHD, ...) is
transcoded on the fly and text subtitles are served as WebVTT without any
runtime dependency.

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
  receiver cannot decode (AC3, DTS, TrueHD, ...), castig remuxes on the fly
  with the ffmpeg compiled in, no external process: the video is copied and
  the audio is transcoded to AAC. `--remux` picks the delivery: `auto`
  (default) serves on-demand HLS (a VOD playlist plus MPEG-TS segments
  transcoded as the receiver asks for them, instant start, native seek) and
  falls back to `mp4` when the receiver refuses it; `mp4` assembles a
  seekable MP4 on the fly with no temp file, after one pass over the source
  (the audio is encoded in parallel chunks); `stream` is a fragmented-MP4
  live stream, instant but not seekable.
- `castig subs <file>` downloads a subtitle for a local file from
  [OpenSubtitles.com](https://www.opensubtitles.com) and saves it next to the
  video as `<name>.<lang>.srt`. See Subtitles below.
- `castig pause`, `play`, `seek <pos>` and `rate <x>` control whatever is
  playing, whoever started it. Positions are seconds, `m:ss`, `h:mm:ss`, or
  `+N` / `-N` relative to the current time. Rates go from 0.5 to 2.0.
- `castig stop <device>` stops the running app.

`<device>` is an IP, `ip:port`, or any part of a name shown by `ls`.
Set `CASTIG_DEBUG=1` to see every message exchanged with the receiver.

Video must already be in a codec the receiver decodes (H.264, VP8, VP9 or
AV1); unplayable audio is remuxed. Software video transcoding (for HEVC or
other video) is not implemented.

Device note: the Chromecast tested (Pixel Tablet) accepts HLS with MPEG-TS
segments only up to 720p and refuses a 1080p remux in that form, though it
plays 1080p over plain MP4. That is what the `auto` fallback to `mp4` is for.

Some receivers, the Pixel Tablet among them, may show an "allow this cast?"
prompt on screen. castig waits for it and says so.

## Subtitles

`cast` side-loads one text track and starts it enabled:

- `--subs <file|url>`: an `.srt` (converted to WebVTT on the fly) or `.vtt`.
- No `--subs`: a sidecar next to the video is used when there is one, first
  `<name>.<lang>.srt` / `.vtt` in your configured language order, then
  `<name>.srt` / `.vtt`.
- `--subs auto`: the sidecar if any, else a download from OpenSubtitles of a
  trusted hash match; when there is none, the cast goes on without a track
  and says why.

Embedded text subtitle streams (SubRip, ASS, mov_text, WebVTT) are offered
as extra tracks in the receiver's menu. Bitmap subtitles (PGS, VOBSUB) are
not handled.

`castig subs <file> [--lang en,ko] [--auto]` searches OpenSubtitles by
moviehash and by a title guessed from the file name, and prints a ranked
list, best match last, right above the prompt:

```
subtitles for Movie.2019.1080p.mkv (video 23.98 fps)
  4) [en] [AI] 120 dl · Movie.2019.WEBRip
  3) [HASH?] [en] 4000 dl · Movie.2019.1080p.BluRay.x264-OTHER
  2) [HASH] [en] [HI] 800 dl · Movie.2019.1080p.BluRay.x264-GRP
  1) [HASH] [en] 3100 dl · Movie.2019.1080p.BluRay.x264-GRP
pick [1]:
```

`[HASH]` is a moviehash match for the feature most hash matches agree on,
`[HASH?]` a hash match that names another feature or episode, `[HI]` hearing
impaired, `[AI]` machine translated; a frame rate is shown only when it
differs from the video's. Enter takes the top row, `q` leaves. With
`--auto` (and in `cast --subs auto`) only a `[HASH]` match with the video's
frame rate is downloaded, never a guess: a free account has 20 downloads a
day. When stdin is not a terminal, `subs` behaves as `--auto`.

Configuration lives in `~/.config/castig/config` (`$XDG_CONFIG_HOME`
respected), `key=value` lines. Create an account at opensubtitles.com and an
API consumer at opensubtitles.com/consumers, then:

```ini
api_key=YOUR_API_KEY
username=YOUR_USERNAME
password=YOUR_PASSWORD
# priority order, ISO 639-1 codes
languages=en,ko
# rank hearing-impaired subtitles first
prefer_hi=no
# where to save when the video's directory is not writable
# (default: ~/.cache/castig/subs)
fallback_dir=
```

The credentials are stored in plain text; keep the file at mode 0600 and out
of public dotfiles. `CASTIG_OS_API_KEY`, `CASTIG_OS_USERNAME` and
`CASTIG_OS_PASSWORD` override the file. The login token is cached in
`~/.cache/castig/token.json` for 20 hours.

## Building

The project pins a Zig version in `build.zig.zon`; with
[anyzig](https://github.com/marler8997/anyzig) the right compiler is picked
up automatically.

```sh
zig build                 # debug build, compiles ffmpeg from source the first time
zig build test            # unit tests
zig build docs            # API documentation into zig-out/docs
zig build run -- ls
zig build run -- probe movie.mkv
zig build run -- cast "living room" https://example.com/clip.mp4
```

`zig build docs` renders every module reachable from `src/root.zig`. Autodoc
loads its sources over HTTP, so browse it with a static server, for example
`python -m http.server -d zig-out/docs`, rather than opening `index.html`
from disk.

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
src/root.zig            library root: re-exports every module, the docs root
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
src/media/vmp4.zig      `--remux mp4`: seekable MP4 assembled on the fly, no temp file
src/subs/subs.zig       `subs` and `--subs auto`: search, pick, download, save
src/subs/opensubtitles.zig OpenSubtitles REST client, session cache, result ranking
src/subs/release.zig    moviehash, title and episode from a file name, sidecar names
src/subs/config.zig     ~/.config/castig/config and the env overrides
```

## License

MIT.
