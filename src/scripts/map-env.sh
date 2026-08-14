#!/bin/bash
set -euo pipefail

if [ -z "${ORB_VAL_ENV_FILE}" ]; then
    echo "Error: env-file must not be empty." >&2
    exit 1
fi

mkdir -p "$(dirname "${ORB_VAL_ENV_FILE}")"
: >"${ORB_VAL_ENV_FILE}"

# Decide ONCE, up front, how (if at all) to resolve $VAR/${VAR} references against the job's
# real env vars (context/project env vars), so a caller can write e.g. `webhook: $SLACK_WEBHOOK`
# in orb config without the secret ever appearing in config. `circleci env subst` is bundled
# into every CircleCI job regardless of image; fall back to a plain envsubst if it is somehow
# missing (e.g. this script run standalone for local testing), and warn loudly rather than
# silently skipping substitution if neither is available. Substitution itself is applied further
# down, per-value, AFTER each settings line has already been split into key/value - never over
# the whole settings block - so that a newline embedded in a substituted secret's value cannot
# turn into an unintended extra `key: value` settings line (which would otherwise let the
# *content* of a secret inject arbitrary additional PLUGIN_* variables, or abort the step with a
# confusing parse error).
subst_mode="none"
if command -v circleci >/dev/null 2>&1; then
    subst_mode="circleci"
elif command -v envsubst >/dev/null 2>&1; then
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

# Warn about non-JSON-parseable JSON-looking values at most once per invocation, so a caller
# without python3 available isn't spammed once per settings line.
json_tool_warned=0

