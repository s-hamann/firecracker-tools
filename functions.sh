#!/bin/bash

function die() {
    # usage: die $code $message [...]
    # Prints $message to stderr and exits with the given exit $code.
    local code="$1"
    shift
    printf "%s\n" "$*" >&2
    exit "${code}"
}

function busybox_setup() {
    # usage: busybox_setup $dir
    # If BusyBox is installed, creates $dir, install symlinks to all applets in
    # $dir and appends $dir to $PATH.
    # This means that regular system tools are prefered over BusyBox
    # implementations, but BusyBox provides a fallback for missing tools.
    local busybox_bindir="$1"
    if ! command -v busybox >&/dev/null; then
        # BusyBox not found.
        return 1
    fi
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
    if ! (cd "${cache_dir}" && wget --timestamping "${url}"); then
    # shellcheck disable=SC2034
        downloaded_file=
        printf 'Error: Could not download %s\n' "${url}" >&2
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
                "${gpg}" --homedir="${keyring}" --auto-key-locate wkd --locate-keys "${key}" || { printf 'Error: Could not import public PGP key for %s\n' "${key}" >&2; exit 1; }
            else
                # $key seems to be a key ID, use the default key server to get it.
                "${gpg}" --homedir="${keyring}" --recv-key "${key}" || { printf 'Error: Could not import public PGP key %s\n' "${key}" >&2; exit 1; }
            fi
        done
    fi
    # Verify signature.
    gpg_status="$(exec 4>&1; "${gpg}" --quiet ${keyring:+--homedir="${keyring}"} ${keyring:+--trust-model=always} --status-fd=3 --verify ${signature_file:+"${signature_file}"} "${signed_file}" 3>&1 1>&4)" 4>&1
    # Check that gpg found a valid signature that is not untrusted.
    if grep --quiet -Fw VALIDSIG <<< "${gpg_status}" && \
        ! grep --quiet -Ew 'TRUST_(UNDEFINED|NEVER|MARGINAL)' <<< "${gpg_status}" ; then
        exit 0
    else
        exit 1
    fi
    ) || return 1
}
