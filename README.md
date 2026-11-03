# Vagrant file system notification forwarder plugin

A vagrant plugin that uses [notify-forwarder](https://github.com/mhallin/notify-forwarder) to
forward file system events from the host to the guest automatically on all shared folders.

This is useful for auto reloading file systems that rebuild when files change. Normally, they have
to use CPU intensive polling when watching shared folders. This plugin makes them able to use
inotify or similar for improved performance and reduced CPU usage.

## Installation

### Via Homebrew (recommended)

```bash
brew install antimatter-studios/tap/vagrant-notify-forwarder
```

This downloads the gem and runs `vagrant plugin install` automatically.

### Manual install

```bash
vagrant plugin install vagrant-notify-forwarder2
```

Or from a specific release:

```bash
curl -fsSL -o /tmp/vagrant-notify-forwarder2.gem \
  https://github.com/christhomas/vagrant-notify-forwarder/releases/download/v0.6.3/vagrant-notify-forwarder2-0.6.3.gem
vagrant plugin install /tmp/vagrant-notify-forwarder2.gem
```

After installing, reload your Vagrant environment:

```bash
vagrant reload
```

## Configuration

### Port

By default, the plugin uses UDP port 29324. A machine that is starting takes the
first free port of the 10 from there, and `up` fails, naming the range, if none is
free. The port is chosen only then: other commands do not probe, and nothing moves
the forward afterwards. Machines starting at the same time get different ports,
whether one `vagrant` starts them or several do, as long as they share a
`VAGRANT_HOME`. A running, saved or paused machine keeps the port it has, recorded
in its data directory.

To set a specific port:

```ruby
config.notify_forwarder.port = 22020
```

### Disabling

To disable the plugin for a specific machine:

```ruby
config.notify_forwarder.enable = false
```

### Permissions

The receiver in the guest runs as the SSH user, by default `vagrant`. It needs to be able
to write to the files in your shared folders, because that is how it raises an event. If the
SSH user cannot write to them, run it as root:

```ruby
config.notify_forwarder.run_as_root = true
```

## The receiver in the guest

With passwordless `sudo`, the binary is installed at
`/usr/local/libexec/notify-forwarder/notify-forwarder`, owned by root. On a guest with systemd it
runs as `notify-forwarder.service`, which restarts on failure and comes back after a reboot inside
the guest. To stop it after disabling the plugin, run
`sudo systemctl disable --now notify-forwarder` in the guest.

| Guest | Binary | How it runs |
|-------|--------|-------------|
| `sudo` and systemd | `/usr/local/libexec/notify-forwarder`, owned by root | a service |
| `sudo`, no systemd | `/usr/local/libexec/notify-forwarder`, owned by root | a background process, started again at the next `up` |
| no `sudo` | `~/.local/libexec/notify-forwarder`, mode 0700 | a background process as the SSH user, started again at the next `up` |

Each start compares the binary's SHA-256 and the service definition with what the guest has, and
changes only what differs. A `resume`, or an `up` on a running machine, uploads nothing and leaves a
matching receiver running. A receiver an earlier version started from `/tmp/notify-forwarder` is
stopped, and that file is removed.

### Overriding binary sources

The plugin ships with a default map of download URLs and SHA256 checksums for each supported
`[os, hardware]` combination. You can override or extend the map via
`config.notify_forwarder.binaries`:

```ruby
config.notify_forwarder.binaries = {
  [:darwin, :arm64] => {
    url: "https://example.com/notify-forwarder-osx-arm64",
    sha256: "deadbeef..."
  },
  [:linux, :riscv64] => [
    "https://example.com/notify-forwarder-linux-riscv64",
    "cafebabe..."
  ]
}
```

You may supply each entry either as an array `[url, sha256]` or a hash with `:url`/`:sha256` keys.
Entries you omit continue using the built-in defaults.

## Watcher lifecycle

Cleanup runs at the start of halt, suspend, destroy and reload actions, independently
of provider-specific middleware. Existing registered watchers are also stopped before
the next start, even when forwarding has since been disabled or the provider fails.

Each host watcher runs under a small supervisor. It owns and reaps the forwarder
process, stops it on cleanup, and exits if the machine ID disappears or changes.
It also probes the machine's SSH endpoint every five seconds and stops after three
consecutive failures to receive an SSH banner, so an externally stopped VM does not
leave a watcher behind. This requires a reachable SSH endpoint; prolonged SSH
outages stop forwarding even if the VM is otherwise still running. Start or reload
the machine to restart forwarding after such an outage.

Watchers hold no descriptor of the `vagrant` that started them, so a pipe or a
command substitution around `vagrant up` ends when `vagrant` does. What they print
goes to `notify_watcher_host.log` in the machine's data directory
(`.vagrant/machines/<name>/<provider>/`), emptied at each start.

PID records include the process start time and complete command line. Cleanup
signals only matching processes. Old PID-only records cannot prove ownership and
are discarded without signalling those processes.

## Supported platforms

The plugin downloads binaries for supported platforms:

| Platform | Host | Guest |
|----------|------|-------|
| Linux arm64 | ✓ | ✓ |
| Linux armv7l | — | ✓ |
| Linux x86_64 | ✓ | ✓ |
| macOS arm64 | ✓ | — |
| macOS x86_64 | ✓ | — |

## Development

Run the specs without installing Vagrant or changing any installed plugins:

```bash
BUNDLE_GEMFILE=spec/Gemfile bundle install
BUNDLE_GEMFILE=spec/Gemfile bundle exec rspec --require ./spec/spec_helper.rb
```

The suite stubs `Vagrant.plugin(2, :config)`, the downloader and the middleware
environment. It does not boot a VM or download forwarder binaries. Pull requests
run the same specs on Ruby 3.1 and 3.3; release publishing is separate.

An additional integration suite reads the installed QEMU and VirtualBox action
chains and uses Vagrant's real hook builder. It does not start a VM or change
installed plugins. Run it with a Ruby environment containing Vagrant and RSpec:

```bash
VAGRANT_HOME="$HOME/tmp/notify-forwarder-test-home" \
TEST_TMPDIR="$HOME/tmp" \
VAGRANT_QEMU_ACTION="/path/to/vagrant-qemu/lib/vagrant-qemu/action.rb" \
VAGRANT_VIRTUALBOX_ACTION="/path/to/vagrant/plugins/providers/virtualbox/action.rb" \
ruby spec/integration/provider_chains.rb
```

QEMU 0.6.0 does not implement suspend. Its halt, destroy and reload chains and
VirtualBox's halt, suspend, destroy and reload chains are exercised. The regular
suite also checks registration of all four provider-independent lifecycle hooks.

Use Bundler and the project `Rakefile` to keep all tooling local to the repository.

1. Install dependencies:

   ```bash
   rake dev:bundle
   ```

2. Build the gem:

   ```bash
   bundle exec rake dev:build
   ```

3. Install locally for testing:

   ```bash
   bundle exec rake dev:install
   ```

4. Launch or reload Vagrant:

   ```bash
   bundle exec rake dev:up
   bundle exec rake dev:reload
   ```

## Contributors

* [CharlieC3](https://github.com/CharlieC3)
* [hedinfaok](https://github.com/hedinfaok)
* [seff](https://github.com/seff)
* [christhomas](https://github.com/christhomas)
