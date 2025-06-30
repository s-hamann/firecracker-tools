#!/usr/bin/env bash
# Deploy a certificate via SFTP. The necessary files are simply copied to the
# target system, which is responsible for moving the files to the correct
# location(s) and restarting consuming services.

if [[ "$#" -ne 3 ]]; then
    cat - <<EOH
Usage: ${0#*/} \$domain \$cert_dir \$key_path
Note: This script should not be called directly.
EOH
fi

domain="$1"
crt_dir="$2"
crt_path="${crt_dir}/${domain}.unbundled.crt"
fullchain_path="${crt_dir}/${domain}.crt"
issuer_path="${crt_dir}/${domain}.issuer.crt"
key_path="$3"
: "${sftp_host:="${domain}"}"
: "${sftp_upload_dir:=upload}"

sftp -b - "${sftp_host}" << EOC
cd "${sftp_upload_dir}"
put -p "${crt_path}" "${domain}.pem"
put -p "${fullchain_path}" "${domain}_fullchain.pem"
put -p "${issuer_path}" "${domain}_chain.pem"
put -p "${key_path}" "${domain}.key"
EOC
