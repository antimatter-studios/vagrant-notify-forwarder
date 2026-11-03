require_relative 'spec_helper'

RSpec.describe VagrantPlugins::VagrantNotifyForwarder::Utils do
  include_context 'middleware env'

  let(:payload) { 'verified binary content' }
  let(:checksum) { Digest::SHA256.hexdigest(payload) }
  let(:url) { 'https://example.test/notify-forwarder' }
  let(:cached_binary) { directory.join('notify-forwarder') }

  before do
    allow(settings).to receive(:binaries).and_return({ [:linux, :arm64] => [url, checksum] })
  end

  it 'reuses a cache entry only when its checksum matches' do
    cached_binary.write(payload)
    expect(Vagrant::Util::Downloader).not_to receive(:new)

    expect(described_class.ensure_binary_downloaded(env, :linux, :arm64)).to eq(cached_binary)
    expect(cached_binary.stat.mode & 0o777).to eq(0o755)
  end

  it 'replaces a cache entry whose checksum does not match' do
    cached_binary.write('stale binary')
    downloader = instance_double(Vagrant::Util::Downloader)
    allow(Vagrant::Util::Downloader).to receive(:new) do |_source, destination|
      allow(downloader).to receive(:download!) { File.write(destination, payload) }
      downloader
    end

    expect(described_class.ensure_binary_downloaded(env, :linux, :arm64)).to eq(cached_binary)
    expect(cached_binary.read).to eq(payload)
  end

  it 'reports an unconfigured platform without downloading' do
    expect(Vagrant::Util::Downloader).not_to receive(:new)
    expect(ui).to receive(:error).with(/No binary configured/)

    expect(described_class.ensure_binary_downloaded(env, :linux, :riscv64)).to be_nil
  end
end
