require_relative 'spec_helper'
require 'rubygems/package'

RSpec.describe 'a gem built from a checkout' do
  root = File.expand_path('..', __dir__)
  config_path = 'lib/vagrant-notify-forwarder/config.rb'

  it 'holds the checksum of every default binary' do
    Dir.mktmpdir('notify-forwarder-gem') do |directory|
      built = File.join(directory, 'built.gem')
      unpacked = File.join(directory, 'unpacked')
      expect(system('gem', 'build', 'vagrant-notify-forwarder.gemspec', '--output', built,
                    chdir: root, out: File::NULL, err: File::NULL)).to be(true)
      Gem::Package.new(built).extract_files(unpacked)
      config = File.read(File.join(unpacked, config_path))

      checksums = VagrantPlugins::VagrantNotifyForwarder::Config::DEFAULT_BINARIES.values.map(&:last)

      expect(checksums.size).to eq(5)
      expect(checksums).to all(match(/\A[0-9a-f]{64}\z/))
      expect(checksums).to all(satisfy { |checksum| config.include?(checksum) })
      expect(config).not_to match(/SHA256_/)
    end
  end
end
