require_relative 'spec_helper'

RSpec.describe VagrantPlugins::VagrantNotifyForwarder::Action::StartHostForwarder do
  include_context 'middleware env'

  subject(:middleware) { described_class.new(app, env) }

  it 'forwards the notification port on the loopback interface only' do
    expect(vm).to receive(:network).with(
      :forwarded_port,
      host: 29324,
      guest: 29324,
      host_ip: '127.0.0.1',
      protocol: 'udp',
      auto_correct: true
    )

    middleware.call(env)
  end
end
