#!/bin/bash
set -uo pipefail

if [ -z "${ORB_VAL_IMAGE}" ]; then
    echo "Error: image parameter is required." >&2
    exit 1
fi

if [ ! -d "${ORB_VAL_WORKSPACE_PATH}" ]; then
    echo "Error: workspace-path '${ORB_VAL_WORKSPACE_PATH}' does not exist or is not a directory." >&2
    exit 1
fi
host_workspace_abs="$(cd "${ORB_VAL_WORKSPACE_PATH}" && pwd)"

if [ ! -f "${ORB_VAL_OUTPUT_FILE}" ]; then
    echo "Error: output-file '${ORB_VAL_OUTPUT_FILE}' does not exist - run create-output-file first." >&2
    exit 1
fi
host_output_abs="$(cd "$(dirname "${ORB_VAL_OUTPUT_FILE}")" && pwd)/$(basename "${ORB_VAL_OUTPUT_FILE}")"

if [ ! -f "${ORB_VAL_ENV_FILE}" ]; then
    echo "Error: env-file '${ORB_VAL_ENV_FILE}' does not exist - run map-env first." >&2
    exit 1
fi

# Boolean orb parameters interpolated into an `environment:` block render as the literal
# strings "true"/"false" - verified directly with `circleci config process` against a minimal
# repro of this exact <<parameters.x>> -> environment: -> shell pattern. (The act-orb `pull`/
# `privileged`-style comment this previously cited as precedent turned out to carry the same
# latent "1"/"0" bug rather than being confirmed-correct prior art - do not reintroduce it.)
if [ "${ORB_VAL_PULL}" = "true" ]; then
    echo "Pulling ${ORB_VAL_IMAGE}..."
    docker pull "${ORB_VAL_IMAGE}"
fi

docker_cmd=(docker run --rm
    --env-file "${ORB_VAL_ENV_FILE}"
    -v "${host_workspace_abs}:${ORB_VAL_CONTAINER_WORKSPACE_PATH}"
    -v "${host_output_abs}:${ORB_VAL_CONTAINER_OUTPUT_FILE}"
    -w "${ORB_VAL_CONTAINER_WORKSPACE_PATH}")

if [ "${ORB_VAL_PRIVILEGED}" = "true" ]; then
    docker_cmd+=(--privileged)
fi

if [ -n "${ORB_VAL_ADDITIONAL_DOCKER_FLAGS}" ]; then
    # Intentional word-splitting: additional-docker-flags is a caller-supplied flag string.
    # Globbing must be disabled around it, though: with pathname expansion left on, a single
    # wildcard character anywhere in a flag value (a stray '*' in a build-arg version pin, a
    # path glob, etc.) silently expands against this job's working directory and corrupts the
    # docker run argument list with real filenames instead of the literal flag text.
    set -f
    # shellcheck disable=SC2206
    extra_flags=(${ORB_VAL_ADDITIONAL_DOCKER_FLAGS})
    set +f
    docker_cmd+=("${extra_flags[@]}")
fi

docker_cmd+=("${ORB_VAL_IMAGE}")

echo "Running: ${docker_cmd[*]}"
"${docker_cmd[@]}"
plugin_exit_code=$?

# The plugin container commonly runs as root, so files it creates in the bind-mounted
# workspace are left root-owned on the host - which then breaks subsequent CircleCI steps
# running as the normal job user. Reclaim ownership unconditionally, regardless of whether
# the plugin succeeded, without masking the plugin's own exit code. Try three ways, in
# order of preference, and stop at the first that works:
#   1. sudo chown - what CircleCI's own machine executor images document as available
#      (the default job user has passwordless sudo), and needs nothing extra pulled.
#   2. plain chown - covers the case where this is already running as root.
#   3. a throwaway container doing the chown from inside a Linux mount namespace that can
#      always write the bind-mounted path, regardless of host sudo configuration - this is
#      what makes the fix-up portable to environments without passwordless sudo (verified
#      as the path this repo's own local acceptance test exercises).
job_user_uid="$(id -u)"
job_user_gid="$(id -g)"
ownership_fixed=1
if command -v sudo >/dev/null 2>&1 && sudo chown -R "${job_user_uid}:${job_user_gid}" "${host_workspace_abs}" 2>/dev/null; then
    ownership_fixed=0
elif chown -R "${job_user_uid}:${job_user_gid}" "${host_workspace_abs}" 2>/dev/null; then
    ownership_fixed=0
elif docker run --rm -v "${host_workspace_abs}:/harness-orb-chown-target" busybox \
    chown -R "${job_user_uid}:${job_user_gid}" /harness-orb-chown-target >/dev/null 2>&1; then
    ownership_fixed=0
fi
if [ "${ownership_fixed}" -ne 0 ]; then
    echo "Error: failed to reclaim ownership of ${host_workspace_abs} after the plugin run (tried sudo chown, plain chown, and a busybox container chown - all three failed). Workspace files may still be root-owned, which will surface as a confusing permission error in a later, unrelated step." >&2
    # Don't let this hide behind a green step: if the plugin itself already failed, that
    # exit code is the more useful signal and takes priority; but if the plugin succeeded,
    # failing here (rather than only warning) is the only way this problem is visible at all.
    if [ "${plugin_exit_code}" -eq 0 ]; then
        exit 1
    fi
fi

exit "${plugin_exit_code}"
