require_relative 'spec_helper'

RSpec.describe VagrantPlugins::VagrantNotifyForwarder::Action::CheckBootState do
  include_context 'middleware env'

  subject(:middleware) { described_class.new(app, env) }

  it 'continues booting when the plugin is disabled without inspecting machine state' do
    allow(settings).to receive(:enable).and_return(false)
    expect(machine).not_to receive(:state)
    expect(app).to receive(:call).with(env)

    middleware.call(env)
  end

  it 'continues booting an enabled running machine' do
    expect(app).to receive(:call).with(env)

    middleware.call(env)

    expect($BOOT_SAVED).to eq(false)
  end

  it 'continues booting an enabled saved machine' do
    allow(state).to receive(:id).and_return(:saved)
    expect(app).to receive(:call).with(env)

    middleware.call(env)

    expect($BOOT_SAVED).to eq(true)
  end
end
