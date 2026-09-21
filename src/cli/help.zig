//! What `castig help` prints, kept apart from the code that acts on it.
//!
//! Nothing here imports anything: it is the text a user reads, and that is
//! what lets `zig build docs` render it into a reference page without
//! building the tool, ffmpeg and all, to ask the binary for it.

pub const Command = enum { ls, probe, status, watch, stop, pause, play, seek, rate, cast, subs, ui, version, help };

/// The summary, and the index of commands.
pub const usage =
    \\usage: castig <command> [args]
    \\
    \\commands:
    \\  ls        discover cast receivers and DLNA renderers on the network
    \\  probe     print a file's streams and whether it can be cast directly
    \\  status    show what the receiver is doing
    \\  watch     follow what is playing, whoever started it
    \\  cast      play a local file or a URL and follow playback
    \\  pause     pause the current item
    \\  play      resume the current item
    \\  seek      jump to a position
    \\  rate      set playback speed
    \\  stop      stop whatever app is running on the receiver
    \\  ui        open the window
    \\  subs      download a subtitle next to a video
    \\  version   print the version
    \\  help      show this message
    \\
    \\<device> is an IP, IP:port, a renderer URL, or part of a name shown
    \\by `ls`. Prefix it with `cast:` or `dlna:` to settle an ambiguous name.
    \\
    \\Run `castig help <command>` for what a command takes.
    \\
;

/// What a command takes. The index in `usage` stays one line per command, so
/// everything a command needs explaining goes here.
pub fn help(cmd: Command) []const u8 {
    return switch (cmd) {
        .ls =>
        \\usage: castig ls [--timeout <ms>] [--protocol cast|dlna]
        \\
        \\Find the devices castig can drive: Cast receivers over mDNS and
        \\UPnP AV renderers over SSDP. Both rounds run at once.
        \\
        \\The last column is what to pass as <device>: an id for a Cast
        \\receiver, a description URL for a renderer. Part of a name works
        \\too, and `cast:name` or `dlna:name` settles one that matches both.
        \\
        \\  --timeout <ms>       how long to listen for replies (default 2000)
        \\  --protocol cast|dlna only look for one kind
        \\
        ,
        .watch =>
        \\usage: castig watch <device>
        \\
        \\Follow what the device is playing until it stops, whoever started
        \\it. A Cast receiver reports as it goes; a DLNA renderer is asked
        \\once a second, since UPnP AV tells nobody anything by itself.
        \\
        ,
        .probe =>
        \\usage: castig probe <file> [--device <device>]
        \\
        \\Print the streams of a media file, and whether a device can play it
        \\as it is or the audio has to be transcoded.
        \\
        \\  --device <d>  judge it against this device rather than against a
        \\                Cast receiver. A Cast receiver answers the same as
        \\                the default, since that is already its own list.
        \\                A DLNA renderer is asked what it accepts, and
        \\                usually accepts more than the default assumes.
        \\
        ,
        .status =>
        \\usage: castig status <device>
        \\
        \\Show what the receiver is playing, and where it is in the item.
        \\
        ,
        .cast =>
        \\usage: castig cast <device> <file|url> [--title <t>] [--type <mime>]
        \\                                       [--subs <file|url|auto>] [--remux <mode>]
        \\                                       [--protocol cast|dlna]
        \\
        \\Play a local file or a URL and follow playback until it ends. Local
        \\files are served from a built-in HTTP server, so seeking works.
        \\
        \\  --title <t>     what the receiver shows as the title
        \\  --type <mime>   override the media type sent to the receiver
        \\  --subs <arg>    add a .srt or .vtt track. On by default: without it
        \\                  a sidecar <name>.srt or <name>.<lang>.srt next to
        \\                  the file is used. `auto` downloads a hash match
        \\                  from OpenSubtitles when there is none. Embedded
        \\                  text subtitles are offered too, pick one from the
        \\                  receiver's subtitle menu.
        \\  --protocol <p>  which kind of device the name means, when it
        \\                  matches one of each. A `cast:` or `dlna:` prefix
        \\                  on <device> says the same thing.
        \\  --remux <mode>  how transcoded audio is delivered:
        \\                    auto    hls, falling back to mp4 if refused
        \\                    hls     seekable, starts at once
        \\                    mp4     seekable, no temp file, brief startup
        \\                    stream  starts at once, no seeking
        \\
        ,
        .pause =>
        \\usage: castig pause <device>
        \\
        \\Pause the current item, whoever started it.
        \\
        ,
        .play =>
        \\usage: castig play <device>
        \\
        \\Resume the current item, whoever started it.
        \\
        ,
        .seek =>
        \\usage: castig seek <device> <pos>
        \\
        \\Jump to <pos>: seconds, m:ss or h:mm:ss, or +N / -N to move relative
        \\to where playback is now.
        \\
        ,
        .rate =>
        \\usage: castig rate <device> <x>
        \\
        \\Set playback speed, between 0.5 and 2.0.
        \\
        ,
        .stop =>
        \\usage: castig stop <device>
        \\
        \\Stop whatever app is running on the receiver.
        \\
        ,
        .subs =>
        \\usage: castig subs <file> [--lang en,ko] [--auto]
        \\
        \\Download a subtitle from OpenSubtitles.com next to the file. Needs an
        \\API key and login in ~/.config/castig/config (see the README).
        \\
        \\  --lang <list>   comma separated languages to look for
        \\  --auto          take a trusted hash match only, without asking
        \\
        ,
        .ui =>
        \\usage: castig ui
        \\
        \\Open the window. Runs castigui, which `zig build gui` builds.
        \\
        ,
        .version =>
        \\usage: castig version
        \\
        \\Print the version: the tag on a release, otherwise a dev version
        \\carrying the commit count and hash.
        \\
        ,
        .help => usage,
    };
}
