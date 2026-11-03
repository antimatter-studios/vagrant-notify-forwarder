require_relative 'spec_helper'
require 'json'
require 'open3'

RSpec.describe VagrantPlugins::VagrantNotifyForwarder::Action::StopHostForwarder do
  include_context 'middleware env'

  subject(:middleware) { described_class.new(app, env) }

  let(:pidfile) { directory.join('notify_watcher_host_pid') }
  let(:pid) { 424242 }
  let(:identity) { "Tue Nov  3 10:00:00 2026 /tmp/notify-forwarder watch -c 127.0.0.1:29324 /host /guest" }

  before { allow(Process).to receive(:kill) }

  it 'does not signal a reused PID whose process start time has changed' do
    pidfile.write("#{pid} #{JSON.generate(identity: identity)}\n")
    allow(Open3).to receive(:capture3).and_return([
      identity.sub('10:00:00', '10:01:00'), '', double(success?: true)
    ])

    middleware.call(env)

    expect(Process).not_to have_received(:kill)
    expect(pidfile).not_to exist
  end

  it 'does not signal a legacy PID without verifiable ownership' do
    pidfile.write("#{pid}\n")

    middleware.call(env)

    expect(Process).not_to have_received(:kill)
    expect(pidfile).not_to exist
  end

  it 'does not turn malformed records into process-group signals' do
    pidfile.write("not-a-pid\n0\n-1\n")

    middleware.call(env)

    expect(Process).not_to have_received(:kill)
  end
end
