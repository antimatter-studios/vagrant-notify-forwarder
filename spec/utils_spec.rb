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

  def stub_download(content)
    downloader = instance_double(Vagrant::Util::Downloader)
    allow(Vagrant::Util::Downloader).to receive(:new) do |_source, destination|
      allow(downloader).to receive(:download!) do
        File.write(destination, content)
        yield destination if block_given?
      end
      downloader
    end
  end

  def ensure_downloaded
    described_class.ensure_binary_downloaded(env, :linux, :arm64)
  end

  it 'fails and deletes a fresh download whose checksum does not match' do
    tampered = 'tampered binary content'
    stub_download(tampered)

    expect { ensure_downloaded }.to raise_error(Vagrant::Errors::VagrantError) { |error|
      expect(error.message).to include(url, checksum, Digest::SHA256.hexdigest(tampered))
    }
    expect(directory.children).to be_empty
  end

  it 'downloads to a temporary name beside the target and renames it into place' do
    destinations = []
    stub_download(payload) do |destination|
      destinations << destination.to_s
      expect(cached_binary).not_to exist
    end

    expect(ensure_downloaded).to eq(cached_binary)

    expect(destinations.length).to eq(1)
    expect(destinations.first).not_to eq(cached_binary.to_s)
    expect(File.dirname(destinations.first)).to eq(directory.to_s)
    expect(directory.children).to eq([cached_binary])
    expect(cached_binary.read).to eq(payload)
    expect(cached_binary.stat.mode & 0o777).to eq(0o755)
  end

  it 'gives each download its own temporary name' do
    destinations = []
    stub_download(payload) { |destination| destinations << destination.to_s }

    ensure_downloaded
    cached_binary.delete
    ensure_downloaded

    expect(destinations.uniq.length).to eq(2)
  end

  it 'leaves the old cache entry in place until the new download is verified' do
    cached_binary.write('stale binary')
    stub_download('tampered binary content') do
      expect(cached_binary.read).to eq('stale binary')
    end

    expect { ensure_downloaded }.to raise_error(Vagrant::Errors::VagrantError)

    expect(directory.children).to eq([cached_binary])
    expect(cached_binary.read).to eq('stale binary')
  end

  it 'removes the partial file when the download itself fails' do
    downloader = instance_double(Vagrant::Util::Downloader)
    allow(Vagrant::Util::Downloader).to receive(:new) do |_source, destination|
      allow(downloader).to receive(:download!) do
        File.write(destination, 'partial')
        raise IOError, 'connection reset'
      end
      downloader
    end

    expect { ensure_downloaded }.to raise_error(IOError, 'connection reset')

    expect(directory.children).to be_empty
  end

  it 'accepts a configured checksum written in upper case' do
    allow(settings).to receive(:binaries).and_return({ [:linux, :arm64] => [url, checksum.upcase] })
    stub_download(payload)

    expect(ensure_downloaded).to eq(cached_binary)
    expect(cached_binary.read).to eq(payload)
  end

  it 'reports an unconfigured platform without downloading' do
    expect(Vagrant::Util::Downloader).not_to receive(:new)
    expect(ui).to receive(:error).with(/No binary configured/)

    expect(described_class.ensure_binary_downloaded(env, :linux, :riscv64)).to be_nil
  end
end
