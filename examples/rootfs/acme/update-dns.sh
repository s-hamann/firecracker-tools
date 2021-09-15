#!/bin/sh
# shellcheck disable=SC2039

readonly desec_dns=/usr/local/bin/desec-dns.py
readonly token_file=/etc/acme/desec_token

split_domain() {
    # usage: split_domain $fqdn
    # Split the given FQDN into the domain and the subname part.
    # Set the global variable $domain and $subname accordingly.
    local fqdn="${1%.}"
    unset subname
    # Split the FQDN in the (managed) domain and the subname.
    for domain in $("${desec_dns}" --token-file "${token_file}" list-domains); do
        if [ "${fqdn}" != "${fqdn%${domain}}" ]; then
            subname="${fqdn%.${domain}}"
            break
        fi
    done

    if [ -z "${subname}" ]; then
        unset domain
        printf 'Error: Can not manage %s with this token.\n' "${fqdn}" >&2
        return 2
    fi
}

set_response() {
    # usage: set_response $fqdn $value
    # Set a DNS TXT record at $fqdn to $value.
    local fqdn="$1"
    local value="$2"
    local subname domain
    split_domain "${fqdn}" || return $?
    "${desec_dns}" --token-file "${token_file}" update-record "${domain}" --type TXT --subname "${subname}" --records "${value}"
}

remove_response() {
    # usage: remove_response $fqdn $value
    # Remove the DNS TXT record $value from $fqdn (if any).
    local fqdn="$1"
    local value="$2"
    local subname domain
    split_domain "${fqdn}" || return $?
    "${desec_dns}" --token-file "${token_file}" delete-record "${domain}" --type TXT --subname "${subname}" --records "${value}"
}

get_dane_records() {
    # usage: get_dane_records $fqdn
    # Print the TLSA records that are effective for the given $fqdn, e.g. _25._tcp.$fqdn.
    local fqdn="$1"
    local subname domain
    split_domain "${fqdn}" || return $?
    "${desec_dns}" --token-file "${token_file}" get-records "${domain}" --type TLSA | grep -E "^_[0-9]+\._(tcp|udp|sctp)\.${fqdn%.}\. "
}

set_dane() {
    # usage: set_dane [add|exact] $fqdn $crt_path
    # Set a TLSA record for the certificate at $crt_path to $fqdn.
    # If the first parameter is 'add', the record is added to the existing records (if any).
    # If the first parameter is 'exact', the record replaces any existing records.
    # Usage, selector and hash type are taken from environment variable.
    # If they are not set, the last existing record or, failing that, default values are taken.
    local action
    case "$1" in
        add) action='add-tlsa' ;;
        exact) action='set-tlsa' ;;
        *) printf 'Invalid action %s\n' "$1" >&2; return 1 ;;
    esac
    local fqdn="$2"
    local crt_path="$3"
    local subname domain port protocol
    split_domain "${fqdn}" || return $?
    local usage="${TLSA_USAGE}"
    local selector="${TLSA_SELECTOR}"
    local hash_type="${TLSA_HASH_TYPE}"
    local ttl="${TLSA_TTL}"
    if [ -z "${usage}" ] || [ -z "${selector}" ] || [ -z "${hash_type}" ] || [ -z "${ttl}" ]; then
        local tlsa_record
        tlsa_record="$("${desec_dns}" --token-file="${token_file}" get-records "${domain}" --type TLSA --subname "${subname}" | tail -n 1)"
        if [ -n "${tlsa_record}" ]; then
            usage="${usage:-$(echo "${tlsa_record}" | cut -d' ' -f 5)}"
            selector="${selector:-$(echo "${tlsa_record}" | cut -d' ' -f 6)}"
            hash_type="${hash_type:-$(echo "${tlsa_record}" | cut -d' ' -f 7)}"
            ttl="${ttl:-$(echo "${tlsa_record}" | cut -d' ' -f 2)}"
        else
            usage="${usage:-3}"
            selector="${selector:-0}"
            hash_type="${hash_type:-1}"
            ttl="${ttl:-3600}"
        fi
    fi
    port="${subname#_}"
    port="${port%%.*}"
    protocol="${subname#_${port}._}"
    protocol="${protocol%%.*}"
    "${desec_dns}" --token-file="${token_file}" "${action}" "${domain}" --subname "${subname#_${port}._${protocol}.}" --certificate "${crt_path}" --usage "${usage}" --selector "${selector}" --match-type "${hash_type}" --ports "${port}" --protocol "${protocol}" --ttl "${ttl}"
}

action="$1"
shift
case "${action}" in
    present)
        [ "$1"  = '--' ] && shift
        if [ "$#" -ne 2 ]; then
            printf 'Usage: %s %s <fqdn> <value>\n' "${0##*/}" "${action}" >&2
            exit 1
        fi
        set_response "$@" || exit $?
        ;;
    cleanup)
        [ "$1"  = '--' ] && shift
        if [ "$#" -ne 2 ]; then
            printf 'Usage: %s %s <fqdn> <value>\n' "${0##*/}" "${action}" >&2
            exit 1
        fi
        remove_response "$@" || exit $?
        ;;
    get-dane-records)
        [ "$1"  = '--' ] && shift
        if [ "$#" -ne 1 ]; then
            printf 'Usage: %s %s <fqdn>\n' "${0##*/}" "${action}" >&2
            exit 1
        fi
        get_dane_records "$@" || exit $?
        ;;
    dane-present)
        [ "$1"  = '--' ] && shift
        if [ "$#" -ne 2 ]; then
            printf 'Usage: %s %s <fqdn> <certificate>\n' "${0##*/}" "${action}" >&2
            exit 1
        fi
        set_dane add "$@" || exit $?
        ;;
    dane-cleanup)
        [ "$1" = '--' ] && shift
        if [ "$#" -ne 2 ]; then
            printf 'Usage: %s %s <fqdn> <certificate>\n' "${0##*/}" "${action}" >&2
            exit 1
        fi
        set_dane exact "$@" || exit $?
        ;;
    *)
        printf 'Error: Invalid action %s.\n' "${action}" >&2
        exit 1
        ;;
esac
