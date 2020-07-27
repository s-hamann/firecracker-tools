#!/usr/bin/env bash

# shellcheck source=functions.sh disable=1091
source "$(dirname -- "$(realpath -- "$0")")/functions.sh"

readonly E_CMDLINE=1
readonly E_IDMAP=2
readonly E_BUILD=3

cache_dir="$(dirname -- "$0")/cache"

# Defaults, can be overridden per image.
rootfs_type='ext2'
rootfs_max_size=128
rootfs_min_size=0

if [[ "${UID}" -ne 0 ]]; then
    # Unshare everything except network and restart.
    # This step ensures that we run with the same uid and gid mapping outside
    # and inside the rootfs, which is required to keep ids consistent from
    # extracted tarballs, etc.
    # Note: We can not simply exec since the uid and gid mappings need to be
    # set up from outside the user namespace. Hence the infinite sleep to keep
    # the namespace alive for the duration of this script.
    unshare --user --ipc --pid --fork --kill-child --mount --mount-proc --uts --cgroup sleep infinity &
    main_pid="$(ps -o pid= --ppid $! | tr -d ' ')"
    # This is a simplified and somewhat limited parser of /etc/sub?id. There
    # might be room for improvement here.
    min_subuid="$(grep -Po "^(${USER}|${UID}):\K([0-9]+)(?=:65536)" /etc/subuid | head -n1)"
    min_subgid="$(grep -Po "^(${USER}|${UID}):\K([0-9]+)(?=:65536)" /etc/subgid | head -n1)"
    if [[ -z "${min_subuid}" ]]; then
        printf 'Error: Could not determine valid subuid mapping for user %s\n' "${USER}" >&2
        printf 'Please add a line like '\'%s:1065536:65536\'' to /etc/subuid\n' "${USER}" >&2
        printf 'See man 5 subuid for further information\n' >&2
        exit "${E_IDMAP}"
    fi
    if [[ -z "${min_subgid}" ]]; then
        printf 'Error: Could not determine valid subgid mapping for user %s\n' "${USER}" >&2
        printf 'Please add a line like '\'%s:1065536:65536\'' to /etc/subgid\n' "${USER}" >&2
        printf 'See man 5 subgid for further information\n' >&2
        exit "${E_IDMAP}"
    fi
    newuidmap "${main_pid}" 0 "${UID}" 1 1 "${min_subuid}" 65536
    newgidmap "${main_pid}" 0 "$(id -g)" 1 1 "${min_subgid}" 65536
    # Restart self in the new namespace.
    nsenter --target "${main_pid}" --user --ipc --pid --mount --uts --cgroup --wd "$0" "$@"
    r="$?"
    # Done. End the infinite sleep and exit with the return code of the child from the namespace.
    kill -9 "${main_pid}"
    exit $r
fi

function usage() {
cat - << EOH
Usage: $0 [options] [--] [files]
 Builds one or more root filesystems for use with Firecracker.
 Valid options are:
 -h, --help
   Show this help and exit
 --interactive
   Run an interactive shell (/bin/sh) in the rootfs just after running all
   commands to set it up. This can be used for debugging or doing manual
   changes.
EOH
}

function run_in_rootfs() {
    # usage: run_in_rootfs $cmd
    # Run the given command in the currently active rootfs namespace. If no
    # namespace is active, a namespace is created and chrooted to
    # $rootfs_mount.
    start_rootfs_namespace
    nsenter --target "${chroot_pid}" --ipc --pid --mount --uts --cgroup --root --wd sh -c "$*"
}

function start_rootfs_namespace() {
    # Poor man's container: Unshare all the things (except user and network) and run the given command in a chroot at $rootfs_mount
    if [[ -z "${chroot_pid}" ]]; then
        unshare --ipc --pid --fork --kill-child --mount --mount-proc --root="${rootfs_mount}" --wd=/ --uts --cgroup sleep infinity &
        chroot_pid="$(ps -o pid= --ppid $! | tr -d ' ')"
        disown $!
    fi
}

function stop_rootfs_namespace() {
    if [[ -n "${chroot_pid}" ]]; then
        kill -9 "${chroot_pid}"
        unset chroot_pid
    fi
}

