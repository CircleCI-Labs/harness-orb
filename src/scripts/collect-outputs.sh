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

# Shell/interpreter-control variable names this script must never export, even though they
# pass the identifier-syntax check below. The plugin container has write access to the
# bind-mounted workspace (the same one later native steps run from), so a hostile or
# supply-chain-compromised plugin image could otherwise plant a binary in the workspace and
# simply emit an output line named e.g. PATH=./evilbin:/usr/bin:/bin or
# GIT_SSH_COMMAND=/tmp/evil.sh - both of which we then export into $BASH_ENV, giving it code
# execution (or credential-bearing-git-command execution) in every later native step that
# sources $BASH_ENV, with that job's secrets. This list is deliberately conservative (block
# known-dangerous names) rather than an allowlist, to keep VERBATIM passthrough for everything
# else per this orb's design.
#
# Kept as a superset of the identical RESERVED_SHELL_VAR_NAMES array in the sibling
# bitbucket-pipes-orb/buildkite-orb map-env.sh/collect-outputs.sh scripts (SHELL,
# DYLD_INSERT_LIBRARIES, DYLD_LIBRARY_PATH, NODE_OPTIONS, GIT_SSH_COMMAND, PERL5LIB,
# PYTHONPATH, RUBYOPT, CDPATH added here to reach parity - see the release-readiness audit's
# "harness's denylist is a strict subset of its siblings'" finding), plus this script's own
# original HOME/TMPDIR entries, which the siblings don't carry but which are worth keeping.
RESERVED_SHELL_VAR_NAMES=(
    PATH BASH_ENV IFS ENV SHELLOPTS PS4 LD_PRELOAD LD_LIBRARY_PATH HOME TMPDIR
    SHELL DYLD_INSERT_LIBRARIES DYLD_LIBRARY_PATH NODE_OPTIONS GIT_SSH_COMMAND
    PERL5LIB PYTHONPATH RUBYOPT CDPATH
)
is_reserved_shell_var_name() {
    local candidate="$1" reserved
    for reserved in "${RESERVED_SHELL_VAR_NAMES[@]}"; do
        if [ "${candidate}" = "${reserved}" ]; then
            return 0
        fi
    done
    return 1
}

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

    if is_reserved_shell_var_name "${key}"; then
        echo "Warning: ignoring output line that would overwrite the reserved variable '${key}' - refusing to let a plugin's output hijack a shell/interpreter control variable for later native steps: ${line}" >&2
        continue
    fi

    # Export the plugin's own key VERBATIM (no renaming) with the value quoted for BASH_ENV,
    # so a later `source $BASH_ENV` in a native run step reproduces it exactly, special
    # characters included.
    printf 'export %s=%q\n' "${key}" "${value}" >> "${BASH_ENV}"
    count=$((count + 1))
done < "${ORB_VAL_OUTPUT_FILE}"

echo "Exported ${count} plugin output variable(s) into \$BASH_ENV."
