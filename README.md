About
=====

This is a set of tools for use with the [Firecracker MicroVM hypervisor](http://firecracker-microvm.io/).
These scripts can be used to:
1. Build a kernel image suitable for use with Firecracker.
2. Build a root filesystem image suitable for use with Firecracker.
3. Start a VM using Firecracker.

These scripts are suitable for non-interactive use, e.g. in a cronjob that rebuilds images or launches MicroVMs.

Dependencies
============

These scripts generally do not have particularly exotic dependencies and should simply run on most modern Linux systems. The dependencies are listed here for completeness and for the benefit of those, who run non-mainstream systems or containers.

build-kernel.sh
---------------
* bash
* GNU Coreutils or BusyBox
* GNU wget
* curl
* gnupg >= 2.1.12
* GNU grep
* tar (GNU, BSD or BusyBox)
* xz
* gzip (optional)
* bzip2 (optional)
* file
* binutils (or BusyBox)
* patch (or BusyBox) (optional)
* tput (ncurses, optional)
* [Requirements to compile the Kernel](https://www.kernel.org/doc/html/latest/process/changes.html)

build-rootfs.sh
---------------
* bash
* GNU Coreutils or BusyBox
* GNU wget
* curl
* gnupg >= 2.1.12
* util-linux
* newuidmap, newgidmap (shadow)
* awk (or BusyBox)
* GNU grep
* GNU tar or BSD tar (or BusyBox, but with limited functionality)
* e2fsprogs
* btrfs-progs (optional)
* tput (ncurses, optional)

firestarter.py
--------------
* Python >= 3.8
* [packaging](https://github.com/pypa/packaging) (optional)
* Firecracker (and Jailer)
* iproute2 (optional)

Usage
=====

All scripts provide usage information when called with the parameter `--help` or `-h`.
This section provides additional information.

build-kernel.sh
---------------

This scripts builds a kernel image that can be used by Firecracker.
Refer to `build-kernel.sh --help` for a list of parameters.
All parameters are optional.
When called without any parameters, `build-kernel.sh` does the following:
1. Determine the latest stable kernel version.
2. Download the source code for this version.
3. Verify the PGP signature on the archive.
4. Extract the source code to a temporary directory.
5. Copy the configuration file template that is most specific for the given version to the kernel build directory.
6. Completes the kernel configuration. If this requires user input and the script does not run from a terminal, this step fails.
7. Build the kernel image.
8. Copy the kernel image to the current working directory with a filename indicating the version.
9. Clean up the temporary directory.

Optional parameters can influence this sequence to some degree and eliminate some of the automatic decisions.
It is also possible to apply custom patches to the kernel source before compiling.

Running this script as `root` is neither required nor recommended.

build-rootfs.sh
---------------

This script builds one or more root filesystem images that can be used with Firecracker.
Refer to `build-rootfs.sh --help` for a list of parameters.
All parameters are optional.
When called without parameters, `build-rootfs.sh` builds all rootfs images described by `.rootfs` files in the current directory and places the resulting images in the current directory.
To build only specific images, specify the respective `.rootfs` files on the command line.
Note that images may expand on other images.
This only works if the base image(s) are built in the same call to `build-rootfs.sh` and are ordered before the depending image(s).
Having the resulting image file available is *not* sufficient.

Running this script as `root` is neither required nor recommended.
`build-rootfs.sh` automatically establishes namespace confinement.
It uses an environment similar to a container when running commands "in" the rootfs image, such as installing software using the rootfs image's package manager.
This means, however, that subuids and subgids need to be set up for the user running `build-rootfs.sh`.
To allocate a range of 65536 subuids and subgids run the following command (or similar):
```sh
usermod --add-subuid 1065536-1131071 --add-subgids 1065536-1131071 <user>
```
It is important to ensure that the ranges allocated to different users do not overlap!

### .rootfs File Format

Files with the extension `.rootfs` (by convention) define, how to programmatically build a rootfs image.
These files use a simple description language that is documented in the following.

Empty lines and lines starting with `#` are ignored.
All other lines need to start with a command, followed by a number of parameters specific to the command.
Parameters are separated by whitespace.
To include a whitespace in a parameter value, it needs to be escaped by `\`, e.g. `\ `. To include a literal `\ ` in a parameter, use `\\ `.
The following commands are implemented:

#### UMASK

Sets the umask value used when creating the filesystem image.
Expects one parameter and the is the umask value.
For example, to restrict all access to the image for 'other users':
```
UMASK 027
```
The default value is inherited from the environment from which `build-rootfs.sh` is called.

#### FROM

Every `.rootfs` file needs to contain this command. It describes the base used for the image.
Multiple forms are supported:
* `FROM scratch`  
  Start with a completely empty root filesystem.
* `FROM some.img`  
  Populate the rootfs image with the contents of `some.img`.
  Note that this only works if `some.rootfs` was already built by `build-rootfs.sh` in the same script invocation.
  The resulting `.img` file alone is not sufficient.
* `FROM some.tar`  
  Populate the rootfs image with the  contents of a (possibly compressed) tar archive `some.tar`.
  Accepted file extensions are `.tar`, `.tar.*`, `.tgz`, `.tbz`, `.tbz2`, `.tlz`, `.txz`, `.tZ` and `.tzst`.
* `FROM url [signature_url [key [...]]]`  
  Download a (possibly compressed) tar archive from `url` and extract it into the image.
  The URL of a detached PGP signature for the archive can be specified as `signature_url`.
  If one or more `key`s are given, the signature is verified against these keys.
  If no `key`s are given, the signature is verified against the default gnupg keyring of the user running `build-rootfs.sh`.
* `FROM name[:version]`  
  This is a convenient short-hand for certain known bases.
  At this time, the following values are accepted for `name`:
    * `alpine`: the [Alpine Linux](https://alpinelinux.org/) minimal root filesystem
    * `gentoo-*`: a [Gentoo Linux](https://www.gentoo.org/) stage3 archive.
      Gentoo provides various stage3 archives.
      To use a specific archive, include its "keywords" in `name`, e.g. `gentoo-hardened-nomultilib-selinux-openrc`.
      The name `gentoo` is short for `gentoo-nomultilib-openrc`.
  If `version` is set, that specific version is used.
  If it is not set, `latest` is assumed, which makes `build-rootfs.sh` detect the latest (stable) version of the given base.

Note: It is possible to use multiple `FROM` directives.
Bases are merged in the order of appearance, i.e. files from later `FROM` commands overwrite files from previous ones.

#### FILESYSTEM

Set the type of filesystem used to format the rootfs image.
Expects one parameter and that is the name of the filesystem.
For example, to use `ext2`:
```
FILESYSTEM ext2
```

Valid values are:
* `ext2` (default)
* `ext3`
* `ext4`
* `btrfs`

If `FILESYSTEM` is use multiple times, only the last instance is taken into account.
There are no restrictions on where this command may appear, in particular it does not need to (but may) be before the first `FROM` directive.

#### MAX_SIZE

Sets the maximum size of the resulting rootfs image.
Expects one parameter and that is the size in MiB.
For example, to limit the filesystem to 128 MiB (which is the default) value:
```
MAX_SIZE 128
```
It is recommended setting this directive before the first `FROM` command, but this is not strictly necessary.
If `MAX_SIZE` is used later, the limit is adjusted accordingly.
However, until then, the default value is in effect, which would cause issues if the base set up by `FROM` needs more space.

`build-rootfs.sh` builds the rootfs image in memory.
Limiting the size of the filesystem therefore serves as a limit on the amount of memory used in the process.

#### MIN_SIZE

Sets the minimum size of the resulting rootfs image.
Expects one parameter and that is the size in MiB.
For example, to request at least 0 MiB (which is the default) value:
```
MIN_SIZE 0
```

The filesystem will take up at least as much space as needed by it's contents.
`MIN_SIZE` can be used to ensure that there is some free space to work with during runtime.
For read-only use, a value of `0` is recommended.

#### RUN

Run a command in the rootfs image.
Everything after the `RUN` directive is passed to `/bin/sh` in the rootfs.
Therefore, a working `/bin/sh` needs to be present before the first `RUN` command.

For example to update the package database in an Alpine image:
```
RUN apk update
```

`RUN` can not be used before `FROM`.
But a second `FROM` may appear after `RUN`.

#### COPY

Copy one or more files from the host to the rootfs image.
Takes at least two arguments.

All but the last argument are files or directories on the host (relative paths are relative to the location of the `.rootfs` file).
These arguments can be patterns as described in the section 'Pathname Expansion' in the bash documentation.
To match `*`, `?` or `[` literally, these characters need to be enclosed in `[]`, e.g. `[*]`.

The last argument denotes a path in the root filesystem and is the target of the copy operation (relative paths are relative to `/` in the rootfs).
The file ownership is set to `root` in the rootfs.
Example:
```
COPY files/custom_issue /etc/issue
```

`COPY` can not be used before `FROM`.
But a second `FROM` may appear after `COPY`.

firestarter.py
--------------

This script runs a MicroVM using Firecracker.
It handles populating the chroot environment with the necessary files, running `jailer` (which in turn starts `firecracker`) and cleaning up the chroot after Firecracker terminates.

The only mandatory argument to `firestarter.py` is the path to a config file that describes the VM.
See [Config File Format](#Config File Format) below for further information.
`firestarter.py` also accept some optional parameters.
Refer to `firestarter.py --help` for a list.

`firestarter.py` needs to be started as `root`, since this is a requirement of `jailer`.

The first time `firestarter.py` receives a terminating signal (`SIGINT`, `SIGTERM`, `SIGQUIT`, `SIGHUP`), it sends `Ctrl+Alt+Del` to the VM, so the guest can shut down gracefully.
This does, however, require the cooperation of the guest.
If `firestarter.py` does not terminate in an acceptable time span, it is recommended to send the same signal again.
Graceful guest shutdown is attempted only once.
The second signal is passed to the Firecracker process, followed by `SIGKILL` after a short delay.

### Config File Format

`firestarter.py` expects a JSON formatted config file that contains all information about the VM.
The file format is mostly identical to the file format accepted by Firecracker with the following extensions:

* The `boot-source` section is not mandatory. If it is not present, a sensible default (i.e. the latest kernel image as created by `build-kernel.sh`) is assumed.
* Paths to the kernel, initrd and filesystems simply refer to files on the host. `firestarter.py` handles rewriting these paths for use in the chroot. Relative paths are considered to be relative to the location of the config file (or a path specified as a parameter to `firestarter.py`).
* Paths to the kernel, initrd and filesystems support globbing. If multiple files match a globbing expression the most recently modified or (if the `packaging` module is available) the one containing the highest version number is chosen.
* The `boot-source` and `drives` sections support the key `glob_order` to override the default choice of algorithm. Valid values are `most_recent` and `latest_version` (if available).
* The `network-interfaces` section has limited support for IP address configuration:
    * `host_dev_name` is not mandatory. If it is omitted but `host_bridge_name` is set, a tap device is created and connected to the bridge device `host_bridge_name`.
      The bridge needs to be fully set up on the host; it is not configured by `firestarter.py`.
    * The parameter `ip_address` can be added to a network interfaces.
      It may specify an IP address in CIDR notation or one of the special keywords `dhcp`, `bootp`, `rarp` or `any`.
      `dhcp`, `bootp` and `rarp` use the respective protocol to obtain a network configuration, `any` uses any of these protocols.
      This only works if the kernel was compiled with support for IP autoconfiguration (`CONFIG_IP_PNP`, possibly `CONFIG_IP_PNP_DHCP`, `CONFIG_IP_PNP_BOOTP`, `CONFIG_IP_PNP_RARP`) and only works for *one* network interface.
    * If `ip_address` is set, the optional parameter `gateway` can be set to the address of the gateway (or router) for the interface.
    * If `ip_address` is set, the optional parameter `dns` can be set to a list of up to two nameserver addresses.
      Note that the kernel provides the nameserver information in `/proc/net/pnp`.
      It is up to the rootfs to set up `/etc/resolv.conf` accordingly, for example by making it a symlink to `/proc/net/pnp`.

Here is an example that showcases some of the extended options:
```json
{
  "boot-source": {
    "kernel_image_path": "vmlinux-*",
    "boot_args": "console=ttyS0 reboot=k panic=1 pci=off quiet i8042.noaux i8042.nomux i8042.nopnp i8042.dumbkbd"
  },
  "drives": [
    {
      "drive_id": "rootfs",
      "path_on_host": "rootfs_*.img",
      "glob_order": "most_recent",
      "is_root_device": true,
      "is_read_only": true
    }
  ],
  "machine-config": {
    "vcpu_count": 1,
    "mem_size_mib": 128
  },
  "network-interfaces": [
    {
      "iface_id": "eth0",
      "host_bridge_name": "fcbr0",
      "ip_address": "192.168.0.2/24",
      "gateway": "192.168.0.1",
      "dns": ["192.168.0.1"]
    }
  ]
}
```

License
=======

MIT
