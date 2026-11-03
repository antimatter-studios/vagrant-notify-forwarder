require_relative 'spec_helper'
require 'rbconfig'
require 'socket'

RSpec.describe 'the port a start takes', :real_ports do
  include_context 'middleware env'

  let(:utils) { VagrantPlugins::VagrantNotifyForwarder::Utils }
  let(:range) { 10 }
  let(:first) { free_range }
  let(:held) { [] }
  let(:claimants) { [] }
  let(:other_directory) { directory.join('other machine').tap(&:mkpath) }
  let(:other_machine) { double('other machine', config: config, state: state, data_dir: other_directory) }
  let(:other_env) { { machine: other_machine, ui: ui, tmp_path: directory, root_path: directory } }

  before do
    allow(state).to receive(:id).and_return(:not_created)
    allow(settings).to receive(:port) { first }
  end

  after do
    held.each(&:close)
    claimants.each { |claimant| claimant.close unless claimant.closed? }
    [env, other_env].each { |each_env| utils.release_port_claim(each_env) if utils.respond_to?(:release_port_claim) }
  end

  def bindable?(port)
    socket = UDPSocket.new
    socket.bind('127.0.0.1', port)
    socket.close
    true
  rescue SystemCallError
    socket.close
    false
  end

  def free_range
    200.times do
      base = 40_000 + rand(20_000)
      return base if (base...(base + range)).all? { |port| bindable?(port) }
    end
    raise 'No free run of UDP ports on this host'
  end

  # A second `vagrant`: a process of its own that chooses a port on a line from
  # the parent, prints it, and holds it until its stdin closes.
  CLAIMANT = <<~'RUBY'.freeze
    support, lib, first, tmp_path, data_dir = ARGV
    $LOAD_PATH.unshift(support, lib)
    require 'pathname'
    require 'vagrant'
    require 'vagrant-notify-forwarder/utils'

    settings = Struct.new(:port).new(first.to_i)
    config = Struct.new(:notify_forwarder).new(settings)
    state = Struct.new(:id).new(:not_created)
    machine = Struct.new(:config, :state, :data_dir).new(config, state, Pathname.new(data_dir))
    env = { machine: machine, tmp_path: Pathname.new(tmp_path) }

    $stdout.sync = true
    puts 'ready'
    $stdin.gets
    puts VagrantPlugins::VagrantNotifyForwarder::Utils.choose_port(env)
    $stdin.read
  RUBY

  def start_claimant(name)
    data_dir = directory.join(name).tap(&:mkpath).to_s
    arguments = [File.expand_path('support', __dir__), File.expand_path('../lib', __dir__),
                 first.to_s, directory.to_s, data_dir]
    claimant = IO.popen([RbConfig.ruby, '-e', CLAIMANT, *arguments], 'r+')
    claimants << claimant
    expect(claimant.gets).to eq("ready\n")
    claimant
  end

  def claimed_port(claimant)
    claimant.puts
    claimant.gets.to_i
  end

  def hold(port)
    socket = UDPSocket.new
    socket.bind('127.0.0.1', port)
    held << socket
  end

  it 'moves past a port taken since the configuration was read' do
    hold(first)

    expect(utils.choose_port(env)).to eq(first + 1)
    expect(directory.join('notify_forwarder_port').read.strip).to eq((first + 1).to_s)
  end

  it 'gives two machines starting in one process different ports before either is bound' do
    ports = [utils.choose_port(env), utils.choose_port(other_env)]

    expect(ports.uniq.size).to eq(2)
  end

  it 'gives threads starting machines at once different ports' do
    machines = [env, other_env]

    ports = machines.map { |each_env| Thread.new { utils.choose_port(each_env) } }.map(&:value)

    expect(ports.uniq.size).to eq(2)
  end

  it 'moves past a port another vagrant process has claimed and not yet bound' do
    claimant = start_claimant('claimant')
    expect(claimed_port(claimant)).to eq(first)

    expect(utils.choose_port(env)).to eq(first + 1)
  end

  it 'gives vagrant processes starting at the same moment different ports' do
    racing = Array.new(6) { |index| start_claimant("racer #{index}") }

    racing.each(&:puts)
    ports = racing.map { |claimant| claimant.gets.to_i }

    expect(ports.uniq.size).to eq(6)
    expect(ports).to all(be_between(first, first + range - 1))
  end

  it 'takes back a port from a vagrant process that has finished' do
    claimant = start_claimant('claimant')
    claimed_port(claimant)
    claimant.close

    expect(utils.choose_port(env)).to eq(first)
  end

  it 'takes back a port from a vagrant process that was killed' do
    claimant = start_claimant('claimant')
    claimed_port(claimant)
    Process.kill('KILL', claimant.pid)
    claimant.close

    expect(utils.choose_port(env)).to eq(first)
  end

  it 'lets a machine take the port it already claimed' do
    expect(utils.choose_port(env)).to eq(first)
    expect(utils.choose_port(env)).to eq(first)
  end

  it 'frees the port for another machine once its own has started' do
    utils.choose_port(env)
    utils.release_port_claim(env)

    expect(utils.choose_port(other_env)).to eq(first)
  end

  it 'releases the claim when the start action finishes or fails' do
    allow(vm).to receive(:network)
    allow(app).to receive(:call).and_raise('boot failed')
    start = VagrantPlugins::VagrantNotifyForwarder::Action::StartHostForwarder.new(app, env)

    expect { start.call(env) }.to raise_error('boot failed')

    expect(utils.choose_port(other_env)).to eq(first)
  end

  it 'fails, naming the range, when no port in it is free' do
    (first...(first + range)).each { |port| hold(port) }

    expect { utils.choose_port(env) }.to raise_error(Vagrant::Errors::VagrantError, /#{first}-#{first + range - 1}/)
    expect(directory.join('notify_forwarder_port')).not_to exist
  end

  it 'does not probe a port the machine kept' do
    directory.join('notify_forwarder_port').write("#{first}\n")
    hold(first)
    allow(state).to receive(:id).and_return(:running)

    expect(utils.choose_port(env)).to eq(first)
  end
end
