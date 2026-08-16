#!/bin/bash
set -uo pipefail

# Runs the plugin's REAL entrypoint as an ordinary `run:` step inside the job's own primary
# container (the plugin's own image) -- no `docker run`, no bind mount, no --privileged, no
# post-run chown. This is the mechanism the whole native-primary-container path rests on:
# CircleCI ignores a primary container's own ENTRYPOINT/CMD and runs `steps:` inside the
# already-live container, so exec'ing the plugin's documented entrypoint command directly IS the
# equivalent of "docker run <image>" here -- the image is already running, this just invokes what
# its Dockerfile would otherwise have run automatically.
#
# PLUGIN_*/DRONE_*/HARNESS_* env vars are already present in this step's shell -- map-env-native
# exported them into $BASH_ENV, and every `run:` step sources $BASH_ENV before its command runs --
# so nothing further is needed to make them visible to the entrypoint process below.
#
# `entrypoint` is a REQUIRED parameter with no default at the command/job level specifically so
# omitting it is a config-validation error, never a runtime guess: a plugin's real entrypoint is
# vendor-chosen and arbitrary (/bin/drone-slack, /pipe.sh, python3 /pipe.py) and cannot be
# discovered from inside the container without a Docker daemon to `docker inspect` with -- which a
# docker-executor primary container does not have.

if [ -z "${ORB_VAL_ENTRYPOINT}" ]; then
    echo "Error: entrypoint parameter is required and must not be empty. A plugin's real entrypoint is vendor-chosen (e.g. '/bin/drone-slack', '/pipe.sh', 'python3 /pipe.py') and cannot be auto-detected from inside a docker-executor primary container (there is no Docker daemon here to 'docker inspect' with). Find it in the plugin's own Dockerfile/documentation." >&2
    exit 1
fi

echo "Running (native primary-container mode): ${ORB_VAL_ENTRYPOINT}"

# sh -c "<string>", not eval and not a bare word-split exec: this correctly runs both a
# single-binary entrypoint ('/bin/drone-slack') and a multi-word one ('python3 /pipe.py') exactly
# the way the image's own Dockerfile ENTRYPOINT/CMD would have been interpreted, with ordinary
# shell word-splitting/quoting rules applied once, not twice.
sh -c "${ORB_VAL_ENTRYPOINT}"
exit $?