function build_image() {
    (
    # Note: Everything in this function runs in a subshell, mostly so that we can use a trap on errors that wipe the mount point.
    local file="$1"
    local rootfs_mount="${tmpdir}/$(basename -- "${f%.rootfs}")"
    local rootfs_base_mount
    local rootfs_url
    local rootfs_file
    local signature_url
    local signature_keys
    local rootfs_base_name
    local rootfs_base_version
    local rootfs_type="${rootfs_type}"
    local rootfs_size
    local rootfs_min_size="${rootfs_min_size}"
    local rootfs_max_size="${rootfs_max_size}"
    local resolv_conf_checksum
    mkdir -p -- "${rootfs_mount}"
    trap 'code=$?; if [[ "${code}" -gt 1 ]]; then if mountpoint --quiet "${rootfs_mount}"; then umount "${rootfs_mount}"; fi; rmdir "${rootfs_mount}"; fi; exit "${code}"' EXIT

    # Parse the rootfs setup file.
    # shellcheck disable=SC2094
    while read -r line; do
        if [[ "${line}" =~ ^\s*# || "${line}" =~ ^\s*$ ]]; then
            # Skip comments.
            continue
        fi
        local cmd="${line%% *}"
        local -a argv
        mapfile -t argv < <(awk 'BEGIN{FPAT = "([^[:space:]]+)|(\"[^\"]+\")"}{for(i=1; i<=NF; i++) print $i}' <<< "${line#${cmd}}")
        local argc="${#argv[@]}"
        case "${cmd}" in
            FROM)
                local base="${argv[0]}"
                case "${base}" in
                    *.img)
                        # Base is a local image.
                        rootfs_base_mount="${tmpdir}/${base%.img}"
                        if [[ ! -d "${rootfs_base_mount}" ]]; then
                            die 2 "${file}: Error: Base image ${base} not found"
                        fi
                        ;;
                    *.tar|*.tar.*|*.tgz|*.tbz|*.tbz2|*.txz)
                        # Base is a tar archive.
                        rootfs_file="${base}"
                        ;;
                    http://*|https://*|ftp://*)
                        # Base is a URL.
                        rootfs_url="${base}"
                        if [[ -n "${argv[1]}" ]]; then
                            signature_url="${argv[1]}"
                        fi
                        if [[ -n "${argv[2]}" ]]; then
                            signature_keys=( "${argv[@]:2}" )
                        fi
                        ;;
                    *)
                        # Base is a name for an upstream image, optionally with a version.
                        rootfs_base_name="${base%%:*}"
                        rootfs_base_version="${base#*:}"
                        if [[ "${rootfs_base_version}" == "${base}" ]]; then
                            rootfs_base_version='latest'
                        fi
                        case "${rootfs_base_name}" in
                            scratch)
                                ;;
                            alpine)
                                if [[ "${rootfs_base_version}" == 'latest' ]]; then
                                    # Get latest stable version.
                                    rootfs_base_version="$(curl --silent "http://dl-cdn.alpinelinux.org/alpine/latest-stable/releases/$(uname -m)/" | grep -Po '(?<=alpine-minirootfs-)[0-9]+\.[0-9]+\.[0-9]+(?!_rc[0-9])' | sort -Vu | tail -n1)"
                                fi
                                rootfs_url="http://dl-cdn.alpinelinux.org/alpine/v${rootfs_base_version%.*}/releases/$(uname -m)/alpine-minirootfs-${rootfs_base_version}-$(uname -m).tar.gz"
                                signature_url="http://dl-cdn.alpinelinux.org/alpine/v${rootfs_base_version%.*}/releases/$(uname -m)/alpine-minirootfs-${rootfs_base_version}-$(uname -m).tar.gz.asc"
                                signature_keys=('0482 D840 22F5 2DF1 C4E7 CD43 293A CD09 07D9 495A')
                                ;;
                            *)
                                die 2 "${file}: Error: Unknown image base ${rootfs_base_name}"
                                ;;
                        esac
                        ;;
                esac

                # Mount a tmpfs at the root of the new rootfs.
                if ! mountpoint --quiet "${rootfs_mount}"; then
                    if ! mount -t tmpfs -o size="${rootfs_max_size}M",mode=0700 tmpfs "${rootfs_mount}"; then
                        die 2 "${file}: Error: Could not mount tmpfs at ${rootfs_mount}"
                    fi
                fi

                # Fill the rootfs with content.
                if [[ -n "${rootfs_url}" || -n "${rootfs_file}" ]]; then
                    if [[ -n "${rootfs_url}" ]]; then
                        # Download the rootfs archive.
                        if ! download "${rootfs_url}"; then
                            die 2 "${file}: Error: Could not download rootfs base from ${rootfs_url}"
                        fi
                        # shellcheck disable=SC2154
                        rootfs_file="${downloaded_file}"
                        if [[ -n "${signature_url}" ]]; then
                            if ! download "${signature_url}"; then
                                die 2 "${file}: Error: Could not download rootfs base signature from ${signature_url}"
                            fi
                            # shellcheck disable=SC2154
                            local signature_file="${downloaded_file}"
                            # Verify the signature.
                            local verify_opts=()
                            for key in "${signature_keys[@]}"; do
                                verify_opts+=('--key' "${key}")
                            done
                            if ! verify_signature "${verify_opts[@]}" "${rootfs_file}" "${signature_file}"; then
                                die 2 "${file}: Error: Could not verify signature on ${rootfs_file}"
                            fi
                        fi
                    fi
                    # Extract the rootfs archive.
                    case "$(tar --version | head -n1)" in
                        'tar (GNU tar)'*)
                            tar_opts=('--numeric-owner' '--xattrs' '--xattrs-include="*"' '--acls')
                            ;;
                        bsdtar*)
                            tar_opts=('--numeric-owner' '--xattrs' '--acls')
                            ;;
                        *)
                            # BusyBox tar, for instance.
                            printf 'Warning: Unknown or unsupported tar implementation. ACLs, extended attributes or SELinux contexts may be missing or extraction may fail completely.\n' >&2
                            tar_opts=('--numeric-owner')
                            ;;
                    esac
                    if ! tar -xpf "${rootfs_file}" -C "${rootfs_mount}" "${tar_opts[@]}"; then
                        die 2 "${file}: Error: Could not extract $(basename -- "${rootfs_url}")"
                    fi
                elif [[ -n "${rootfs_base_mount}" ]]; then
                    # Copy everything from the base image into the new rootfs image.
                    if ! cp -Ta -- "${rootfs_base_mount}" "${rootfs_mount}"; then
                        die 2 "${file}: Error: Could not copy files from ${rootfs_base_mount}"
                    fi
                fi

                # Make DNS available in the chroot.
                if [[ -z "${resolv_conf_checksum}" ]]; then
                    if [[ -e "${rootfs_mount}/etc/resolv.conf" || -h "${rootfs_mount}/etc/resolv.conf" ]]; then
                        # Make a backup of the rootfs /etc/resolv.conf.
                        mv -T -- "${rootfs_mount}/etc/resolv.conf" "${tmpdir}/resolv.conf"
                    fi
                    # Copy the host's /etc/resolv.conf to the rootfs and store its contents to later check if it was changed.
                    cp -aL -- /etc/resolv.conf "${rootfs_mount}/etc/resolv.conf"
                    resolv_conf_checksum="$(md5sum -- "${rootfs_mount}/etc/resolv.conf" 2>/dev/null)"
                fi

                ;;
            FILESYSTEM)
                if [[ "${argc}" -ne 1 ]]; then
                    die 2 "${file}: Error: ${cmd} expects exactly 1 argument"
                fi
                rootfs_type="${argv[0]}"
                ;;
            MAX_SIZE)
                if [[ "${argc}" -ne 1 ]]; then
                    die 2 "${file}: Error: ${cmd} expects exactly 1 argument"
                fi
                rootfs_max_size="${argv[0]}"
                if mountpoint --quiet "${rootfs_mount}"; then
                    mount -o "remount,size=${rootfs_max_size}M" "${rootfs_mount}"
                fi
                ;;
            MIN_SIZE)
                if [[ "${argc}" -ne 1 ]]; then
                    die 2 "${file}: Error: ${cmd} expects exactly 1 argument"
                fi
                rootfs_min_size="${argv[0]}"
                ;;
            RUN)
                if [[ "${argc}" -lt 1 ]]; then
                    die 2 "${file}: Error: ${cmd} expects at least 1 argument"
                fi
                if ! mountpoint --quiet "${rootfs_mount}"; then
                    die 2 "${file}: Error: ${cmd} can not apprear before FROM"
                fi
                run_in_rootfs "${line#${cmd} }"
                ;;
            COPY)
                if [[ "${argc}" -lt 2 ]]; then
                    die 2 "${file}: Error: ${cmd} expects at least 2 arguments"
                fi
                if ! mountpoint --quiet "${rootfs_mount}"; then
                    die 2 "${file}: Error: ${cmd} can not apprear before FROM"
                fi
                (cd -- "$(dirname -- "${file}")" && cp -dR -- "${argv[@]:0:((${argc}-1))}" "${rootfs_mount}/${argv[-1]}")
                ;;
            *)
                die 2 "${file}: Error: Invalid directive ${cmd}"
                ;;
        esac
    done < "${file}"

    if "${interactive}"; then
        # Run an interactive shell in the rootfs, useful for debugging or manual changes.
        run_in_rootfs /bin/sh
    fi

    stop_rootfs_namespace

    # Restore original /etc/resolv.conf if the resolv.conf in the rootfs was not changed.
    if md5sum -c <<< "${resolv_conf_checksum}" &>/dev/null; then
        rm -f -- "${rootfs_mount}/etc/resolv.conf"
        if [[ -e "${tmpdir}/resolv.conf" || -h "${tmpdir}/resolv.conf" ]]; then
            mv -T -- "${tmpdir}/resolv.conf" "${rootfs_mount}/etc/resolv.conf"
        fi
    fi

    # Determine size of the disk image.
    rootfs_size="$(du -m -s -- "${rootfs_mount}" | cut -f1)"
    case "${rootfs_type}" in
        ext3|ext4)
            # Add 4 MiB for the journal.
            (( rootfs_size+=4 ))
            ;;
        btrfs)
            # Btrfs needs about 88 MiB for itself.
            (( rootfs_size+=88 ))
            if [[ "${rootfs_min_size}" -lt 109 ]]; then
                # Btrfs needs at least 109 MiB.
                rootfs_min_size=109
            fi
            ;;
    esac
    if [[ "${rootfs_min_size}" -gt "${rootfs_size}" ]]; then
        rootfs_size="${rootfs_min_size}"
    fi

    local rootfs_image_file="${f%.rootfs}.img"
    # Create an empty file for the image.
    if ! dd if=/dev/zero of="${rootfs_image_file}" bs=1M count="${rootfs_size}"; then
        die 1 "${file}: Error: Could not create image ${rootfs_image_file}"
    fi
    # Format with the appropriate filesystem.
    case "${rootfs_type}" in
        ext2|ext3|ext4)
            if ! mke2fs -t "${rootfs_type}" -L root -m 0 -d "${rootfs_mount}" "${rootfs_image_file}"; then
                die 1 "${file}: Error: Could not format ${rootfs_image_file} as ${rootfs_type}"
            fi
            ;;
        btrfs)
            if ! mkfs.btrfs --label root --rootdir "${rootfs_mount}" "${rootfs_image_file}"; then
                die 1 "${file}: Error: Could not format ${rootfs_image_file} as ${rootfs_type}"
            fi
            ;;
        *)
            die 1 "${file}: Error: Unsupported filesystem ${rootfs_type}"
            ;;
    esac
    )
}

