# castig

Cast a local file or a URL to a Chromecast from the command line, as a single
static binary. ffmpeg is compiled in, so audio the receiver cannot decode (DTS,
AC3, TrueHD, ...) is transcoded on the fly and subtitles are handled without any
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
castig ui                        # open the window (see below)
castig version                   # print the version
```

`<device>` is an IP, `ip:port`, or any part of a name shown by `ls`. The
playback controls work on whatever is playing, whoever started it.

Local files are served from a built-in HTTP server, so seeking works. `cast`
takes `--title`, `--type`, `--subs` and `--remux`; run `castig help cast` for
what each one does.

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
of public dotfiles. `OPENSUBTITLES_API_KEY`, `OPENSUBTITLES_USERNAME` and
`OPENSUBTITLES_PASSWORD` override it.

## The window

`castig ui` opens a window with the same things in it: the receivers found on
the network, the file to cast with its stream list and verdict, the subtitle
and remux choices, and, once it is playing, the position, the transport
controls and the speed. It is a separate binary, `castigui`, built with
`zig build gui`; `castig ui` runs the copy next to it, or one on PATH.

`Find ...` next to the subtitle choice is `castig subs` without the prompt:
the ranked list of OpenSubtitles results, best first, one click to download
it next to the video and side-load it on the next cast. It needs the same
credentials, and spends the same daily allowance. The language chooser next
to it searches in one language instead of the configured order, the way
`--lang` does.

The window is [dvui](https://github.com/david-vanderson/dvui) over SDL3, both
compiled in, so it stays a single file like the CLI. The library does the
work on its own thread and the window draws what it reports, which is why a
long mp4 preparation shows a progress bar instead of freezing.

## Install

Each [release](https://github.com/arrufat/castig/releases) carries an archive
for Linux, macOS and Windows on x86_64 or Apple Silicon. It holds two files,
`castig` and `castigui`; put both in the same directory on your PATH, so
`castig ui` finds the window next to it.

The Linux `castig` is static and runs anywhere. Its `castigui` is not: SDL3
loads X11 and Wayland at run time, which a static binary cannot do, so the
window needs glibc 2.29 or newer.

## Building

The project pins a Zig version in `build.zig.zon`; with
[anyzig](https://github.com/marler8997/anyzig) the right compiler is picked
up automatically.

```sh
zig build                 # debug build, compiles ffmpeg from source the first time
zig build test            # unit tests
zig build docs            # API documentation into zig-out/docs
zig build run -- ls
zig build gui             # the window, into zig-out/bin/castigui
zig build run-gui
zig build version         # the version this checkout resolves to
```

`zig build` builds the CLI alone; only `gui` compiles SDL3 and the rest of
the window. Their sources are fetched with the other dependencies.

```sh
zig build -Doptimize=ReleaseFast -Dtarget=x86_64-linux-musl   # static release
zig build -fsys=ffmpeg                                        # link system ffmpeg
zig build gui -fsys=sdl3                                      # link system SDL3
```

`-fsys=ffmpeg` finds the libav* libraries with pkg-config instead of building
ffmpeg, which is much faster and gives you hardware codecs, at the cost of a
dynamic binary. The bindings target ffmpeg 8.1 and work with 9.0.

`zig build docs-serve` opens the rendered documentation in a browser, and
takes a port: `zig build docs-serve -- 8080`.

## License

MIT.
