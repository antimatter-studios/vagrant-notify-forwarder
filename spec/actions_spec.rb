require_relative 'spec_helper'

RSpec.describe 'action middleware' do
  include_context 'middleware env'

  it 'leaves the disabled host start chain intact without adding a port' do
    allow(settings).to receive(:enable).and_return(false)
    expect(app).to receive(:call).with(env)
    expect(vm).not_to receive(:network)

    VagrantPlugins::VagrantNotifyForwarder::Action::StartHostForwarder.new(app, env).call(env)
  end

  it 'leaves the disabled client start chain intact without communicating' do
    allow(settings).to receive(:enable).and_return(false)
    expect(app).to receive(:call).with(env)
    expect(communicator).not_to receive(:execute)

    VagrantPlugins::VagrantNotifyForwarder::Action::StartClientForwarder.new(app, env).call(env)
  end

  it 'leaves the disabled stop chain intact without sending signals' do
    allow(settings).to receive(:enable).and_return(false)
    expect(app).to receive(:call).with(env)
    expect(Process).not_to receive(:kill)

    VagrantPlugins::VagrantNotifyForwarder::Action::StopHostForwarder.new(app, env).call(env)
  end
end
