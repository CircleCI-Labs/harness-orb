#!/bin/bash
set -euo pipefail

# Native-primary-container counterpart to map-env.sh. Same PLUGIN_<KEY> settings-parsing rules and
# the same verified CIRCLE_*->DRONE_*/HARNESS_* subset, but a DIFFERENT SINK: the original
# map-env.sh writes a `docker --env-file` for `run-plugin.sh`'s `docker run --env-file` to consume.
# In this model there is no `docker run` -- the plugin's entrypoint runs as an ordinary `run:`
# step in the job's own primary container -- so map-env.sh does NOT drop in unmodified here (this
# was checked, not assumed: see the README's "Does map-env drop in unmodified?" section). Instead
# this script exports each derived variable straight into $BASH_ENV, which every later `run:` step
# (including run-plugin-native.sh) sources automatically at start, exactly the mechanism
# create-output-file.sh/collect-outputs.sh already use unmodified in both the docker-run and
# native paths.
#
# Also different: DRONE_WORKSPACE/HARNESS_WORKSPACE and DRONE_OUTPUT/HARNESS_OUTPUT point at the
# REAL host-side paths directly (ORB_VAL_WORKSPACE_PATH/ORB_VAL_OUTPUT_FILE) rather than a
# container-side bind-mount path -- there is no bind mount, and no host/container path duality, to
# remap in this model.

export_kv() {
    local key="$1" value="$2"
    local escaped="${value//\'/\'\\\'\'}"
    echo "export ${key}='${escaped}'" >> "${BASH_ENV}"
}

if [ -z "${BASH_ENV:-}" ]; then
    echo "Error: \$BASH_ENV is not set - is this step running in a CircleCI job?" >&2
    exit 1
fi

subst_mode="none"
if command -v circleci > /dev/null 2>&1; then
    subst_mode="circleci"
elif command -v envsubst > /dev/null 2>&1; then
    subst_mode="envsubst"
    echo "Warning: 'circleci' CLI not found; falling back to plain envsubst for settings substitution." >&2
else
    echo "Warning: neither 'circleci' nor 'envsubst' found; settings passed through with no \$VAR substitution." >&2
fi

subst_value() {
    case "${subst_mode}" in
        circleci) printf '%s' "$1" | circleci env subst ;;
        envsubst) printf '%s' "$1" | envsubst ;;
        *) printf '%s' "$1" ;;
    esac
}

json_tool_warned=0
plugin_count=0
while IFS= read -r line || [ -n "${line}" ]; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"

    [ -z "${trimmed}" ] && continue
    case "${trimmed}" in
        '#'*) continue ;;
    esac

    case "${trimmed}" in
        *': '*)
            key="${trimmed%%: *}"
            raw_value="${trimmed#*: }"
            ;;
        *)
            echo "Error: settings line is not 'key: value': ${trimmed}" >&2
            exit 1
            ;;
    esac

    [ -z "${key}" ] && {
        echo "Error: empty key in settings line: ${trimmed}" >&2
        exit 1
    }

    value="$(subst_value "${raw_value}")"

    case "${value}" in
        '{'* | '['*)
            if command -v python3 > /dev/null 2>&1; then
                if ! printf '%s' "${value}" | python3 -c 'import json, sys; json.loads(sys.stdin.read())' > /dev/null 2>&1; then
                    echo "Error: settings.${key} looks like JSON (starts with '{' or '[') but failed to parse as JSON: ${value}" >&2
                    exit 1
                fi
            elif [ "${json_tool_warned}" -eq 0 ]; then
                echo "Warning: 'python3' not found; skipping JSON validation of settings that look like JSON (e.g. settings.${key})." >&2
                json_tool_warned=1
            fi
            ;;
    esac

    env_key="PLUGIN_$(printf '%s' "${key}" | tr '[:lower:]' '[:upper:]' | tr -- '-.' '__')"

    if ! [[ "${env_key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        echo "Error: settings key '${key}' does not produce a valid env var name (got '${env_key}') - check for spaces or other unusual characters in this settings line: ${trimmed}" >&2
        exit 1
    fi

    export_kv "${env_key}" "${value}"
    plugin_count=$((plugin_count + 1))
done < <(printf '%s\n' "${ORB_VAL_SETTINGS}")

echo "Exported ${plugin_count} PLUGIN_* var(s) derived from settings into \$BASH_ENV."

# CIRCLE_* -> DRONE_*/HARNESS_* -- identical subset to map-env.sh (see that script's own comment
# for the full list of what's deliberately NOT shimmed). WORKSPACE/OUTPUT point at the real,
# unremapped host paths -- see this script's header comment.
if [ -n "${CIRCLE_PROJECT_USERNAME:-}" ]; then
    export_kv DRONE_REPO_OWNER "${CIRCLE_PROJECT_USERNAME}"
fi
if [ -n "${CIRCLE_PROJECT_REPONAME:-}" ]; then
    export_kv DRONE_REPO_NAME "${CIRCLE_PROJECT_REPONAME}"
fi
if [ -n "${CIRCLE_PROJECT_USERNAME:-}" ] && [ -n "${CIRCLE_PROJECT_REPONAME:-}" ]; then
    export_kv DRONE_REPO "${CIRCLE_PROJECT_USERNAME}/${CIRCLE_PROJECT_REPONAME}"
fi
if [ -n "${CIRCLE_SHA1:-}" ]; then
    export_kv DRONE_COMMIT "${CIRCLE_SHA1}"
fi
if [ -n "${CIRCLE_BRANCH:-}" ]; then
    export_kv DRONE_COMMIT_BRANCH "${CIRCLE_BRANCH}"
fi
if [ -n "${CIRCLE_BUILD_NUM:-}" ]; then
    export_kv DRONE_BUILD_NUMBER "${CIRCLE_BUILD_NUM}"
fi

export_kv DRONE_WORKSPACE "${ORB_VAL_WORKSPACE_PATH}"
export_kv HARNESS_WORKSPACE "${ORB_VAL_WORKSPACE_PATH}"
export_kv DRONE_OUTPUT "${ORB_VAL_OUTPUT_FILE}"
export_kv HARNESS_OUTPUT "${ORB_VAL_OUTPUT_FILE}"
export_kv HARNESS_OUTPUT_FILE "${ORB_VAL_OUTPUT_FILE}"

echo "Done mapping settings and CIRCLE_* context into \$BASH_ENV (native primary-container mode)."
