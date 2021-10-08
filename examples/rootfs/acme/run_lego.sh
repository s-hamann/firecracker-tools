#!/usr/bin/env bash

# This script handles issuing, renewal and deployment of X.509 certificates.
# It works with any CA that provides an ACME compatible API and supports DNS
# challenges. This script supports global and per-domain configuration settings
# and pluggable deployment methods via external scripts. On certificate
# renewal, existing TLSA records are taken into account to ensure that DANE
# does not break at any time. Private keys are not stored and therefore
# regenerated on every certificate renewal.

readonly E_CONFIG=1
readonly E_CERTIFICATE=2
readonly E_CSR=254

readonly lego_path="${HOME}/.lego"

die() {
    # usage: die $code $msg
    # Print $msg to stderr and exit with return code $code.

    code="$1"
    shift
    msg="$*"
    printf '%s\n' "${msg}" >&2
    exit "${code}"
}

get_from_config() {
    # usage: get_from_config $file $key $default
    # Read the key named $key from the config file at $file and print the value
    # to stdout. If $key is not set, print $default instead.

    local file="$1"
    local key="$2"
    local default="$3"
    local value
    if [[ ! -r "${file}" ]]; then
        printf 'Error: Could not open %s for reading.\n' "${file}" >&2
        return 1
    fi
    value="$(sed -En -e "s/^\s*${key}:\s+(.*)/\1/p" "${file}")"
    if [[ -z "${value}" ]]; then
        value="${default}"
    fi
    printf '%s' "${value}"
}

read_env() {
    # usage: read_env $file
    # Read the variables from $file and export them into the environment.

    local file="$1"
    if [[ ! -r "${file}" ]]; then
        printf 'Error: Could not open %s for reading.\n' "${file}" >&2
        return 1
    fi
    while read -r line; do
        if ! printf '%s' "${line}" | grep -Eq '^[a-zA-Z0-9_]+='; then
            # Line does not look valid, silently skip it.
            continue
        fi
        var="${line%%=*}"
        val="${line#${var}=}"
        export "${var}=${val}"
    done < "${file}"
}

generate_csr() {
    # usage: generate_csr $key_type $must_staple $domain [$domain [...]]
    # Generate a key pair of the given type and a certificate signing request using that key pair for the given domain(s).
    # The CSR is saved to $tmpdir/$domain.csr and the private key to $tmpdir/keys/$domain.key.

    local key_type="$1"
    local openssl_key_type
    shift
    local must_staple="$1"
    shift
    local domain="$1"
    local san=''
    for d in "$@"; do
        san="${san},DNS:${d}"
    done
    san="${san#,}"

    case "${key_type}" in
        rsa*)
            openssl_key_type="rsa:${key_type#rsa}"
            ;;
        ec*)
            # For ECDSA keys, openssl needs to get the generation parameters from a file.
            # Generate that file, if it does not exist already.
            if [[ ! -e "${tmpdir}/${key_type}" ]]; then
                openssl genpkey -genparam -out "${tmpdir}/${key_type}" -algorithm ec -pkeyopt "ec_paramgen_curve:P-${key_type#ec}"
            fi
            openssl_key_type="ec:${tmpdir}/${key_type}"
            ;;
        *)
            printf 'Error: Invalid key type "%s".\n' "${key_type}" >&2
            return 1
            ;;
    esac

    if [[ "${must_staple}" != 'true' ]]; then
        # No must-staple extension requested. Set the variable to null.
        # If it is not null, the extension is added to the CSR below.
        must_staple=
    fi
    openssl req -newkey "${openssl_key_type}" -nodes -keyout "${tmpdir}/keys/${domain}.key" -out "${tmpdir}/${domain}.csr" -sha256 -subj "/CN=${domain}/" -addext "subjectAltName=${san}" ${must_staple:+-addext 'tlsfeature = status_request'}
}


# shellcheck disable=SC2153
if [[ -n "${CONFIG_DIR}" ]]; then
    if [[ -d "${CONFIG_DIR}" ]]; then
        config_dir="${CONFIG_DIR}"
    else
        die "${E_CONFIG}" "Error: Invalid value for \$CONFIG_DIR: ${CONFIG_DIR}"
    fi
elif [[ -d "${XDG_CONFIG_HOME:-${HOME}/.config}/acme" ]]; then
    config_dir="${XDG_CONFIG_HOME:-${HOME}/.config}/acme"
