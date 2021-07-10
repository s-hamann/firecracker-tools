#!/usr/bin/env python3

import argparse
import atexit
import ipaddress
import json
import os
import pwd
import shutil
import subprocess
import sys
import uuid

from pathlib import Path
try:
    from packaging import version
except ModuleNotFoundError:
    pass


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
parser.add_argument('-i', '--image-base-dir', type=Path,
                    help='base path for image files, i.e. relative paths in VM config are '
                    'relative to this directory (default is the config file directory)')
parser.add_argument('-f', '--firecracker', type=Path, help='path to the firecracker binary')
parser.add_argument('-j', '--jailer', type=Path, help='path to the jailer binary')
parser.add_argument('-u', '--user', default='firecracker',
                    help='system user account to run Firecracker as')
parser.add_argument('-n', '--node', type=int, default=0, help='NUMA node to assign the VM to')
parser.add_argument('--netns', help='path to the network namespace this microVM should join')
parser.add_argument('--daemonize', action='store_true', default=False,
                    help='run the VM in a background process')
args = parser.parse_args()

if not args.config.is_file():
    raise FileNotFoundError('Config file {} not found.'.format(args.config))

if not args.kernel_base_dir:
    args.kernel_base_dir = args.config.resolve().parent

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
                             ' i8042.noaux i8042.nomux i8042.nopnp i8042.dumbkbd'}

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
    latest_version = lambda p: version.parse(str(p))
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
kernel.link_to(instance_chroot / kernel.name)

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
    p.link_to(instance_chroot / p.name)

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
jailer_cmd = [args.jailer, '--exec-file', args.firecracker, '--node', str(args.node), '--id', vmid,
              '--chroot-base-dir', args.chroot_base_dir, '--uid', str(uid), '--gid', str(gid)]
if args.netns:
    jailer_cmd += ['--netns', args.netns]
if args.daemonize:
    jailer_cmd += ['--daemonize']
jailer_cmd += ['--', '--config-file', 'config.json']

r = subprocess.run(jailer_cmd)
sys.exit(r.returncode)
