# Changelog

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
