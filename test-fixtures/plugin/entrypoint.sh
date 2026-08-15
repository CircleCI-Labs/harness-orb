#!/bin/sh
set -eu

# Test fixture only - not a published Drone/Harness plugin. Modeled on the shape of
# Harness's own public "write a script, put it in a container, ENTRYPOINT runs it"
# minimal-plugin walkthrough (developer.harness.io: use-drone-plugins/custom_plugins),
# extended to also demonstrate the output-variable contract for this orb's acceptance test.
# Reads PLUGIN_* settings env vars, writes a file into the shared workspace (as root, on
# purpose, to exercise the orb's post-run ownership fix-up), and appends KEY=value lines to
# $DRONE_OUTPUT.

# PLUGIN_FAIL is a test-only escape hatch (no real Drone/Harness plugin settings key), used
# by this orb's own failure-propagation regression test. When set to a non-empty value, exit
# with it as the process exit code, before writing anything else -- exercising the case where
# the vendor plugin itself fails and run-plugin.sh must propagate that exit code unchanged.
if [ -n "${PLUGIN_FAIL:-}" ]; then
    echo "test-fixture-plugin: PLUGIN_FAIL=${PLUGIN_FAIL} set - exiting with that code on purpose" >&2
    exit "${PLUGIN_FAIL}"
fi

echo "test-fixture-plugin: PLUGIN_MESSAGE=${PLUGIN_MESSAGE:-<unset>}"
echo "test-fixture-plugin: PLUGIN_GREETING=${PLUGIN_GREETING:-<unset>}"
echo "test-fixture-plugin: DRONE_REPO=${DRONE_REPO:-<unset>}"
echo "test-fixture-plugin: DRONE_WORKSPACE=${DRONE_WORKSPACE:-<unset>}"
echo "test-fixture-plugin: running as uid=$(id -u) gid=$(id -g)"

workspace="${DRONE_WORKSPACE:-/harness}"
echo "test-fixture-plugin: workspace contents before:"
ls -la "${workspace}"

echo "written by the plugin container, running as root, repo=${DRONE_REPO:-<unset>}" \
    > "${workspace}/plugin-wrote-this.txt"

if [ -z "${DRONE_OUTPUT:-}" ]; then
    echo "test-fixture-plugin: Error: DRONE_OUTPUT is not set" >&2
    exit 1
fi

{
    echo "PLUGIN_RESULT=ok"
    echo "GREETING_ECHOED=${PLUGIN_GREETING:-nogreeting}"
} >> "${DRONE_OUTPUT}"

echo "test-fixture-plugin: wrote outputs to ${DRONE_OUTPUT}"