plugin_count=0
while IFS= read -r line || [ -n "${line}" ]; do
    # Trim leading/trailing whitespace.
    trimmed="${line#"${line%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"

    [ -z "${trimmed}" ] && continue
    case "${trimmed}" in
        '#'*) continue ;;
    esac

    # Split on the FIRST ": " (colon-space), YAML-flow-scalar style, so values that
    # themselves contain a bare colon (URLs, times, JSON) are preserved intact. This split
    # happens on the RAW, unsubstituted line - substitution is applied only to the extracted
    # value below, never to the whole settings block (see the comment above subst_value).
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

    # If the (already-substituted) value looks like it's meant to be JSON - the wire format
    # this orb uses for Harness's nested-map settings (settings.with -> PLUGIN_WITH) - validate
    # it server-side and fail with a clear, settings-line-specific message instead of letting a
    # malformed string reach the plugin's own JSON-unmarshal call, which would otherwise surface
    # as an opaque error deep inside the vendor's binary with no hint the real mistake was here.
    case "${value}" in
        '{'* | '['*)
            if command -v python3 >/dev/null 2>&1; then
                if ! printf '%s' "${value}" | python3 -c 'import json, sys; json.loads(sys.stdin.read())' >/dev/null 2>&1; then
                    echo "Error: settings.${key} looks like JSON (starts with '{' or '[') but failed to parse as JSON: ${value}" >&2
                    exit 1
                fi
            elif [ "${json_tool_warned}" -eq 0 ]; then
                echo "Warning: 'python3' not found; skipping JSON validation of settings that look like JSON (e.g. settings.${key})." >&2
                json_tool_warned=1
            fi
            ;;
    esac

    # PLUGIN_<KEY>: uppercase, kebab-case/dotted keys normalized to underscores - this is
    # the verified Harness case rule (settings.repo_url -> PLUGIN_REPO_URL, etc.), extended
    # to kebab-case since PLUGIN_* is a literal env var name and env var names can't contain
    # hyphens or dots.
    # The -- guards against BSD tr (macOS) reading a leading '-' in the SET1 argument as an
    # option flag instead of a literal character; GNU tr accepts -- too, so this is portable.
    env_key="PLUGIN_$(printf '%s' "${key}" | tr '[:lower:]' '[:upper:]' | tr -- '-.' '__')"

    # Validate the derived env-file key itself, the same way collect-outputs.sh validates keys
    # coming back from the plugin. A settings key with a space or other shell-illegal character
    # (an easy typo, e.g. `content type:` instead of `content-type:`) would otherwise survive
    # the tr transform unchanged and land straight in the docker --env-file, where it fails
    # `docker run --env-file` with an error that gives no hint the real cause is here.
    if ! [[ "${env_key}" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
        echo "Error: settings key '${key}' does not produce a valid env var name (got '${env_key}') - check for spaces or other unusual characters in this settings line: ${trimmed}" >&2
        exit 1
    fi

    printf '%s=%s\n' "${env_key}" "${value}" >>"${ORB_VAL_ENV_FILE}"
    plugin_count=$((plugin_count + 1))
    # Process substitution, deliberately not a herestring: two adjacent angle-bracket pairs
    # anywhere in an orb script get misparsed by CircleCI's own config compiler as a parameter
    # interpolation token once this file is spliced into orb YAML, so this avoids ever writing
    # that pair of characters back to back.
done < <(printf '%s\n' "${ORB_VAL_SETTINGS}")

echo "Wrote ${plugin_count} PLUGIN_* var(s) derived from settings."

# CIRCLE_* -> DRONE_*/HARNESS_* - only the mappings below have a real CircleCI equivalent to map
# from. Deliberately NOT shimmed here because no CircleCI equivalent exists / would have to be
# invented: DRONE_BUILD_EVENT, DRONE_STAGE_STATUS, DRONE_BUILD_STATUS, DRONE_FAILED_STEPS,
# DRONE_COMMIT_AUTHOR* (email n/a on CircleCI), HARNESS_ACCOUNT_ID/ORG_ID/PROJECT_ID/
# PIPELINE_ID/EXECUTION_ID/DELEGATE_ID, DRONE_NETRC_*, DRONE_SEMVER*/DRONE_CALVER,
# HARNESS_OUTPUT_SECRET_FILE (Harness's separate, feature-flagged output-*secrets* mechanism -
# see https://developer.harness.io/docs/continuous-integration/use-ci/use-drone-plugins/plugin-step-settings-reference/#output-secrets
# - out of scope here; a plugin that needs masked secret outputs has no equivalent on this orb).
{
    if [ -n "${CIRCLE_PROJECT_USERNAME:-}" ]; then
        printf 'DRONE_REPO_OWNER=%s\n' "${CIRCLE_PROJECT_USERNAME}"
    fi
    if [ -n "${CIRCLE_PROJECT_REPONAME:-}" ]; then
        printf 'DRONE_REPO_NAME=%s\n' "${CIRCLE_PROJECT_REPONAME}"
    fi
    if [ -n "${CIRCLE_PROJECT_USERNAME:-}" ] && [ -n "${CIRCLE_PROJECT_REPONAME:-}" ]; then
        printf 'DRONE_REPO=%s/%s\n' "${CIRCLE_PROJECT_USERNAME}" "${CIRCLE_PROJECT_REPONAME}"
    fi
    if [ -n "${CIRCLE_SHA1:-}" ]; then
        printf 'DRONE_COMMIT=%s\n' "${CIRCLE_SHA1}"
    fi
    if [ -n "${CIRCLE_BRANCH:-}" ]; then
        printf 'DRONE_COMMIT_BRANCH=%s\n' "${CIRCLE_BRANCH}"
    fi
    if [ -n "${CIRCLE_BUILD_NUM:-}" ]; then
        printf 'DRONE_BUILD_NUMBER=%s\n' "${CIRCLE_BUILD_NUM}"
    fi

    # Shared workspace path and the output-variable file path - both sides of the bind mounts
    # `run-plugin.sh` sets up. This orb controls the VALUE of every one of these (it's our own
    # container-workspace-path/container-output-file parameter), so it does not depend on how
    # Harness's own runner internally wires them up - only on the public, documented variable
    # NAMES a plugin might read.
    #   - HARNESS_WORKSPACE/DRONE_WORKSPACE: default path /harness, documented at
    #     https://developer.harness.io/docs/continuous-integration/troubleshoot-ci/ci-env-var/#lite-engine-environment-variables
    #   - DRONE_OUTPUT: documented at
    #     https://developer.harness.io/docs/continuous-integration/troubleshoot-ci/ci-env-var/#other-variables
    #     and https://developer.harness.io/docs/continuous-integration/use-ci/use-drone-plugins/plugin-step-settings-reference/#output-variables
    #   - HARNESS_OUTPUT: the HARNESS_-prefixed name for the same file, documented (alongside
    #     DRONE_OUTPUT) at
    #     https://developer.harness.io/docs/platform/harness-ai/core-capabilities/in-your-pipelines/worker-agent/configuration/#configure-agent-outputs
    #   - HARNESS_OUTPUT_FILE: included defensively for older plugins/snippets that reference
    #     this exact spelling, but NOT independently confirmed in Harness's current public docs
    #     as of writing - unverified, kept only because setting an extra unread env var is
    #     harmless. Prefer HARNESS_OUTPUT (above) as the confirmed HARNESS_-prefixed name.
    printf 'DRONE_WORKSPACE=%s\n' "${ORB_VAL_CONTAINER_WORKSPACE_PATH}"
    printf 'HARNESS_WORKSPACE=%s\n' "${ORB_VAL_CONTAINER_WORKSPACE_PATH}"
    printf 'DRONE_OUTPUT=%s\n' "${ORB_VAL_CONTAINER_OUTPUT_FILE}"
    printf 'HARNESS_OUTPUT=%s\n' "${ORB_VAL_CONTAINER_OUTPUT_FILE}"
    printf 'HARNESS_OUTPUT_FILE=%s\n' "${ORB_VAL_CONTAINER_OUTPUT_FILE}"
} >>"${ORB_VAL_ENV_FILE}"

# Print var NAMES only, never values - a value can be a resolved secret that isn't
# necessarily a registered context/project env var CircleCI's own log masking would catch.
echo "Derived env file at ${ORB_VAL_ENV_FILE} contains:"
cut -d= -f1 "${ORB_VAL_ENV_FILE}"
