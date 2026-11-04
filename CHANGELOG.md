# Changelog

## v0.7.8

- The guest receiver restarts when its roots are mounted after it started, so file notifications keep working after a second boot ([#33](https://github.com/antimatter-studios/vagrant-notify-forwarder/issues/33))

## v0.7.7

- Version 0.7.6 was tagged and never published, so this is the first release of everything below; a user of 0.7.5 gets all of it at once
- Updated all notify-forwarder binaries to v1.2.1 and all SHA256 checksums
- The receiver no longer writes to the files an event names: no data, size, mode or mtime changes, so it cannot empty a file the host has just written
- The receiver raises `IN_OPEN`, `IN_ATTRIB` and `IN_CLOSE_WRITE`, and no longer `IN_MODIFY`; a filesystem without user extended attributes, such as NFSv3, also gets no `IN_ATTRIB`
- A receiver that cannot start exits nonzero with a message, and the plugin reports it; a bad port is refused and never read as a different one
- The Linux binaries need glibc 2.27: unchanged on arm64 and x86_64, and down from 2.34 on armv7l
- The macOS binaries declare a minimum of macOS 15.0, unchanged
- The receiver acts only on the guest paths of the machine's enabled synced folders and refuses files outside them, including symlinks that resolve outside them; a change to that set restarts it, and it is stopped when no folder is enabled (#26)
- A receive root that does not resolve stops the receiver with status 64 rather than leaving that root out; the service retries every 5 seconds (#26)
- `config.notify_forwarder.port` must be an integer from 1 to 65535, so a port set as a string now fails validation, and the free-port search stops at 65535 (#27)
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

## v0.7.6

- Tagged and never published: the release workflow stopped before it reached RubyGems, so this version does not exist there and the tag holds no release; its changes ship in v0.7.7

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
