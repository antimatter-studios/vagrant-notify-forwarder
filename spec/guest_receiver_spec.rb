require_relative 'spec_helper'
require_relative 'support/shell_guest'
require 'digest'
require 'etc'
require 'timeout'

RSpec.describe VagrantPlugins::VagrantNotifyForwarder::Action::StartClientForwarder do
  include_context 'middleware env'

  module_name = 'VagrantPlugins::VagrantNotifyForwarder::GuestReceiver'

  let(:sandbox) { directory.join('guest') }
  let(:system_directory) { sandbox.join('usr local libexec') }
  let(:runtime_directory) { sandbox.join('run notify-forwarder') }
  let(:systemd_runtime) { sandbox.join('run systemd') }
  let(:unit) { sandbox.join('notify-forwarder.service') }
  let(:legacy) { sandbox.join('legacy notify-forwarder') }
  let(:binary) { directory.join('binary') }
  let(:guest_user) { Etc.getpwuid.name }
  let(:guest) { ShellGuest.new(sandbox) }
  let(:communicator) { guest }

  subject(:middleware) { described_class.new(app, env) }

  before do
    sandbox.mkpath
    systemd_runtime.mkpath
    stub_const("#{module_name}::SYSTEM_DIRECTORY", system_directory.to_s)
    stub_const("#{module_name}::RUNTIME_DIRECTORY", runtime_directory.to_s)
    stub_const("#{module_name}::SYSTEMD_RUNTIME", systemd_runtime.to_s)
    stub_const("#{module_name}::UNIT_PATH", unit.to_s)
    stub_const("#{module_name}::LEGACY_BINARY", legacy.to_s)
    write_binary('first')
    allow(vm).to receive(:synced_folders).and_return('project' => { hostpath: directory.to_s, guestpath: '/guest' })
    allow(middleware).to receive(:ensure_binary_downloaded).and_return(binary)
  end

  after do
    Dir.glob(File.join(sandbox.to_s, '**', 'receiver.pid')).each do |pidfile|
      begin
        Process.kill('TERM', File.read(pidfile).to_i)
      rescue Errno::ESRCH, ArgumentError
        nil
      end
    end
  end

  # Exits at once, as a receiver does on a fatal error (nonzero) or a stand-in does (zero).
  def write_exiting_binary(status)
    binary.write("#!/bin/sh\nexit #{status}\n")
    binary.chmod(0o755)
  end

  # Stays alive as a receiver does, under the arguments it was started with.
  def write_binary(marker)
    binary.write(<<~SH)
      #!/bin/sh
      # #{marker}
      printf '%s\\0' "$@" > "$(dirname "$0")/receiver.argv"
      sleep 30 &
      child=$!
      trap 'kill $child; exit 0' TERM
      wait
    SH
    binary.chmod(0o755)
  end

  def installed
    system_directory.join('notify-forwarder')
  end

  def receiver_pid(pidfile)
    Timeout.timeout(5) { sleep 0.02 until pidfile.exist? && !pidfile.read.strip.empty? }
    pidfile.read.to_i
  end

  def alive?(pid)
    Process.kill(0, pid)
    true
  rescue Errno::ESRCH
    false
  end

  def stopped?(pid)
    Timeout.timeout(5) { sleep 0.02 while alive?(pid) }
    true
  rescue Timeout::Error
    false
  end

  def folders(*paths)
    paths.each_with_index.to_h do |guestpath, index|
      [index.to_s, { hostpath: directory.join("host #{index}").to_s, guestpath: guestpath }]
    end
  end

  shared_examples 'a rooted background receiver' do
    it 'passes enabled guest roots as separate arguments without interpreting shell syntax' do
      sentinel = sandbox.join('injected')
      roots = ["/guest/team's files", %q{/guest/"quotes" \ $HOME %n}, "/guest/$(touch #{sentinel}); literal"]
      allow(vm).to receive(:synced_folders).and_return(
        folders(*roots).merge('disabled' => { guestpath: '/disabled', disabled: true })
      )

      middleware.call(env)

      arguments = process_directory.join('receiver.argv').binread.split("\0")
      expect(arguments.first(3)).to eq(['receive', '-p', '29324'])
      expect(arguments.drop(3)).to match_array(roots)
      expect(sentinel).not_to exist
    end

    it 'keeps the same process when the root set is unchanged, including spaces' do
      allow(vm).to receive(:synced_folders).and_return(folders('/guest/a b', '/guest/c'))
      middleware.call(env)
      pid = receiver_pid(process_pidfile)
      allow(vm).to receive(:synced_folders).and_return(folders('/guest/c', '/guest/a b', '/guest/c'))

      middleware.call(env)

      expect(receiver_pid(process_pidfile)).to eq(pid)
      expect(alive?(pid)).to be(true)
    end

    it 'replaces the process when an enabled guest root changes' do
      middleware.call(env)
      pid = receiver_pid(process_pidfile)
      allow(vm).to receive(:synced_folders).and_return(folders('/other guest'))

      middleware.call(env)

      expect(stopped?(pid)).to be(true)
      expect(receiver_pid(process_pidfile)).not_to eq(pid)
      expect(process_directory.join('receiver.argv').binread.split("\0")).to eq(['receive', '-p', '29324', '/other guest'])
    end

    it 'distinguishes one root containing a space from two separate roots' do
      allow(vm).to receive(:synced_folders).and_return(folders('/guest/one /guest/two'))
      middleware.call(env)
      pid = receiver_pid(process_pidfile)
      allow(vm).to receive(:synced_folders).and_return(folders('/guest/one', '/guest/two'))

      middleware.call(env)

      expect(stopped?(pid)).to be(true)
      expect(receiver_pid(process_pidfile)).not_to eq(pid)
      expect(process_directory.join('receiver.argv').binread.split("\0").drop(3)).to eq(['/guest/one', '/guest/two'])
    end

    it 'stops the previous process rather than starting an unrestricted receiver when every folder is disabled' do
      middleware.call(env)
      pid = receiver_pid(process_pidfile)
      allow(vm).to receive(:synced_folders).and_return('disabled' => { guestpath: '/guest', disabled: true })

      middleware.call(env)

      expect(stopped?(pid)).to be(true)
      expect(ui).to have_received(:error).with(/no enabled synced folders/i)
    end

    it 'does not start an unrestricted receiver when there are no synced folders' do
      allow(vm).to receive(:synced_folders).and_return({})

      middleware.call(env)

      expect(process_pidfile).not_to exist
      expect(ui).to have_received(:error).with(/no enabled synced folders/i)
    end
  end

  describe 'with sudo and systemd' do
    it 'restricts the service to enabled guest paths rather than host paths' do
      allow(vm).to receive(:synced_folders).and_return(
        folders('/guest/one', '/guest/two').merge('disabled' => { guestpath: '/disabled', disabled: true })
      )

      middleware.call(env)

      command = unit.read.lines.find { |line| line.start_with?('ExecStart=') }
      expect(Shellwords.split(command).last(2)).to eq(['/guest/one', '/guest/two'])
      expect(command).not_to include(directory.join('host').to_s, '/disabled')
    end

    it 'quotes spaces, quotes, backslashes, dollars and systemd specifiers in guest roots' do
      allow(vm).to receive(:synced_folders).and_return(folders(%q{/guest/team's "docs" \ $HOME %n}))

      middleware.call(env)

      expect(unit.read).to include(%q{"/guest/team's \"docs\" \\\\ $$HOME %%n"})
    end

    it 'restarts the service when the enabled root set changes without uploading the binary again' do
      middleware.call(env)
      guest.systemctl_log.delete
      allow(vm).to receive(:synced_folders).and_return(folders('/other guest'))

      middleware.call(env)

      expect(unit.read).to include('"/other guest"')
      expect(guest.uploads.size).to eq(1)
      expect(guest.systemctl_calls).to include('daemon-reload', 'restart notify-forwarder.service')
    end

    it 'keeps the service when only the order or duplication of roots changes' do
      allow(vm).to receive(:synced_folders).and_return(folders('/guest/one', '/guest/two'))
      middleware.call(env)
      guest.systemctl_log.delete
      allow(vm).to receive(:synced_folders).and_return(folders('/guest/two', '/guest/one', '/guest/two'))

      middleware.call(env)

      expect(guest.systemctl_calls).not_to include('daemon-reload', 'restart notify-forwarder.service')
    end

    it 'stops and disables the previous service rather than allowing an empty root set' do
      middleware.call(env)
      guest.systemctl_log.delete
      allow(vm).to receive(:synced_folders).and_return({})

      middleware.call(env)

      expect(guest.systemctl_calls).to include('disable --now notify-forwarder.service')
      expect(ui).to have_received(:error).with(/no enabled synced folders/i)
    end

    it 'does not install an unrestricted service when every folder is disabled' do
      allow(vm).to receive(:synced_folders).and_return('disabled' => { guestpath: '/guest', disabled: true })

      middleware.call(env)

      expect(unit).not_to exist
      expect(ui).to have_received(:error).with(/no enabled synced folders/i)
    end

    it 'installs the receiver in a root-owned directory and never in the shared /tmp path' do
      middleware.call(env)

      expect(Digest::SHA256.file(installed).hexdigest).to eq(Digest::SHA256.file(binary).hexdigest)
      expect(installed.stat.mode & 0o777).to eq(0o755)
      expect(guest.install_log.read).to include("-d -o root -g root -m 755 #{system_directory}")
      expect(guest.install_log.read).to match(/-o root -g root -m 0?755 .*#{Regexp.escape(installed.to_s)}/)
      expect(guest.uploads.size).to eq(1)
      expect(guest.uploads.first).not_to eq(installed.to_s)
    end

    it 'leaves no staged copy behind' do
      middleware.call(env)

      expect(Dir.children(sandbox.join('tmp'))).to eq([])
    end

    it 'runs a supervised service as the SSH user, which comes back after a reboot' do
      middleware.call(env)

      text = unit.read
      expect(text).to include("ExecStart=#{installed} receive -p 29324")
      expect(text).to include("User=#{guest_user}")
      expect(text).to include('Restart=on-failure')
      expect(text).to include('WantedBy=multi-user.target')
      expect(guest.systemctl_calls).to include('daemon-reload', 'enable notify-forwarder.service')
    end

    it 'runs the service as root only when asked to' do
      allow(settings).to receive(:run_as_root).and_return(true)

      middleware.call(env)

      expect(unit.read).to include('User=root')
    end

    it 'changes nothing on a guest that is already running it, as on a resume' do
      middleware.call(env)
      guest.systemctl_log.delete
      allow(state).to receive(:id).and_return(:saved)

      described_class.new(app, env).tap { |again| allow(again).to receive(:ensure_binary_downloaded).and_return(binary) }.call(env)

      expect(guest.uploads.size).to eq(1)
      expect(guest.systemctl_calls).not_to include('daemon-reload', 'restart notify-forwarder.service')
      expect(guest.systemctl_calls).to include('start notify-forwarder.service')
    end

    # The receiver opens each root once, when it starts. A real descriptor cannot be
    # handed to the stub, so a link under a stand-in /proc takes its place: the test
    # follows it to the directory the receiver holds, as it follows /proc/<pid>/fd/<n>.
    # A folder mounted over a root is then the root naming some other directory.
    describe 'with a service already running' do
      let(:guest) { ShellGuest.new(sandbox, main_pid: 4242) }
      let(:descriptors) { sandbox.join('proc/4242/fd') }
      let(:share) { sandbox.join('roots/share') }
      let(:repo) { sandbox.join('roots/repo') }
      let(:disk) { sandbox.join('disk') }

      before do
        stub_const("#{module_name}::PROC_DIRECTORY", sandbox.join('proc').to_s)
        descriptors.mkpath
        descriptors.join('0').write('standard input is not a root')
        [share, repo, disk.join('share'), disk.join('repo')].each(&:mkpath)
        allow(vm).to receive(:synced_folders).and_return(folders(share.to_s, repo.to_s))
        middleware.call(env)
        guest.systemctl_log.delete
      end

      def holds(directories)
        directories.each_with_index { |held, index| descriptors.join((index + 8).to_s).make_symlink(held) }
      end

      it 'restarts it when every root was mounted after it started, as on a second boot' do
        holds([disk.join('repo'), disk.join('share')])

        middleware.call(env)

        expect(guest.systemctl_calls).to include('restart notify-forwarder.service')
        expect(guest.uploads.size).to eq(1)
      end

      it 'restarts it when only one root was mounted after it started' do
        holds([repo, disk.join('share')])

        middleware.call(env)

        expect(guest.systemctl_calls).to include('restart notify-forwarder.service')
      end

      it 'leaves it running when it holds the directory each root names' do
        holds([repo, share])

        middleware.call(env)

        expect(guest.systemctl_calls).not_to include('restart notify-forwarder.service')
        expect(guest.systemctl_calls).to include('start notify-forwarder.service')
      end

      it 'leaves it running when a root is gone, since a restart would end the other roots too' do
        holds([repo, share])
        share.rmdir

        middleware.call(env)

        expect(guest.systemctl_calls).not_to include('restart notify-forwarder.service')
      end
    end

    it 'restarts the service when the port changes' do
      middleware.call(env)
      guest.systemctl_log.delete
      allow(settings).to receive(:port).and_return(29325)

      middleware.call(env)

      expect(unit.read).to include('receive -p 29325')
      expect(guest.uploads.size).to eq(1)
      expect(guest.systemctl_calls).to include('daemon-reload', 'restart notify-forwarder.service')
    end

    it 'replaces the binary and restarts the service when the binary changes' do
      middleware.call(env)
      guest.systemctl_log.delete
      write_binary('second')

      middleware.call(env)

      expect(guest.uploads.size).to eq(2)
      expect(Digest::SHA256.file(installed).hexdigest).to eq(Digest::SHA256.file(binary).hexdigest)
      expect(guest.systemctl_calls).to include('restart notify-forwarder.service')
    end

    it 'removes the binary an earlier version left in /tmp' do
      legacy.write('left by an earlier version')

      middleware.call(env)

      expect(legacy).not_to exist
    end

    it 'reports a service that does not stay up without failing the boot' do
      failing = ShellGuest.new(sandbox, is_active: 'failed')
      allow(machine).to receive(:communicate).and_return(failing)

      expect { middleware.call(env) }.not_to raise_error
      expect(ui).to have_received(:error).with(/journalctl -u notify-forwarder/)
    end

    # What systemctl says while Restart=on-failure waits to try a receiver that exited nonzero.
    it 'reports a service waiting to restart after a fatal exit without failing the boot' do
      restarting = ShellGuest.new(sandbox, is_active: 'activating')
      allow(machine).to receive(:communicate).and_return(restarting)

      expect { middleware.call(env) }.not_to raise_error
      expect(ui).to have_received(:error).with(/journalctl -u notify-forwarder/)
    end

    it 'accepts a receiver that exited cleanly, as a stand-in binary does' do
      stopped = ShellGuest.new(sandbox, is_active: 'inactive')
      allow(machine).to receive(:communicate).and_return(stopped)

      middleware.call(env)

      expect(ui).not_to have_received(:error)
    end
  end

  describe 'on a machine beside a saved one' do
    it 'starts the receiver whatever another machine in the process was doing' do
      $BOOT_SAVED = true

      middleware.call(env)

      expect(unit).to exist
    end
  end

  describe 'with sudo and no systemd' do
    let(:process_directory) { system_directory }
    let(:process_pidfile) { runtime_directory.join('receiver.pid') }

    before { systemd_runtime.rmdir }

    include_examples 'a rooted background receiver'

    it 'runs from the root-owned directory as the SSH user and keeps one process' do
      middleware.call(env)

      pid = receiver_pid(runtime_directory.join('receiver.pid'))
      expect(alive?(pid)).to be(true)
      expect(installed).to exist
      expect(unit).not_to exist

      middleware.call(env)

      expect(receiver_pid(runtime_directory.join('receiver.pid'))).to eq(pid)
      expect(alive?(pid)).to be(true)
    end

    it 'replaces the process when the port changes' do
      middleware.call(env)
      pid = receiver_pid(runtime_directory.join('receiver.pid'))
      allow(settings).to receive(:port).and_return(29325)

      middleware.call(env)

      expect(stopped?(pid)).to be(true)
      expect(receiver_pid(runtime_directory.join('receiver.pid'))).not_to eq(pid)
    end

    it 'reports a receiver that exits nonzero, naming the command that shows why' do
      write_exiting_binary(64)

      expect { middleware.call(env) }.not_to raise_error

      expect(ui).to have_received(:error).with(/exited at once.*receive -p 29324/)
    end

    it 'accepts a receiver that exits cleanly, as a stand-in binary does' do
      write_exiting_binary(0)

      middleware.call(env)

      expect(ui).not_to have_received(:error)
    end
  end

  describe 'without sudo' do
    let(:guest) { ShellGuest.new(sandbox, sudo: false) }
    let(:private_directory) { sandbox.join('home/.local/libexec/notify-forwarder') }
    let(:process_directory) { private_directory }
    let(:process_pidfile) { private_directory.join('receiver.pid') }

    include_examples 'a rooted background receiver'

    it 'runs from a directory only the SSH user can reach' do
      middleware.call(env)

      expect(private_directory.join('notify-forwarder')).to exist
      expect(private_directory.stat.mode & 0o777).to eq(0o700)
      expect(alive?(receiver_pid(private_directory.join('receiver.pid')))).to be(true)
      expect(installed).not_to exist
    end

    it 'says so when asked for root it cannot have' do
      allow(settings).to receive(:run_as_root).and_return(true)

      middleware.call(env)

      expect(ui).to have_received(:error).with(/run_as_root/)
      expect(alive?(receiver_pid(private_directory.join('receiver.pid')))).to be(true)
    end
  end
end

RSpec.describe VagrantPlugins::VagrantNotifyForwarder::Config do
  it 'runs the guest receiver unprivileged by default' do
    config = described_class.new
    config.finalize!

    expect(config.run_as_root).to eq(false)
  end
end
