# castig

Cast a local file or a URL to a Chromecast or a DLNA renderer from the command
line, as a single static binary. ffmpeg is compiled in, so audio the device
cannot decode (DTS, AC3, TrueHD, ...) is transcoded on the fly and subtitles are
handled without any runtime dependency.

## Commands

```sh
castig ls                        # find devices on the network
castig probe <file>              # list a file's streams and whether it can be cast
castig cast <device> <file|url>  # play it, and follow playback until it ends
castig status <device>           # what the device is doing
castig watch <device>            # follow what is playing, whoever started it
castig stop <device>             # stop the running app
castig pause|play <device>
castig seek <device> <pos>       # 90, 1:30, 1:02:03, +30, -10
castig rate <device> <x>         # 0.5 to 2.0
castig subs <file>               # download a subtitle next to the video
castig ui                        # open the window (see below)
castig version                   # print the version
```

`<device>` is an IP, `ip:port`, a renderer's description URL, or any part of a
name shown by `ls`. The last column of `ls` is always something you can paste
back. A name matching one device of each kind goes to the Cast receiver; put
`cast:` or `dlna:` in front to say which you meant. The playback controls work
on whatever is playing, whoever started it.

Local files are served from a built-in HTTP server, so seeking works. `cast`
takes `--title`, `--type`, `--subs`, `--remux` and `--protocol`; run
`castig help cast` for what each one does.

Set `CASTIG_DEBUG=1` to see every message exchanged with the device, SOAP
envelopes included.

## What to expect

Video is copied, never transcoded, so it must already be in a codec the device
decodes, usually H.264, VP8, VP9 or AV1. HEVC and 4K play only where the device
handles them.

A Chromecast's abilities are fixed and known. A renderer is asked what it
accepts, and is usually more capable than a guess would allow: most take
Matroska and AC3, so the file goes over untouched, tracks and all. Use
`castig probe <file> --device <device>` to see the verdict for a particular one
rather than the Chromecast default.

Receivers differ in what they accept, and a 1080p file whose audio needs
transcoding can be refused in one delivery mode and play in another. That is
what `--remux auto` is for. It means HLS on a Chromecast and a seekable mp4 on
a renderer, which does not play HLS at all.

Some receivers show an "allow this cast?" prompt on screen. castig waits for
it and says so.

## DLNA renderers

`ls` finds them over SSDP alongside the Cast receivers, and everything works
the same way: the file is served from here and the device fetches it.

What is worse than on a Chromecast, and why:

- **Nothing is pushed.** UPnP AV tells nobody anything, so a renderer is asked
  once a second. What you change with its own remote shows up a second late.
- **Speed is Chromecast only.** No renderer worth having implements a play
  speed other than 1, and castig says so instead of doing nothing.
- **Seeking depends on the renderer.** Each one is asked which seek modes it
  understands, so a renderer that cannot is a clear refusal rather than a
  button that does nothing.
- **Subtitles are device-specific.** There is no standard way to side-load one,
  so castig names it four ways at once. Kodi takes it; Rygel ignores all four.
- **Choosing a subtitle track is not possible.** UPnP AV has no verb for it. A
  file that goes over whole takes its tracks with it and the renderer picks,
  which for Kodi means its own menu and for a headless renderer means the first
  one. Narrowing them would mean repackaging the container, which costs the
  seek bar.

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

`castig ui` opens a window with the same things in it: the devices found on
the network, of either kind, the file to cast with its stream list and verdict,
the subtitle and remux choices, and, once it is playing, the position, the
transport controls and the speed.

Choosing a device joins whatever it is already playing, so the controls work
on a cast started from the terminal or from anywhere else. It also asks that
device what it plays, so the file's verdict is the one that device would give,
the same as `probe --device`. The remux choices
say what they mean for a renderer, and the speed control is replaced by what a
renderer will actually do, which is 1x. It is a separate binary, `castigui`, built with
`zig build gui`; `castig ui` runs the copy next to it, or one on PATH.

`Find ...` next to the subtitle choice is `castig subs` without the prompt:
the ranked list of OpenSubtitles results, best first, one click to download
it next to the video and side-load it on the next cast. It needs the same
credentials, and spends the same daily allowance. The language chooser next
to it searches in one language instead of the configured order, the way
`--lang` does.

The field beside them holds what the search looks for. It is filled with the
title guessed from the file name, which is what `castig subs` searches for on
its own; correct it when the guess is wrong, and press Enter or `Find ...`.
Emptying it goes back to the guess.

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
