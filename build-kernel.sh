#!/usr/bin/env bash

# shellcheck source=functions.sh disable=1091
source "$(dirname -- "$(realpath -- "$0")")/functions.sh"

readonly E_CMDLINE=1
readonly E_DOWNLOAD=2
readonly E_EXTRACT=3
readonly E_PATCH=4
readonly E_CONFIG=5
readonly E_MAKE=6
readonly E_INCONSISTENCY=7

function usage() {
cat - << EOH
Usage: $0 [options]
 Builds a kernel image for use with Firecracker.
 Valid options are:
 -h, --help
   Show this help and exit
 -c file, --config=file
   Use the specified file as the kernel configuration.
   If this options is omitted, the config file that is most specific for the
   kernel version is used, i.e. kernel-config, kernel-config-x.y or
   kernel-config-x.y.z.
 --menuconfig
   Run make menuconfig to interactively configure the kernel, based on the
   selected config file.
   Implies --force.
 -o file, --output=file
   Write the kernel image to the specified path. Defaults to vmlinux-x.y.z in
   the current working directory.
 --version x.y.z|regex
   If the parameter is given in the form x.y.z, build that kernel version.
   Otherwise it is interpreted as a perl compatible regular expression to match
   one line on https://www.kernel.org/finger_banner. The kernel version on that
   line will be built. If multiple lines match, the fist line is considered.
   Defaults to 'latest stable version'.
 -p file, --patch=file
   Apply the given patch to the kernel source code before building. file may
   refer to a patch file, a compressed patch file or a (compressed) tar archive
   containing multiple patch files.
   This option can be used multiple times to apply multiple patches.
 --force
   Force building a new kernel. If this option is not given, the image is not
   built if the output file exists, matches the kernel version and is newer
   than the config file.
EOH
}

function cleanup() {
    if [[ -n "${tmpdir}" ]]; then
        [[ -d "${tmpdir}/build" ]] && rm -rf -- "${tmpdir}/build"
        [[ -d "${tmpdir}/patches" ]] && rm -rf -- "${tmpdir}/patches"
        [[ -d "${tmpdir}/busybox-bin" ]] && rm -rf -- "${tmpdir}/busybox-bin"
        [[ -n "${kernel_uncompressed_file}" && -e "${kernel_uncompressed_file}" ]] && rm -f -- "${kernel_uncompressed_file}"
        [[ -d "${tmpdir}" ]] && rmdir -- "${tmpdir}"
    fi
}
trap cleanup EXIT INT TERM QUIT

kernel_version='latest stable version'
menuconfig=false
force_build=false
patches=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help)
            usage
            exit
            ;;
        --force)
            force_build=true
            ;;
        --menuconfig)
            menuconfig=true
            force_build=true
            ;;
        -c|--config|--config=*)
            if [[ "$1" == "${1%=*}" ]]; then
                kernel_config_file="$2"
                shift
            else
                kernel_config_file="${1#*=}"
            fi
            if [[ ! -f "${kernel_config_file}" || ! -r "${kernel_config_file}" ]]; then
                die ${E_CMDLINE} "Error: Could not read kernel config file ${kernel_config_file}"
            fi
            ;;
        -o|--output|--output=*)
            if [[ "$1" == "${1%=*}" ]]; then
                output_file="$2"
                shift
            else
                output_file="${1#*=}"
            fi
            ;;
        -p|--patch|--patch=*)
            if [[ "$1" == "${1%=*}" ]]; then
                patches+=("$2")
                shift
            else
                patches+=("${1#*=}")
            fi
            ;;
        --version|--version=*)
            if [[ "$1" == "${1%=*}" ]]; then
                kernel_version="$2"
                shift
            else
                kernel_version="${1#*=}"
            fi
            ;;
        *)
            usage >&2
            exit ${E_CMDLINE}
            ;;
    esac
    shift
done

# Get the latest kernel version.
if [[ "${kernel_version}" != *.*.* ]]; then
    regex="${kernel_version}"
    kernel_version="$(curl --silent --location https://www.kernel.org/finger_banner | grep -Po "${regex}.*:\s*\K([0-9]+\.[0-9]+\.[0-9]+)" | head -n1)"
    if [[ "${kernel_version}" != *.*.* ]]; then
        die "${E_CMDLINE}" "Error: Could not get latest kernel version from regex '${regex}'."
    fi
    unset regex
fi

# Parse the kernel version.
kernel_version_base="${kernel_version%.*}"

# Get the best matching kernel config file.
if [[ -z "${kernel_config_file}" ]]; then
    for file in "kernel-config-${kernel_version}" "kernel-config-${kernel_version_base}" kernel-config; do
        if [[ -e "${file}" ]]; then
            kernel_config_file="${file}"
            break
        fi
    done
fi

if [[ -z "${output_file}" ]]; then
    output_file="vmlinux-${kernel_version}"
fi

if ! ${force_build} && [[ -e "${output_file}" && "${output_file}" -nt "${kernel_config_file}" ]] && strings -n 20 "${output_file}" | grep -qFw "Linux version ${kernel_version} "; then
    printf 'Output file %s for kernel version %s exists and is newer than the config file %s. Nothing to do.\nUse --force to force rebuilding.\n' "${output_file}" "${kernel_version}" "${kernel_config_file}"
    exit
fi

