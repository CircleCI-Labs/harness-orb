#!/bin/bash
set -euo pipefail

if [ -z "${ORB_VAL_OUTPUT_FILE}" ]; then
    echo "Error: output-file must not be empty." >&2
    exit 1
fi

output_dir="$(dirname "${ORB_VAL_OUTPUT_FILE}")"
mkdir -p "${output_dir}"

# Truncate/create. A fresh empty file every run so stale outputs from a previous
# invocation in the same job can never leak into this one.
: > "${ORB_VAL_OUTPUT_FILE}"

echo "Created plugin output file at ${ORB_VAL_OUTPUT_FILE}"
