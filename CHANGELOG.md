# Changelog

## v0.7.6

- Updated all notify-forwarder binaries to v1.2.0 and all SHA256 checksums
- The receiver no longer writes to the files an event names: no data, size, mode or mtime changes, so it cannot empty a file the host has just written
- The receiver raises `IN_OPEN`, `IN_ATTRIB` and `IN_CLOSE_WRITE`, and no longer `IN_MODIFY`; a filesystem without user extended attributes, such as NFSv3, also gets no `IN_ATTRIB`
- A receiver that cannot start exits nonzero with a message, and the plugin reports it; a bad port is refused and never read as a different one
- The Linux arm64 and x86_64 binaries need glibc 2.28, up from 2.27; armv7l stays at 2.34
- The macOS binaries declare a minimum of macOS 26.0, up from 15.0
- The guest receiver is a supervised service from a root-owned directory, or a checked background process, and a start changes only what differs; one in `/tmp/notify-forwarder` is stopped and removed (#22)
- Host watchers stop at halt, suspend, destroy and reload on every provider, and exit by themselves after their machine goes away, about 15 seconds after SSH stops answering (#19)
- Watcher PIDs are checked against start time and command line before termination (#18); a watcher started by an earlier version has only a PID on record, so it is not signalled and has to be ended by hand
- A host watcher holds no descriptor of the `vagrant` that started it, so `vagrant up | tail` returns when `vagrant` does, and it writes to `notify_watcher_host.log` in the machine's data directory (#21)
- One watcher serves all of a machine's synced folders, and a folder whose host path does not exist is reported and left out (#25)
- The watcher starts from an argument list and its early exit is reported (#17)
- A start chooses the port once, across `vagrant` processes sharing a `VAGRANT_HOME`, and `up` fails, naming the range, if none of the 10 is free (#23)
- The forwarded port listens on loopback only (#15)
- Downloaded binaries are verified against their checksum before use (#14)
- A gem built from a checkout holds real checksums, and the release workflow stops if a release binary does not match (#24)
- A disabled plugin no longer stops the machine from booting (#13)
- The README, gemspec and binary URLs name the current gem, version and owner (#25)
- Specs run on every pull request (#12)

## v0.7.5

- Binary checksums are written into the gem when it is released

## v0.7.4

- Hooks use provider-agnostic actions, so every provider gets them

## v0.7.2

- No change beyond the version

## v0.7.1

- Renamed the gem to `vagrant-notify-forwarder-christhomas`
- Fixed the release workflow's RubyGems credentials

## v0.7.0

- Added Linux armv7l (ARM32) guest support
- Updated all notify-forwarder binaries to v1.1.0
- Updated all SHA256 checksums
- Added armv7l to hardware name detection

## v0.6.3

- Added auto-correct for UDP port conflicts — tries next 10 ports if default is in use
- Added `auto_correct: true` to forwarded port declaration
- Added GitHub Actions release pipeline (triggers on version tags)
- Added Homebrew formula for installation via `brew install antimatter-studios/tap/vagrant-notify-forwarder`

## v0.6.2

- Added configurable binary sources via `config.notify_forwarder.binaries`
- Added support for macOS ARM64 (Apple Silicon) and Linux ARM64
- Updated notify-forwarder binaries to v1.0.0