if [[ -z "${MAKEOPTS}" ]]; then
    if command -v portageq &>/dev/null; then
        MAKEOPTS="$(portageq envvar MAKEOPTS)"
    else
        MAKEOPTS="-j$(nproc) -l$(nproc)"
    fi
fi
cache_dir="$(dirname -- "$0")/cache"
mkdir -p -- "${cache_dir}"

# Download the kernel source code.
kernel_url="https://www.kernel.org/pub/linux/kernel/v${kernel_version%%.*}.x/linux-${kernel_version}.tar.xz"
kernel_signature_url="https://www.kernel.org/pub/linux/kernel/v${kernel_version%%.*}.x/linux-${kernel_version}.tar.sign"
if ! download "${kernel_url}"; then
    die "${E_DOWNLOAD}" "Error: Could not download kernel source code from ${kernel_url}"
fi
# shellcheck disable=SC2154
kernel_file="${downloaded_file}"
if ! download "${kernel_signature_url}"; then
    die "${E_DOWNLOAD}" "Error: Could not download kernel source code signature from ${kernel_signature_url}"
fi
# shellcheck disable=SC2154
kernel_signature_file="${downloaded_file}"

tmpdir="$(mktemp -d -p "${TMPDIR:-/tmp}" build-kernel.XXXXXX)"
mkdir -p -- "${tmpdir}/build"
mkdir -p -- "${tmpdir}/patches"
busybox_setup "${tmpdir}/busybox-bin"

# Uncompress the tar archives, since the signature is valid for the uncompressed file only.
kernel_uncompressed_file="${tmpdir}/linux-${kernel_version}.tar"
xz -cd "${kernel_file}" > "${kernel_uncompressed_file}"
if ! verify_signature --key torvalds@kernel.org --key gregkh@kernel.org "${kernel_uncompressed_file}" "${kernel_signature_file}"; then
    die "${E_DOWNLOAD}" "Error: Could not verify signature on ${kernel_file}"
fi

# Extract the kernel source to the build directory.
tar -C "${tmpdir}/build" -xf "${kernel_uncompressed_file}" --strip-components=1 || die ${E_EXTRACT} 'Error: Could not extract kernel source code.'
rm -f -- "${kernel_uncompressed_file}"

# Copy or extract the patches to the patches directory.
for patch in "${patches[@]}"; do
    case "${patch}" in
        *.patch|*.diff)
            cp "${patch}" "${tmpdir}/patches/" || die "${E_PATCH}" "Error: Could not copy patch ${patch}"
            ;;
        *.tar|*.tar.*|*.tgz|*.tbz|*.tbz2|*.txz)
            tar -C "${tmpdir}/patches/" -xf "${patch}" || die "${E_EXTRACT}" "Error: Could not extract patch archive ${patch}"
            ;;
        *.gz)
            gzip -cd "${patch}" > "${tmpdir}/patches/${patch#.gz}" || die "${E_EXTRACT}" "Error: Could not extract compressed patch ${patch}"
            ;;
        *.bz2)
            bzip2 -cd "${patch}" > "${tmpdir}/patches/${patch#.bz2}" || die "${E_EXTRACT}" "Error: Could not extract compressed patch ${patch}"
            ;;
        *.xz)
            xz -cd "${patch}" > "${tmpdir}/patches/${patch#.xz}" || die "${E_EXTRACT}" "Error: Could not extract compressed patch ${patch}"
            ;;
        *)
            if [[ "$(file --brief --mime-type "${patch}")" == 'text/x-diff' ]]; then
                cp "${patch}" "${tmpdir}/patches/" || die "${E_PATCH}" "Error: Could not copy patch ${patch}"
            fi
            die "${E_CMDLINE}" "Error: ${patch}: Unknown patch file format."
            ;;
    esac
done

# Apply all patches.
shopt -s nullglob
for patch in "${tmpdir}"/patches/*; do
    (cd -- "${tmpdir}/build" && patch -p 1 -i "${patch}" >/dev/null) || die "${E_PATCH}" "Error: Could not patch kernel source code. Failing patch was: ${patch}"
done

# Configure the kernel.
cp -- "${kernel_config_file}" "${tmpdir}/build/.config"
pushd "${tmpdir}/build" || die "${E_INCONSISTENCY}" 'Error: Temporary build directory disappeared.'
new_opts="$(make -s listnewconfig)"
if "${menuconfig}"; then
    make menuconfig
    tmpfile="$(mktemp -p "${TMPDIR:-/tmp}" "kernel-config-${kernel_version}.XXXXXX")"
    cp -a .config "${tmpfile}"
    printf 'Config file was updated. The new config is saved to %s\n' "${tmpfile}" >&2
fi
if [[ -n "${new_opts}" ]]; then
    if [[ ! -t 0 ]]; then
        die ${E_CONFIG} 'Error: New kernel config options available. Please run interactively.'
    else
        make oldconfig
        tmpfile="$(mktemp -p "${TMPDIR:-/tmp}" "kernel-config-${kernel_version}.XXXXXX")"
        cp -a .config "${tmpfile}"
        printf 'Config file was updated. The new config is saved to %s\n' "${tmpfile}" >&2
    fi
fi

# Compile the kernel.
# shellcheck disable=SC2086
make ${MAKEOPTS} vmlinux || die ${E_MAKE} 'Error building kernel'
popd || die "${E_INCONSISTENCY}" 'Error: Working directory disappeared.'
cp -a "${tmpdir}/build/vmlinux" "${output_file}"
