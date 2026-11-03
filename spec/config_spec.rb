require_relative 'spec_helper'

RSpec.describe VagrantPlugins::VagrantNotifyForwarder::Config do
  subject(:config) { described_class.new }

  before do
    allow(config).to receive(:auto_correct_port) { |port| port }
  end

  it 'defaults to enabled with the standard port and binary map' do
    config.finalize!

    expect(config.enable).to eq(true)
    expect(config.port).to eq(29324)
    expect(config.binaries).to eq(described_class::DEFAULT_BINARIES)
  end

  it 'preserves an explicitly disabled plugin' do
    config.enable = false
    config.finalize!

    expect(config.enable).to eq(false)
  end

  it 'normalizes binary overrides without discarding other platforms' do
    config.binaries = { ['linux', 'arm64'] => { 'url' => '/local/binary', 'sha256' => 'checksum' } }
    config.finalize!

    expect(config.binaries[[:linux, :arm64]]).to eq(['/local/binary', 'checksum'])
    expect(config.binaries[[:darwin, :arm64]]).to eq(described_class::DEFAULT_BINARIES[[:darwin, :arm64]])
  end
end
