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

# Boolean orb parameters interpolated into an `environment:` block render as the
# strings "1" (true) / "0" (false), not "true"/"false" - matching the convention the
# reference act-orb's own scripts rely on (see run-act.sh).
if [ "${ORB_VAL_PULL}" = "1" ]; then
    echo "Pulling ${ORB_VAL_IMAGE}..."
    docker pull "${ORB_VAL_IMAGE}"
fi

docker_cmd=(docker run --rm
    --env-file "${ORB_VAL_ENV_FILE}"
    -v "${host_workspace_abs}:${ORB_VAL_CONTAINER_WORKSPACE_PATH}"
    -v "${host_output_abs}:${ORB_VAL_CONTAINER_OUTPUT_FILE}"
    -w "${ORB_VAL_CONTAINER_WORKSPACE_PATH}")

if [ "${ORB_VAL_PRIVILEGED}" = "1" ]; then
    docker_cmd+=(--privileged)
fi

if [ -n "${ORB_VAL_ADDITIONAL_DOCKER_FLAGS}" ]; then
    # Intentional word-splitting: additional-docker-flags is a caller-supplied flag string.
    # shellcheck disable=SC2206
    extra_flags=(${ORB_VAL_ADDITIONAL_DOCKER_FLAGS})
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
    echo "Warning: failed to reclaim ownership of ${host_workspace_abs} after the plugin run; workspace files may still be root-owned." >&2
fi

exit "${plugin_exit_code}"
