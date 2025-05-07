#!/usr/bin/env python3

import argparse
import atexit
import ipaddress
import json
import os
import pwd
import re
import shutil
import signal
import socket
import subprocess
import sys
import time
import uuid

from pathlib import Path
try:
    from packaging import version
except ModuleNotFoundError:
    pass


# For compatibility with Python 3.8/3.9: Implement pathlib.Path.hardlink_to
if not hasattr(Path, 'hardlink_to'):
    Path.hardlink_to = lambda self, target: target.link_to(self)


class ConfigError(Exception):
    pass


@atexit.register
def cleanup():
    """Clean up temporary resources created by this script."""
    # Remote tap interfaces created before running firecracker.
    for tap in created_tap_interfaces:
        subprocess.run(['ip', 'link', 'delete', 'dev', tap])
    # Remove the chroot directory.
    try:
        shutil.rmtree(instance_dir)
    except NameError:
        pass


def signal_handler(sig, frame):
    """Handler for terminating signals. Send CtrlAltDel to the firecracker process on first
    invocation. Forward the signal and kill firecracker on subsequent invocations.

    :sig: signal number
    :frame: current stack frame

    """

    if not hasattr(signal_handler, "SentCtrlAltDel"):

        # Send Ctrl+Alt+Del via the Firecracker API socket so the guest can shut down gracefully.
        shutdown_request = ('PUT /actions HTTP/1.0\r\n'
                            'Content-Type: application/json\r\n'
                            'Content-Length: 33\r\n'
                            '\r\n'
                            '{"action_type": "SendCtrlAltDel"}')
        api_client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        api_client.settimeout(0.1)
        api_client.connect(bytes(Path(instance_chroot / 'run' / 'firecracker.socket')))
        api_client.send(shutdown_request.encode())
        try:
            while len(api_client.recv(256)) >= 256:
                pass
        except socket.timeout:
            pass
        api_client.close()
        signal_handler.SentCtrlAltDel = True

    else:

        # This is the second signal. If the guest did not react to Ctrl+Alt+Del the first time,
        # it won't do so when sending it again. Pass the signal to the Firecracker process and
        # follow up with SIGKILL.
        if firecracker_process.poll() is None:
            # Our direct child process is still running. Signal it.
            firecracker_process.send_signal(sig)
            try:
                firecracker_process.communicate(timeout=0.25)
            except subprocess.TimeoutExpired:
                firecracker_process.kill()
        else:
            # Our direct child has terminated. This means it forked and we are really waiting
            # for firecracker_pid.
            if type(firecracker_pid) == int:
                os.kill(firecracker_pid, sig)
                time.sleep(0.25)
                try:
                    os.kill(firecracker_pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            else:
                signal.pidfd_send_signal(firecracker_pid.fileno(), sig)
                time.sleep(0.25)
                try:
                    signal.pidfd_send_signal(firecracker_pid.fileno(), signal.SIGKILL)
                except ProcessLookupError:
                    pass


created_tap_interfaces = []

# Set up the command line arguments parser.
parser = argparse.ArgumentParser(description='Run a given virtual machine in Firecracker')
parser.add_argument('config', type=Path,
                    help='path to a config file in JSON format that describes the VM')
parser.add_argument('-d', '--chroot-base-dir', type=Path, default=Path('chroot'),
                    help='base of the Firecracker chroot directory')
parser.add_argument('-k', '--kernel-base-dir', type=Path,
                    help='base path for kernel files, i.e. relative paths in VM config are '
                    'relative to this directory (default is the config file directory)')
parser.add_argument('--initrd-base-dir', type=Path,
                    help='base path for initrd files, i.e. relative paths in VM config are '
                    'relative to this directory (default is the kernel base directory)')
parser.add_argument('-i', '--image-base-dir', type=Path,
                    help='base path for image files, i.e. relative paths in VM config are '
                    'relative to this directory (default is the config file directory)')
parser.add_argument('-f', '--firecracker', type=Path, help='path to the firecracker binary')
parser.add_argument('-j', '--jailer', type=Path, help='path to the jailer binary')
parser.add_argument('-u', '--user', default='firecracker',
                    help='system user account to run Firecracker as')
parser.add_argument('--new-pid-ns', action='store_true', help='exec into a new PID namespace')
parser.add_argument('--netns', help='path to the network namespace this microVM should join')
parser.add_argument('--cgroup', action='append',
                    help='cgroup and value to be set by the jailer. This argument can be used '
                    'multiple times and is passed to jailer as is.')
parser.add_argument('--resource-limit', action='append',
                    help='resource limit values to be set by the jailer. This argument can be '
                    'used multiple times and is passed to jailer as is.')
parser.add_argument('--daemonize', action='store_true', default=False,
                    help='run the VM in a background process')
seccomp = parser.add_mutually_exclusive_group()
seccomp.add_argument('--no-seccomp', action='store_true',
                    help='disables seccomp filtering. Not recommended.')
seccomp.add_argument('--seccomp-filter', type=Path,
                    help='path to a custom seccomp filter. For advanced users.')
args = parser.parse_args()

if not args.config.is_file():
    raise FileNotFoundError('Config file {} not found.'.format(args.config))

if not args.kernel_base_dir:
    args.kernel_base_dir = args.config.resolve().parent

if not args.initrd_base_dir:
    args.initrd_base_dir = args.kernel_base_dir

if not args.image_base_dir:
    args.image_base_dir = args.config.resolve().parent

if not args.firecracker:
    try:
        args.firecracker = Path(shutil.which('firecracker'))
    except TypeError:
        pass

if not args.firecracker or not args.firecracker.is_file():
    raise FileNotFoundError('firecracker binary not found.')

if not args.jailer:
    try:
        args.jailer = Path(shutil.which('jailer'))
    except TypeError:
        pass

if not args.jailer or not args.jailer.is_file():
    raise FileNotFoundError('jailer binary not found.')

# Get the user's numeric user id and primary group id.
uid, gid = pwd.getpwnam(args.user)[2:4]

# Read the VM config file.
with args.config.open('r') as f:
    config = json.load(f)

if 'boot-source' not in config:
    # Add default boot-source section.
    config['boot-source'] = {'kernel_image_path': 'vmlinux-*',
                             'boot_args': 'console=ttyS0 reboot=k panic=1 pci=off quiet'
                             ' i8042.noaux i8042.nomux i8042.dumbkbd'}

# Generate a unique ID for the VM instance.
vmname = args.config.stem if args.config.suffix == '.json' else args.config.name
vmid = '{name}-{uuid}'.format(name=vmname, uuid=uuid.uuid4())

# Determine the chroot directory that jailer will use.
if not args.chroot_base_dir.is_absolute:
    # Make chroot_base_dir an absolute path.
    args.chroot_base_dir = args.config.resolve().parent / args.chroot_base_dir
instance_dir = args.chroot_base_dir / 'firecracker' / vmid
instance_chroot = instance_dir / 'root'

# Create the instance chroot directory.
instance_chroot.mkdir(mode=0o750, parents=True)
os.chown(instance_chroot, -1, gid)

# Helper functions for sorting if multiple files match a globbing expression.
most_recent = lambda p: p.stat().st_mtime
default_glob_order = most_recent
if 'version' in globals():
    # packaging.version does not support version numbers embedded in strings. So we extract the
    # version number and pass only that to packaging.version.parse.
    version_regex = re.compile(version.VERSION_PATTERN, re.VERBOSE | re.IGNORECASE)

    def latest_version(filename):
        """Parse and return the version number embedded in in the file name.

        :filename: the file name to parse
        :returns: packaging.version.Version object representing the embedded version number or None
        """
        version_part = version_regex.search(str(filename))
        if version_part is not None:
            return version.parse(version_part.group())
        return None

    default_glob_order = latest_version

# Resolve the kernel path.
kernel = Path(config['boot-source']['kernel_image_path'])
if kernel.is_absolute():
    kernel_glob = str(kernel.relative_to('/'))
    kernel_glob_base = Path('/')
else:
    kernel_glob = str(kernel)
    kernel_glob_base = args.kernel_base_dir
try:
    glob_order = config['boot-source']['glob_order']
    del config['boot-source']['glob_order']
    glob_order = globals()[glob_order]
except KeyError:
    glob_order = default_glob_order
try:
    kernel = max(kernel_glob_base.glob(kernel_glob), key=glob_order)
except ValueError:
    raise ConfigError('{}: No such file or directory.'.format(kernel))
# Store only the file name in the config, as the full path is meaningless in the chroot.
config['boot-source']['kernel_image_path'] = kernel.name
# Hardlink the kernel to the instance chroot.
(instance_chroot / kernel.name).hardlink_to(kernel)

# Resolve the initrd path.
if 'initrd_path' in config['boot-source']:
    initrd = Path(config['boot-source']['initrd_path'])
    if initrd.is_absolute():
        initrd_glob = str(initrd.relative_to('/'))
        initrd_glob_base = Path('/')
    else:
        initrd_glob = str(initrd)
        initrd_glob_base = args.initrd_base_dir
    try:
        glob_order = config['boot-source']['glob_order']
        del config['boot-source']['glob_order']
        glob_order = globals()[glob_order]
    except KeyError:
        glob_order = default_glob_order
    try:
        initrd = max(initrd_glob_base.glob(initrd_glob), key=glob_order)
    except ValueError:
        raise ConfigError('{}: No such file or directory.'.format(initrd))
    # Store only the file name in the config, as the full path is meaningless in the chroot.
    config['boot-source']['initrd_path'] = initrd.name
    # Hardlink the initrd to the instance chroot.
    (instance_chroot / initrd.name).hardlink_to(initrd)

# Resolve the drives' paths.
for drive in config['drives']:
    p = Path(drive['path_on_host'])
    if p.is_absolute():
        p = str(p.relative_to('/'))
        p_glob_base = Path('/')
    else:
        p_glob = str(p)
        p_glob_base = args.image_base_dir
    try:
        glob_order = drive['glob_order']
        del drive['glob_order']
        glob_order = globals()[glob_order]
    except KeyError:
        glob_order = default_glob_order
    try:
        p = max(p_glob_base.glob(p_glob), key=glob_order)
    except ValueError:
        raise ConfigError('{}: No such file or directory.'.format(p))
    # Store only the file name in the config, as the full path is meaningless in the chroot.
    drive['path_on_host'] = p.name
    # Hardlink the drive to the instance chroot.
    (instance_chroot / p.name).hardlink_to(p)

# Handle custom seccomp filter.
if args.seccomp_filter:
    shutil.copy(args.seccomp_filter, Path(instance_chroot / 'seccomp.bpf'))

# Handle networking.
if 'network-interfaces' in config:
    for i, interface in enumerate(config['network-interfaces']):
        if 'host_dev_name' not in interface and 'host_bridge_name' in interface:
            interfaces = os.listdir('/sys/class/net')
            for j in range(32768):
                if 'fctap' + str(j) not in interfaces:
                    tap = 'fctap' + str(j)
                    break
            created_tap_interfaces.append(tap)
            subprocess.run(['ip', 'tuntap', 'add', 'dev', tap, 'mode', 'tap', 'user', args.user],
                           check=True)
            subprocess.run(['ip', 'link', 'set', 'dev', tap, 'master',
                            interface['host_bridge_name']], check=True)
            subprocess.run(['ip', 'link', 'set', 'dev', tap, 'up'], check=True)
            interface['host_dev_name'] = tap
            del interface['host_bridge_name']
        if 'ip_address' in interface:
            if interface['ip_address'] in ['dhcp', 'bootp', 'rarp', 'any']:
                autoconf = interface['ip_address']
                ip = ''
                netmask = ''
            else:
                autoconf = 'off'
                ip = interface['ip_address'].split('/')[0]
                netmask = ipaddress.ip_network(interface['ip_address'], strict=False).netmask
            del interface['ip_address']
            try:
                gateway = interface['gateway']
                del interface['gateway']
            except KeyError:
                gateway = ''
            try:
                dns = interface['dns']
                del interface['dns']
            except KeyError:
                dns = ''
            config['boot-source']['boot_args'] += (
                ' ip={ip}::{gateway}:{netmask}:{hostname}:{device}:{autoconf}:{dns}'.
                format(ip=ip, gateway=gateway, netmask=netmask, hostname=vmid,
                       device='eth' + str(i), autoconf=autoconf, dns=':'.join(dns))
            )

# Write config.json.
with Path(instance_chroot / 'config.json').open('w') as f:
    json.dump(config, f)

# Run jailer.
jailer_cmd = [args.jailer, '--exec-file', args.firecracker, '--id', vmid,
              '--chroot-base-dir', args.chroot_base_dir, '--uid', str(uid), '--gid', str(gid)]
if args.new_pid_ns:
    jailer_cmd += ['--new-pid-ns']
if args.netns:
    jailer_cmd += ['--netns', args.netns]
if args.cgroup:
    for cgroup in args.cgroup:
        jailer_cmd += ['--cgroup', cgroup]
if args.resource_limit:
    for limit in args.resource_limit:
        jailer_cmd += ['--resource-limit', limit]
if args.daemonize:
    jailer_cmd += ['--daemonize']
jailer_cmd += ['--', '--config-file', 'config.json']
if args.no_seccomp:
    jailer_cmd += ['--no-seccomp']
elif args.seccomp_filter:
    jailer_cmd += ['--seccomp-filter', 'seccomp.bpf']

# Set up a signal handler to gracefully shut down the VM when signalled.
for sig in [signal.SIGINT, signal.SIGTERM, signal.SIGQUIT, signal.SIGHUP]:
    signal.signal(sig, signal_handler)

# Run jailer/firecracker and wait for the process to finish but store a reference to the child
# process.
firecracker_process = subprocess.Popen(jailer_cmd)
firecracker_process.communicate()

if args.new_pid_ns:
    # With --new-pid-ns, jailer forks and therefore does not block until firecracker terminates.
    # We need to wait for firecracker before we can exit and clean up the chroot directory.
    with Path(instance_chroot / 'firecracker.pid').open('r') as f:
        # Get the PID of the firecracker process from the file firecracker.pid in the root of the
        # chroot directory.
        firecracker_pid = int(f.read())
        try:
            # pidfd_open is superior but requires Python 3.9+ and Linux 5.3+.
            # If this fails, fall back to traditional process management.
            firecracker_pid = open(os.pidfd_open(firecracker_pid))
        except Exception:
            pass
        while True:
            try:
                # Send signal 0 (no signal), to check if the process is still alive.
                if type(firecracker_pid) == int:
                    os.kill(firecracker_pid, 0)
                else:
                    signal.pidfd_send_signal(firecracker_pid.fileno(), 0)
            except ProcessLookupError:
                # The firecracker process has exited, we can clean up now.
                if type(firecracker_pid) != int:
                    firecracker_pid.close()
                break
            time.sleep(0.25)
sys.exit(firecracker_process.returncode)
