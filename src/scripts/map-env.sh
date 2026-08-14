#!/bin/bash
set -euo pipefail

if [ -z "${ORB_VAL_ENV_FILE}" ]; then
    echo "Error: env-file must not be empty." >&2
    exit 1
fi

mkdir -p "$(dirname "${ORB_VAL_ENV_FILE}")"
: >"${ORB_VAL_ENV_FILE}"

# Resolve $VAR / ${VAR} references in the settings block against the job's real env vars
# (context/project env vars), so a caller can write e.g. `webhook: $SLACK_WEBHOOK` in orb
# config without the secret ever appearing in config. `circleci env subst` is bundled into
# every CircleCI job regardless of image; fall back to a plain envsubst if it is somehow
# missing (e.g. this script run standalone for local testing), and fail loudly rather than
# silently skipping substitution if neither is available.
resolved_settings="${ORB_VAL_SETTINGS}"
if command -v circleci >/dev/null 2>&1; then
    resolved_settings="$(printf '%s' "${ORB_VAL_SETTINGS}" | circleci env subst)"
elif command -v envsubst >/dev/null 2>&1; then
    echo "Warning: 'circleci' CLI not found; falling back to plain envsubst for settings substitution." >&2
    resolved_settings="$(printf '%s' "${ORB_VAL_SETTINGS}" | envsubst)"
else
    echo "Warning: neither 'circleci' nor 'envsubst' found; settings passed through with no \$VAR substitution." >&2
fi

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
    # themselves contain a bare colon (URLs, times, JSON) are preserved intact.
    case "${trimmed}" in
        *': '*)
            key="${trimmed%%: *}"
            value="${trimmed#*: }"
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

    # PLUGIN_<KEY>: uppercase, kebab-case/dotted keys normalized to underscores - this is
    # the verified Harness case rule (settings.repo_url -> PLUGIN_REPO_URL, etc.), extended
    # to kebab-case since PLUGIN_* is a literal env var name and env var names can't contain
    # hyphens or dots.
    # The -- guards against BSD tr (macOS) reading a leading '-' in the SET1 argument as an
    # option flag instead of a literal character; GNU tr accepts -- too, so this is portable.
    env_key="PLUGIN_$(printf '%s' "${key}" | tr '[:lower:]' '[:upper:]' | tr -- '-.' '__')"

    printf '%s=%s\n' "${env_key}" "${value}" >>"${ORB_VAL_ENV_FILE}"
    plugin_count=$((plugin_count + 1))
    # Process substitution, deliberately not a herestring: two adjacent angle-bracket pairs
    # anywhere in an orb script get misparsed by CircleCI's own config compiler as a parameter
    # interpolation token once this file is spliced into orb YAML, so this avoids ever writing
    # that pair of characters back to back.
done < <(printf '%s\n' "${resolved_settings}")

echo "Wrote ${plugin_count} PLUGIN_* var(s) derived from settings."

# CIRCLE_* -> DRONE_*/HARNESS_* - only the mappings explicitly verified against Harness's
# own CI environment variables reference (see harness.md Section 3). Deliberately NOT
# shimmed here because no CircleCI equivalent exists / would have to be invented:
# DRONE_BUILD_EVENT, DRONE_STAGE_STATUS, DRONE_BUILD_STATUS, DRONE_FAILED_STEPS,
# DRONE_COMMIT_AUTHOR* (email n/a on CircleCI), HARNESS_ACCOUNT_ID/ORG_ID/PROJECT_ID/
# PIPELINE_ID/EXECUTION_ID/DELEGATE_ID, DRONE_NETRC_*, DRONE_SEMVER*/DRONE_CALVER.
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

    # Shared workspace path, and the output-variable file path - both sides of the bind
    # mounts `run.sh` sets up, verified in Section 3 (HARNESS_WORKSPACE/DRONE_WORKSPACE;
    # DRONE_OUTPUT/HARNESS_OUTPUT_FILE, both pointed at the same generated path by
    # lite-engine per the docs-cited source excerpt).
    printf 'DRONE_WORKSPACE=%s\n' "${ORB_VAL_CONTAINER_WORKSPACE_PATH}"
    printf 'HARNESS_WORKSPACE=%s\n' "${ORB_VAL_CONTAINER_WORKSPACE_PATH}"
    printf 'DRONE_OUTPUT=%s\n' "${ORB_VAL_CONTAINER_OUTPUT_FILE}"
    printf 'HARNESS_OUTPUT_FILE=%s\n' "${ORB_VAL_CONTAINER_OUTPUT_FILE}"
} >>"${ORB_VAL_ENV_FILE}"

# Print var NAMES only, never values - a value can be a resolved secret that isn't
# necessarily a registered context/project env var CircleCI's own log masking would catch.
echo "Derived env file at ${ORB_VAL_ENV_FILE} contains:"
cut -d= -f1 "${ORB_VAL_ENV_FILE}"
