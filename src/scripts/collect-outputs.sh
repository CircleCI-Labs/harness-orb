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

    # Reject shell/interpreter-control variable names outright, even though they pass the
    # syntax check above. The plugin container has write access to the bind-mounted workspace
    # (the same one later native steps run from), so a hostile or supply-chain-compromised
    # plugin image could otherwise plant a binary in the workspace and simply emit an output
    # line named e.g. PATH=./evilbin:/usr/bin:/bin or BASH_ENV=<a script it wrote> - both of
    # which we then export into $BASH_ENV, giving it code execution in every later native step
    # that sources $BASH_ENV, with that job's secrets. This list is deliberately conservative
    # (block known-dangerous names) rather than an allowlist, to keep VERBATIM passthrough for
    # everything else per this orb's design.
    case "${key}" in
        PATH | BASH_ENV | IFS | ENV | SHELLOPTS | PS4 | LD_PRELOAD | LD_LIBRARY_PATH | HOME | TMPDIR)
            echo "Warning: ignoring output line that would overwrite the reserved variable '${key}' - refusing to let a plugin's output hijack a shell/interpreter control variable for later native steps: ${line}" >&2
            continue
            ;;
    esac

    # Export the plugin's own key VERBATIM (no renaming) with the value quoted for BASH_ENV,
    # so a later `source $BASH_ENV` in a native run step reproduces it exactly, special
    # characters included.
    printf 'export %s=%q\n' "${key}" "${value}" >>"${BASH_ENV}"
    count=$((count + 1))
done <"${ORB_VAL_OUTPUT_FILE}"

echo "Exported ${count} plugin output variable(s) into \$BASH_ENV."
