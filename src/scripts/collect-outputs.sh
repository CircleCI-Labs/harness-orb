#!/bin/bash
set -uo pipefail

if [ ! -f "${ORB_VAL_OUTPUT_FILE}" ]; then
    echo "No output file at ${ORB_VAL_OUTPUT_FILE}; nothing to collect."
    exit 0
fi

if [ ! -s "${ORB_VAL_OUTPUT_FILE}" ]; then
    echo "Output file ${ORB_VAL_OUTPUT_FILE} is empty; the plugin wrote no output variables."
    exit 0
fi

if [ -z "${BASH_ENV:-}" ]; then
    echo "Error: \$BASH_ENV is not set - is this step running in a CircleCI job?" >&2
    exit 1
fi

count=0
while IFS= read -r line || [ -n "${line}" ]; do
    [ -z "${line}" ] && continue
    case "${line}" in
        *=*) ;;
        *)
            echo "Warning: ignoring malformed output line (no '='): ${line}" >&2
            continue
            ;;
    esac

    key="${line%%=*}"
    value="${line#*=}"

    if ! [[ "${key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        echo "Warning: ignoring output line with an invalid variable name: ${key}" >&2
        continue
    fi

    # Export the plugin's own key VERBATIM (no renaming) with the value quoted for BASH_ENV,
    # so a later `source $BASH_ENV` in a native run step reproduces it exactly, special
    # characters included.
    printf 'export %s=%q\n' "${key}" "${value}" >>"${BASH_ENV}"
    count=$((count + 1))
done <"${ORB_VAL_OUTPUT_FILE}"

echo "Exported ${count} plugin output variable(s) into \$BASH_ENV."