function cleanup() {
    stop_rootfs_namespace
    if [[ -n "${tmpdir}" ]]; then
        [[ -d "${tmpdir}/busybox-bin" ]] && rm -rf -- "${tmpdir}/busybox-bin"
        for dir in "${tmpdir}"/*; do
            if mountpoint --quiet -- "${dir}"; then
                umount -- "${dir}"
            fi
            if [[ -d "${dir}" ]]; then
                rmdir -- "${dir}"
            fi
        done
        if [[ -d "${tmpdir}" ]]; then
            rmdir -- "${tmpdir}"
        fi
    fi
}

interactive=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            exit
            ;;
        --interactive)
            interactive=true
            ;;
        --)
            # End of command line options.
            shift
            break
            ;;
        -*)
            printf 'Error: Unknown option %s\n' "$1" >&2
            usage >&2
            exit ${E_CMDLINE}
            ;;
        *)
            # First non-option argument -> end of command line options.
            break
            ;;
    esac
    shift
done
if [[ $# -eq 0 ]]; then
    shopt -s nullglob
    rootfs_files=( *.rootfs )
    shopt -u nullglob
else
    rootfs_files=( "$@" )
fi

mkdir -p "${cache_dir}"

tmpdir="$(mktemp -d -p "${TMPDIR:-/tmp}" build-rootfs.XXXXXX)"
trap cleanup EXIT INT TERM QUIT
busybox_setup "${tmpdir}/busybox-bin"

errors=0
for f in "${rootfs_files[@]}"; do
    build_image "${f}" || (( errors++ ))
done
if [[ "${errors}" -gt 0 ]]; then
    exit "${E_BUILD}"
fi
