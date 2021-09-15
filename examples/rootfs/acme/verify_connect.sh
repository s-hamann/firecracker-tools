#!/usr/bin/env bash
# Verify deployment of a certificate by connecting to all services with
# published TLSA records and checking that they present the target certificate.
# Blocks until all services do or until a timeout is reached.
# Limitations:
# - May not work reliably for all services
# - STARTTLS works only for certain well-known ports and is not configurable

if [[ "$#" -ne 3 ]]; then
    cat - <<EOH
Usage: ${0#*/} \$cert_path \$timeout \$tlsa-records
Note: This script should not be called directly.
EOH
    exit 1
fi

crt_path="$1"
timeout="$2"
IFS=';' read -a tlsa_records -r <<< "$3"

get_cert_serial() {
    # usage: get_cert_serial [$path|$fqdn]
    # Prints the serial number of the X.509 certificate at $path (an absolute
    # local path) or returned by the service listening at $fqdn, where $fqdn is
    # the name of a TLSA record, e.g. _25._tcp.example.com. STARTTLS is used
    # for some well-known ports.
    if [[ "${1:0:1}" == / ]]; then
        # Argument is an absolute path.
        cat "$1"
    else
        local host port protocol
        local args=()
        port="${1#_}"
        port="${port%%.*}"
        protocol="${1#_${port}._}"
        protocol="${protocol%%.*}"
        host="${1#_${port}._${protocol}.}"
        host="${host%.}"
        if [[ "${protocol}" == 'udp' ]]; then
            args+=( -dtls1 )
        fi
        case "${port}" in
            21) args+=( -starttls ftp ) ;;
            24) args+=( -starttls lmtp ) ;;
            25) args+=( -starttls smtp ) ;;
            110) args+=( -starttls pop3 ) ;;
            119) args+=( -starttls nntp ) ;;
            143) args+=( -starttls imap ) ;;
            389) args+=( -starttls ldap ) ;;
            433) args+=( -starttls nntp ) ;;
            587) args+=( -starttls smtp ) ;;
            3306) args+=( -starttls mysql ) ;;
            4190) args+=( -starttls sieve ) ;;
            5222) args+=( -starttls xmpp ) ;;
            5269) args+=( -starttls xmpp-server ) ;;
            5432) args+=( -starttls postgres ) ;;
            6667) args+=( -starttls irc ) ;;
        esac
        openssl s_client -connect "${host}:${port}"
    fi | openssl x509 -noout -serial | cut -d= -f2
}

new_serial="$(get_cert_serial "${crt_path}")"

# We check that all ports that have a TLSA record return the new certificate (by comparing the serial number).
time=0
while (( (time+=15) < timeout )); do
    deployed=0
    for record in "${tlsa_records[@]}"; do
        if [[ "$(get_cert_serial "${record%% *}")" == "${new_serial}" ]]; then
            (( deployed++ ))
        fi
    done
    if [[ "${deployed}" -eq "${#tlsa_records[@]}" ]]; then
        # All services use the new certificate now.
        exit 0
    fi
    sleep 15
done
# The timeout was reached, i.e. not all services use the new certificate.
exit 1
