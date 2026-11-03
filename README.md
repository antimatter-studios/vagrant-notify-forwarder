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

By default, the plugin uses UDP port 29324. If multiple VMs are running, the
port is automatically corrected to the next available port (tries up to 10 ports).

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

The client in the guest OS runs as root by default, assuming passwordless `sudo` works. To disable
privilege escalation:

```ruby
config.notify_forwarder.run_as_root = false
```

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
