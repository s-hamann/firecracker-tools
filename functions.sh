#!/bin/bash

# shellcheck disable=SC2034
readonly default_cache_dir="${XDG_CACHE_HOME:-${HOME}/.cache}/firecracker"

readonly LOG_ERROR=0
readonly LOG_WARN=1
readonly LOG_INFO=2
readonly LOG_DEBUG=3
declare -A quiet_at

# Default log level.
log_level="${LOG_INFO}"

function error() {
    # usage: error $message [...]
    # Prints message to stderr if the global log level allows it.
    if [[ "${log_level}" -ge "${LOG_ERROR}" ]]; then
        printf "%s\n" "$*" >&2
    fi
}

function warn() {
    # usage: warn $message [...]
    # Prints message to stderr if the global log level allows it.
    if [[ "${log_level}" -ge "${LOG_WARN}" ]]; then
        printf "%s\n" "$*" >&2
    fi
}

function info() {
    # usage: info $message [...]
    # Prints message to stderr if the global log level allows it.
    if [[ "${log_level}" -ge "${LOG_INFO}" ]]; then
        printf "%s\n" "$*" >&2
    fi
}

function debug() {
    # usage: debug $message [...]
    # Prints message to stderr if the global log level allows it.
    if [[ "${log_level}" -ge "${LOG_DEBUG}" ]]; then
        printf "%s\n" "$*" >&2
    fi
}

function die() {
    # usage: die $code $message [...]
    # Prints $message to stderr and exits with the given exit $code.
    local code="$1"
    shift
    error "$@"
    exit "${code}"
}

function log_level_setup() {
    # usage: log_level_setup
    # Sets up $quiet_at as an associative array with a key for each log level
    # and values that are either 'true' (if messages of this log level should
    # be suppressed) or empty (otherwise).
    for level in DEBUG INFO WARN ERROR; do
        local level_name="LOG_${level}"
        quiet_at["${level}"]="$([[ "${log_level}" -le "${!level_name}" ]] && echo 'true')"
    done
}

function busybox_setup() {
    # usage: busybox_setup $dir
    # If BusyBox is installed, creates $dir, installs symlinks to all applets in
    # $dir and appends $dir to $PATH.
    # This means that regular system tools are preferred over BusyBox
    # implementations, but BusyBox provides a fallback for missing tools.
    local busybox_bindir="$1"
    if ! command -v busybox >&/dev/null; then
        # BusyBox not found.
        return 1
    fi
    debug "Setting up busybox to provide fallback tool implementations."
    mkdir -p -- "${busybox_bindir}"
    busybox --install -s "${busybox_bindir}"
    export PATH="${PATH}:${busybox_bindir}"
}

function download() {
    # usage: download $url
    # Downloads the given $url into $cache_dir and sets the global variable
    # $downloaded_file to the full (absolute or relative) path to the file in
    # $cache_dir.
    # If the file is already present in $cache_dir, it is only downloaded if
    # $url is more recent than the local file.
    # If the download fails, returns 1 and sets $downloaded_file to the empty
    # string.
    local url="$1"
    # shellcheck disable=SC2154
    downloaded_file="${cache_dir}/${url##*/}"
    # Download $url into $cache_dir.
    if [[ -n "${quiet_at[WARN]}" ]]; then
        # Only display wget's (non-verbose) output if there was an error.
        # shellcheck disable=SC2015
        (cd "${cache_dir}" && { wget_log="$(wget --no-verbose --timestamping "${url}" 2>&1)" || { r="$?"; error "${wget_log}"; exit "${r}"; }; })
        r="$?"
    else
        # Just let wget print its (verbose) output to stderr.
        (cd "${cache_dir}" && wget --timestamping "${url}")
        r="$?"
    fi
    if [[ "${r}" -gt 0 ]]; then
    # shellcheck disable=SC2034
        downloaded_file=
        error "Error: Could not download ${url}"
        return 1
    fi
}

function verify_signature() {
    # usage verify_signature [--key $keyid|$email] $signed_file [$signature_file]
    # Verifies the PGP signature on $signed_file. If $signature_file is given,
    # it is interpreted as a detached signature. If it is omitted, $signed_file
    # needs to contains it's signature.
    # If --key is given, the key with the ID $keyid is obtained from a key
    # server or the key for the identity $email is obtained via the kws
    # protocol. --key can be used multiple times to specify multiple keys.
    # The signature is verified against the given keys, or, if none are given,
    # against the default keyring of the user that happens to run this code.
    signature_keys=()
    while [[ "$1" == '--key' ]]; do
        local signature_keys+=( "$2" )
        shift
        shift
    done
    local signed_file="$1"
    local signature_file="$2"
    if [[ -z "${signature_file}" ]]; then
        debug "Checking PGP signature of ${signed_file}."
    else
        debug "Checking PGP signature of ${signed_file} using detached signature ${signature_file}."
    fi
    (
    gpg=gpg
    command -v gpg2 &>/dev/null && gpg=gpg2
    if [[ "${#signature_keys[@]}" -gt 0 ]]; then
        # Import the signature keys into a temporary keyring.
        keyring="$(mktemp -d -p "${TMPDIR:-/tmp}" gpg.XXXXXX)"
        trap 'rm -rf -- "${keyring}"' EXIT INT TERM QUIT
        for key in "${signature_keys[@]}"; do
            if [[ "${key}" = *@* ]]; then
                # $key seems to be an email address, use wkd to get it.
                ([[ -n "${quiet_at[WARN]}" ]] && exec 1>/dev/null; "${gpg}" ${quiet_at[INFO]:+--quiet} --homedir="${keyring}" --auto-key-locate wkd --locate-keys "${key}") || die 1 "Error: Could not import public PGP key for ${key}"
            else
                # $key seems to be a key ID, use the Ubuntu key server to get it.
                echo 'keyserver hkps://keyserver.ubuntu.com' > "${keyring}/dirmngr.conf"
                "${gpg}" ${quiet_at[INFO]:+--quiet} --homedir="${keyring}" --recv-key "${key}" || die 1 "Error: Could not import public PGP key ${key}"
            fi
        done
    fi
    # Verify signature.
    gpg_status="$([[ -n "${quiet_at[WARN]}" ]] && exec 2>/dev/null; exec 4>&1; "${gpg}" --quiet ${keyring:+--homedir="${keyring}"} ${keyring:+--trust-model=always} --status-fd=3 --verify ${signature_file:+"${signature_file}"} "${signed_file}" 3>&1 1>&4)" 4>&1
    # Check that gpg found a valid signature that is not untrusted.
    if grep --quiet -Fw VALIDSIG <<< "${gpg_status}" && \
        ! grep --quiet -Ew 'TRUST_(UNDEFINED|NEVER|MARGINAL)' <<< "${gpg_status}" ; then
        exit 0
    else
        exit 1
    fi
    ) || return 1
}
