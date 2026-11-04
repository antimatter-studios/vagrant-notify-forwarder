require_relative 'spec_helper'

RSpec.describe 'the upper limit of the port search' do
  include_context 'middleware env'

  let(:utils) { VagrantPlugins::VagrantNotifyForwarder::Utils }

  before do
    allow(state).to receive(:id).and_return(:not_created)
  end

  after do
    utils.release_port_claim(env)
  end

  [65526, 65530, 65535].each do |first|
    it "reports PortUnavailable after exhausting #{first}-65535" do
      allow(settings).to receive(:port).and_return(first)
      probed = []
      allow(utils).to receive(:udp_port_free?) do |port|
        probed << port
        false
      end

      expect { utils.choose_port(env) }.to raise_error(
        VagrantPlugins::VagrantNotifyForwarder::PortUnavailable,
        /#{first}-65535.*config\.notify_forwarder\.port/
      )
      expect(probed).to eq((first..65535).to_a)
      expect(directory.join('notify_forwarder_port')).not_to exist
      expect(directory.join('notify-forwarder-ports', '65536.lock')).not_to exist
    end
  end

  it 'can choose and record 65535 after the preceding ports are unavailable' do
    allow(settings).to receive(:port).and_return(65530)
    probed = []
    allow(utils).to receive(:udp_port_free?) do |port|
      probed << port
      port == 65535
    end

    expect(utils.choose_port(env)).to eq(65535)
    expect(probed).to eq((65530..65535).to_a)
    expect(directory.join('notify_forwarder_port').read).to eq("65535\n")
  end

  it 'reports PortUnavailable without probing beyond a claimed final port' do
    allow(settings).to receive(:port).and_return(65535)
    claim = utils.lock_port(env, 65535)
    expect(utils).not_to receive(:udp_port_free?)

    expect { utils.choose_port(env) }.to raise_error(
      VagrantPlugins::VagrantNotifyForwarder::PortUnavailable, /65535-65535/
    )
    expect(directory.join('notify_forwarder_port')).not_to exist
    expect(directory.join('notify-forwarder-ports', '65536.lock')).not_to exist
  ensure
    claim.close if claim
  end
end
