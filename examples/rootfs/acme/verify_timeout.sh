#!/usr/bin/env bash
# Verify deployment of a certificate by waiting for a specific amount of time.
# Blocks until the timeout is reached.
# Limitations:
# - Does not acutally do any verification

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

sleep "${timeout}"
