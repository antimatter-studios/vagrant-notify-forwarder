require_relative 'spec_helper'
require 'rbconfig'
require 'socket'
require 'timeout'

RSpec.describe 'watcher VM lifetime' do
  include_context 'middleware env'

  def start_supervisor(server)
    require_relative '../lib/vagrant-notify-forwarder/host_watcher'
    @child_pid_path = directory.join('child-pid')
    directory.join('id').write('test-machine')
    port = server.addr[1]
    @supervisor = Process.fork do
      server.close
      command = [RbConfig.ruby, '-e', 'Signal.trap("TERM", "DEFAULT"); File.write(ARGV.fetch(0), Process.pid); sleep 60', @child_pid_path.to_s]
      watcher = VagrantPlugins::VagrantNotifyForwarder::HostWatcher.new(
        command: command, host: '127.0.0.1', port: port,
        machine_id_path: directory.join('id').to_s, machine_id: 'test-machine',
        interval: 0.02, probe_timeout: 0.2
      )
      exit! watcher.run
    end
    Timeout.timeout(10) { Thread.pass until @child_pid_path.file? && @child_pid_path.size > 0 }
    @watcher_pid = @child_pid_path.read.to_i
  end

  around do |example|
    @server = TCPServer.new('127.0.0.1', 0)
    @server_thread = Thread.new do
      loop do
        client = @server.accept
        client.write("SSH-2.0-lifetime-spec\r\n")
        client.close
      end
    rescue IOError, Errno::EBADF
      nil
    end
    example.run
  ensure
    @server.close unless @server.closed?
    @server_thread.join
    if @supervisor
      begin
        if Process.waitpid(@supervisor, Process::WNOHANG).nil?
          Process.kill('TERM', @supervisor)
          Timeout.timeout(5) { Process.waitpid(@supervisor) }
        end
      rescue Errno::ECHILD, Errno::ESRCH
        nil
      end
    end
  end

  def expect_watcher_stopped
    Timeout.timeout(10) { Process.waitpid(@supervisor) }
    expect { Process.kill(0, @watcher_pid) }.to raise_error(Errno::ESRCH)
  end

  it 'terminates its child when the VM SSH endpoint disappears without a Vagrant action' do
    start_supervisor(@server)
    @server.close

    expect_watcher_stopped
  end

  it 'terminates its child when the Vagrant machine ID is removed' do
    start_supervisor(@server)
    directory.join('id').delete

    expect_watcher_stopped
  end

  it 'terminates its child when the machine ID is replaced by a new VM' do
    start_supervisor(@server)
    directory.join('id').write('replacement-machine')

    expect_watcher_stopped
  end

  it 'terminates and reaps its child when cleanup signals the supervisor' do
    start_supervisor(@server)
    Process.kill('TERM', @supervisor)

    expect_watcher_stopped
  end
end
