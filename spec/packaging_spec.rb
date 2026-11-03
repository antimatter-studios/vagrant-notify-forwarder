require_relative 'spec_helper'
require 'open3'
require 'rubygems/package'
require 'vagrant-notify-forwarder/version'

RSpec.describe 'what the project says about itself' do
  root = File.expand_path('..', __dir__)
  owner = 'https://github.com/antimatter-studios'

  let(:readme) { File.read(File.join(root, 'README.md')) }
  let(:gemspec) { Gem::Specification.load(File.join(root, 'vagrant-notify-forwarder.gemspec')) }
  let(:version) { VagrantPlugins::VagrantNotifyForwarder::VERSION }
  let(:binaries) { VagrantPlugins::VagrantNotifyForwarder::Config::DEFAULT_BINARIES }

  it 'gives the install command the name the gem is published under' do
    expect(readme).to include("vagrant plugin install #{gemspec.name}")
    expect(readme).not_to include('vagrant-notify-forwarder2')
  end

  it 'gives the release download the current version and owner' do
    expect(readme).to include(
      "#{owner}/vagrant-notify-forwarder/releases/download/v#{version}/#{gemspec.name}-#{version}.gem"
    )
  end

  it 'offers no install through a Homebrew formula, because the tap has none' do
    expect(readme).not_to include('brew install')
  end

  it 'links the forwarder this plugin downloads' do
    expect(readme).to include("#{owner}/notify-forwarder")
    expect(readme).not_to include('mhallin/notify-forwarder')
  end

  it 'names the current owner in the gem and its default binaries' do
    expect(gemspec.homepage).to eq("#{owner}/vagrant-notify-forwarder")
    expect(binaries.values.map(&:first)).to all(start_with("#{owner}/notify-forwarder/releases/download/"))

    sources = Dir[File.join(root, 'lib/**/*.rb')] + [File.join(root, 'README.md'), gemspec.loaded_from]
    expect(sources.select { |path| File.read(path).include?('github.com/christhomas/') }).to eq([])
  end

  it 'has a changelog section for the current version' do
    expect(File.read(File.join(root, 'CHANGELOG.md'))).to match(/^## v#{Regexp.escape(version)}$/)
  end

  it 'shows only binary overrides for a platform the plugin can detect' do
    keys = readme.scan(/\[:(\w+), :(\w+)\]/).reject { |key| key == %w[os hardware] }
    os_names = VagrantPlugins::VagrantNotifyForwarder::Utils.class_variable_get(:@@OS_NAMES).values
    hardware_names = VagrantPlugins::VagrantNotifyForwarder::Utils.class_variable_get(:@@HARDWARE_NAMES).values

    expect(keys).not_to be_empty
    keys.each do |os, hardware|
      expect(os_names).to include(os.to_sym)
      expect(hardware_names).to include(hardware.to_sym)
    end
  end

  it 'says FreeBSD has no default binary' do
    expect(binaries.keys.map(&:first)).not_to include(:freebsd)
    expect(readme).to match(/FreeBSD.*no default binary/)
  end

  it 'ships exactly one gemspec' do
    Dir.mktmpdir('notify-forwarder-gem') do |directory|
      built = File.join(directory, 'built.gem')
      _output, status = Open3.capture2e('gem', 'build', 'vagrant-notify-forwarder.gemspec', '--output', built, chdir: root)
      expect(status).to be_success

      expect(Gem::Package.new(built).contents.grep(/\.gemspec\z/)).to eq(['vagrant-notify-forwarder.gemspec'])
    end
  end
end