elif [[ -d '/etc/acme/' ]]; then
    config_dir='/etc/acme/'
else
    # shellcheck disable=SC2016
    die "${E_CONFIG}" 'Error: Configuration directory does not exist. Please create it at $XDG_CONFIG_HOME/acme or /etc/acme or set $CONFIG_DIR to point to a different location.'
fi

if [[ -e "${config_dir}/main.env" ]]; then
    read_env "${config_dir}/main.env"
fi

tmpdir="$(mktemp -d -p "${TMPDIR:-/tmp}" acme-XXXXXX)"
trap 'rm -rf "${tmpdir}"' EXIT INT QUIT TERM
mkdir "${tmpdir}/keys"
chmod 700 "${tmpdir}/keys"
touch "${tmpdir}/tic"

# Renew or issue certificates.
for file in "${config_dir}"/*.conf; do
    if [[ "${file##*/}" == 'main.conf' ]]; then
        continue
    fi
    # Note: The remainder of this loop is done in a subshell to keep the environment clean and to be able to run the sleep commands in parallel.
    # First, a slight delay to keep the workloads from blocking the same resources.
    sleep 0.1
    (
    domain="${file%.conf}"
    domain="${domain##*/}"

    # Read configuration values from the domain-specific config file, falling back to the global config file (where this makes sense).
    # account_email: e-mail address with which to register at the ACME CA
    account_email="$(get_from_config "${file}" account_email)"
    if [[ -z "${account_email}" ]]; then
        account_email="$(get_from_config "${config_dir}/main.conf" account_email)"
    fi
    # acme_url: URL to the CA's API
    acme_url="$(get_from_config "${file}" acme_url)"
    if [[ -z "${acme_url}" ]]; then
        acme_url="$(get_from_config "${config_dir}/main.conf" acme_url)"
    fi
    # dns_provider: DNS provider supported by lego. Setting this disables TLSA handling.
    dns_provider="$(get_from_config "${file}" dns_provider)"
    if [[ -z "${dns_provider}" ]]; then
        dns_provider="$(get_from_config "${config_dir}/main.conf" dns_provider exec)"
    fi
    # min_validity: If existing certificates expire within this many days, they are renewed.
    min_validity="$(get_from_config "${file}" min_validity)"
    if [[ -z "${min_validity}" ]]; then
        min_validity="$(get_from_config "${config_dir}/main.conf" min_validity 30)"
    fi
    # must_staple: If set to 'true' a certificate with the 'must-staple' extension (RFC 6066) is requested.
    must_staple="$(get_from_config "${file}" must_staple)"
    if [[ -z "${must_staple}" ]]; then
        must_staple="$(get_from_config "${config_dir}/main.conf" must_staple false)"
    fi
    # alt_domains: Additional host or domain names to be added to the certificate in the Subject Alternative Name extensions.
    read -ra alt_domains < <(get_from_config "${file}" alt_domains)
    # key_type: Type and length of the key pair. Starts with the algorithm (rsa or ec) followed by the key length, e.g. ec256 or rsa4096.
    key_type="$(get_from_config "${file}" key_type)"
    if [[ -z "${key_type}" ]]; then
        key_type="$(get_from_config "${config_dir}/main.conf" key_type ec256)"
    fi
    # deploy: Deployment method. May be a named deployment method from $config_dir/scripts/deploy_*.sh or an absolute path to a script/executable that handles deployment.
    deploy="$(get_from_config "${file}" deploy)"
    if [[ -z "${deploy}" ]]; then
        deploy="$(get_from_config "${config_dir}/main.conf" deploy sftp)"
    fi
    if [[ "${deploy:0:1}" != '/' ]]; then
        deploy="${config_dir}/scripts/deploy_${deploy}.sh"
    fi
    # verify: Deployment verification method. May be a named verification method from $config_dir/scripts/verify_*.sh or an absolute path to a script/executable that verifies certificate deployment.
    verify="$(get_from_config "${file}" verify)"
    if [[ -z "${verify}" ]]; then
        verify="$(get_from_config "${config_dir}/main.conf" verify connect)"
    fi
    if [[ "${verify:0:1}" != '/' ]]; then
        verify="${config_dir}/scripts/verify_${verify}.sh"
    fi
    # verify_timeout: Timeout for certificate deployment verification in seconds.
    verify_timeout="$(get_from_config "${file}" verify_timeout)"
    if [[ -z "${verify_timeout}" ]]; then
        verify_timeout="$(get_from_config "${config_dir}/main.conf" verify_timeout 300)"
    fi
    # lego_args: Custom raw command line argument to be passed to lego.
    read -ra lego_args < <(get_from_config "${file}" lego_args)
    if [[ -z "${lego_args[*]}" ]]; then
        read -ra lego_args < <(get_from_config "${config_dir}/main.conf" lego_args)
    fi

    # Read environment variables from the domain-specific file.
    if [[ -e "${config_dir}/${domain}.env" ]]; then
        read_env "${config_dir}/${domain}.env"
    fi

    # Set default DNS update script, if nothing else is configured.
    if [[ "${dns_provider}" == 'exec' && -z "${EXEC_PATH}" ]]; then
        export EXEC_PATH="${config_dir}/scripts/update-dns.sh"
    fi

    # Construct the lego command line arguments.
    crt_path="${lego_path}/certificates/${domain}.crt"
    lego_args+=('--path' "${lego_path}" '--email' "${account_email}" '--accept-tos' '--dns' "${dns_provider}")

    if [[ -n "${acme_url}" ]]; then
        lego_args+=('--server' "${acme_url}")
    fi
    if [[ ! -e "${crt_path}" ]]; then
        # There is no certificate for $domain. Generate a CSR.
        generate_csr "${key_type}" "${must_staple}" "${domain}" "${alt_domains[@]}" || die "${E_CSR}" "Error: Could not generate CSR for ${domain}."
        lego_args+=('--csr' "${tmpdir}/${domain}.csr" run)
    else
        if ! openssl x509 -checkend "$((min_validity * 24 * 60 * 60))" -noout -in "${crt_path}" >/dev/null; then
            # Certificate will expire within the next $min_validity days. Generate a CSR.
            generate_csr "${key_type}" "${must_staple}" "${domain}" "${alt_domains[@]}" || die "${E_CSR}" "Error: Could not generate CSR for ${domain}."
            lego_args+=('--csr' "${tmpdir}/${domain}.csr" renew '--days' "${min_validity}")
        else
            # Certificate is valid for (at least) another $min_validity days.
            # Exit the subshell, i.e. continue with the next domain.
            exit 0
        fi
    fi

    # Run lego.
    lego "${lego_args[@]}"

    if [[ "${crt_path}" -nt "${tmpdir}/tic" ]]; then
        # We have a new certificate.

        # Make an unbundled variant with only the first certificate from the bundle file.
        openssl x509 -in "${crt_path}" -out "${crt_path%.crt}.unbundled.crt"

        # Check for TLSA records.
        if [[ "${dns_provider}" == 'exec' ]]; then
            readarray -t tlsa_records < <("${EXEC_PATH}" get-dane-records "${domain}")
            max_ttl=0
            if [[ "${#tlsa_records[@]}" -gt 0 ]]; then
                for record in "${tlsa_records[@]}"; do
                    ttl="$(cut -d' ' -f2 <<< "${record}")"
                    max_ttl="$(( ttl > max_ttl ? ttl : max_ttl ))"
                    "${EXEC_PATH}" dane-present "${record%% *}" "${crt_path}"
                done
            fi
            sleep "${max_ttl}"
        fi

        # Deploy the certificate and key.
        "${deploy}" "${domain}" "${crt_path%/*}" "${tmpdir}/keys/${domain}.key" || die 1 "Error: Could not deploy new certificate to ${domain}."

        if [[ "${#tlsa_records[@]}" -gt 0 ]]; then
            # Wait until/verify that the new certificate is in use.
            "${verify}" "${crt_path}" "${verify_timeout}" "$(printf '%s;' "${tlsa_records[@]}")" || die 1 "Error: Could not verify deployment of new certificate to ${domain}."
            # Clean up existing TLSA records.
            for record in "${tlsa_records[@]}"; do
                "${EXEC_PATH}" dane-cleanup "${record%% *}" "${crt_path}"
            done
        fi
    fi
    ) &
done

# Wait for child processes to exit.
wait -n
r=$?
while [[ "${r}" -ne 127 ]]; do
    if [[ "${r}" -ne 0 ]]; then
        (( errors++ ))
    fi
    wait -n
    r=$?
done

exit "$(( errors > 0 ? E_CERTIFICATE : 0 ))"
