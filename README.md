# castig

Cast a local video to a Chromecast from the command line, as a single static
binary. ffmpeg is compiled in, so audio the receiver cannot decode (DTS, AC3,
TrueHD, ...) is transcoded on the fly and subtitles are handled without any
runtime dependency.

## Commands

```sh
castig ls                        # find receivers on the network
castig probe <file>              # list a file's streams and whether it can be cast
castig cast <device> <file|url>  # play it, and follow playback until it ends
castig status <device>           # what the receiver is doing
castig stop <device>             # stop the running app
castig pause|play <device>
castig seek <device> <pos>       # 90, 1:30, 1:02:03, +30, -10
castig rate <device> <x>         # 0.5 to 2.0
castig subs <file>               # download a subtitle next to the video
```

`<device>` is an IP, `ip:port`, or any part of a name shown by `ls`. The
playback controls work on whatever is playing, whoever started it.

`cast` takes `--title`, `--type <mime>`, `--subs <file|url|auto>` and
`--remux <auto|hls|mp4|stream>`. Local files are served from a built-in HTTP
server, so seeking works. When the audio needs transcoding, `--remux` chooses
how it is delivered: `auto` starts at once and seeks, changing mode if the
receiver refuses; `mp4` seeks but waits for a preparation pass; `stream`
starts at once but cannot seek.

Set `CASTIG_DEBUG=1` to see every message exchanged with the receiver.

## What to expect

Video is copied, never transcoded, so it must already be in a codec the
receiver decodes, usually H.264, VP8, VP9 or AV1. HEVC and 4K play only on
receivers that handle them.

Receivers differ in what they accept, and a 1080p file whose audio needs
transcoding can be refused in one delivery mode and play in another. That is
what `--remux auto` is for.

Some receivers show an "allow this cast?" prompt on screen. castig waits for
it and says so.

## Subtitles

`cast` side-loads one text track and starts it enabled:

- `--subs <file|url>` uses that file, converting SubRip as needed.
- With no `--subs`, a sidecar next to the video is used when there is one:
  `<name>.<lang>.srt` or `.vtt` in your language order, then `<name>.srt`.
- `--subs auto` also downloads a confident match when there is no sidecar,
  and casts without a track, saying why, when it finds none.

Text subtitles already inside the file are offered as extra tracks in the
receiver's menu. Bitmap subtitles (PGS, VOBSUB) are not handled.

`castig subs <file> [--lang en,ko] [--auto]` searches
[OpenSubtitles.com](https://www.opensubtitles.com) by file hash and by a
title guessed from the name, then prints a ranked list, best match last,
right above the prompt. Enter takes it, `q` leaves. Rows are tagged `[HASH]`
for a match on the file itself, `[HI]` for hearing impaired and `[AI]` for
machine translated. `--auto` never prompts and takes only a confident hash
match, so a download is never spent on a guess: a free account has twenty a
day.

Create an account and an API consumer at opensubtitles.com, then write
`~/.config/castig/config`:

```ini
api_key=YOUR_API_KEY
username=YOUR_USERNAME
password=YOUR_PASSWORD
# priority order, ISO 639-1 codes
languages=en,ko
# rank hearing-impaired subtitles first
prefer_hi=no
# where to save when the video's directory is not writable
fallback_dir=
```

The credentials are stored in plain text; keep the file at mode 0600 and out
of public dotfiles. `CASTIG_OS_API_KEY`, `CASTIG_OS_USERNAME` and
`CASTIG_OS_PASSWORD` override it.

## Building

The project pins a Zig version in `build.zig.zon`; with
[anyzig](https://github.com/marler8997/anyzig) the right compiler is picked
up automatically.

```sh
zig build                 # debug build, compiles ffmpeg from source the first time
zig build test            # unit tests
zig build docs            # API documentation into zig-out/docs
zig build run -- ls
```

```sh
zig build -Doptimize=ReleaseFast -Dtarget=x86_64-linux-musl   # static release
zig build -fsys=ffmpeg                                        # link system ffmpeg
```

`-fsys=ffmpeg` finds the libav* libraries with pkg-config instead of building
ffmpeg, which is much faster and gives you hardware codecs, at the cost of a
dynamic binary. The bindings target ffmpeg 8.1 and work with 9.0.

Autodoc loads its sources over HTTP, so browse the `docs` output with a
static server such as `python -m http.server -d zig-out/docs` rather than
opening `index.html` from disk.

castig is a Zig module as well as a program: `src/root.zig` is the library
and `src/cli/` the command-line front end, so another project can depend on
castig and `@import("castig")`.

## License

MIT.
