require_relative 'spec_helper'
require 'socket'

RSpec.describe VagrantPlugins::VagrantNotifyForwarder::Config do
  subject(:config) { described_class.new }

  it 'defaults to enabled with the standard port and binary map' do
    config.finalize!

    expect(config.enable).to eq(true)
    expect(config.port).to eq(29324)
    expect(config.binaries).to eq(described_class::DEFAULT_BINARIES)
  end

  it 'keeps the configured port when that port is in use' do
    socket = UDPSocket.new
    socket.bind('127.0.0.1', 0)
    port = socket.addr[1]
    config.port = port

    config.finalize!

    expect(config.port).to eq(port)
  ensure
    socket.close
  end

  it 'opens no socket while the configuration is read' do
    expect(UDPSocket).not_to receive(:new)

    config.finalize!
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
