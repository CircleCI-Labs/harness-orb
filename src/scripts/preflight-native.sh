#!/bin/bash
set -uo pipefail

# Mandatory eligibility gate for the "plugin image as the job container" (native primary
# container) path. Runs FIRST, before checkout/attach_workspace, so an ineligible image fails
# fast with a specific, actionable reason instead of a confusing mid-job break (a checkout that
# dies partway through because git is missing, or a plugin binary that dies on its first HTTPS
# call because the CA bundle is empty).
#
# CircleCI's own custom-image guide requires a shell plus git, ssh, tar, gzip and
# ca-certificates in a primary container:
# https://circleci.com/docs/custom-images/#adding-required-tools-to-a-custom-image
# The base tier below (tar/gzip/ca-certificates) applies unconditionally, because
# attach_workspace itself needs tar to unpack the workspace archive and ca-certificates to talk
# to CircleCI's API over HTTPS -- not just because checkout might run. git/ssh are checked only
# when ORB_VAL_CHECKOUT is true, since attach_workspace (this job's default) needs neither.
#
# Every check below is a check of THIS CONTAINER'S OWN FILESYSTEM/PATH -- nothing here talks to a
# Docker daemon, because a docker-executor primary container does not have one. That constraint
# is exactly why the plugins/docker case (below) is detected the way it is, not with
# `docker inspect`.

orb_bool_is_true() {
    case "${1:-}" in
        1 | true | True | TRUE) return 0 ;;
        *) return 1 ;;
    esac
}

fail() {
    # $1: short machine-readable reason code, kept in the message so a test (or a human grepping
    # CI logs) can match on it without depending on the full prose staying byte-for-byte stable.
    echo "PREFLIGHT REFUSED (${1}): ${2}" >&2
    exit 1
}

warn() {
    echo "PREFLIGHT WARNING (${1}): ${2}" >&2
}

echo "Running native-primary-container preflight against this image..."

# --- 1. Docker-daemon requirement (the plugins/docker case) -----------------------------------
#
# plugins/docker is built FROM the official `docker` image and its own ENTRYPOINT is
# dockerd-entrypoint.sh, a wrapper that expects a Docker daemon reachable via $DOCKER_HOST (either
# one it starts itself, which a docker-executor primary container cannot do -- no --privileged, no
# /var/run/docker.sock -- or one supplied externally). There is no daemon inside a plain
# docker-executor primary container, so this must be refused, distinctly from a merely-missing
# tool: the fix is "use the machine-executor `plugin` job instead", not "add a missing binary to
# your image".
#
# Detected by looking for the dockerd binary or the dockerd-entrypoint.sh wrapper script directly
# on this container's filesystem -- a static signature, not a live daemon probe (there is no
# daemon to probe). This is a real, honest limitation: it only catches an image that VENDORS its
# own dockerd (plugins/docker's actual case). A plugin that merely shells out to a bare `docker`
# CLI and assumes some EXTERNAL daemon is reachable via a pre-set $DOCKER_HOST leaves no such
# static signature and is NOT reliably detectable from inside the container filesystem alone --
# needing a live daemon at runtime is a behavior, not a file. Documented here and in the README
# rather than silently claimed as caught.
docker_daemon_signal=""
for candidate_dir in /usr/local/bin /usr/local/sbin /usr/bin /usr/sbin /bin /sbin; do
    if [ -e "${candidate_dir}/dockerd-entrypoint.sh" ]; then
        docker_daemon_signal="${candidate_dir}/dockerd-entrypoint.sh"
        break
    fi
    if [ -e "${candidate_dir}/dockerd" ]; then
        docker_daemon_signal="${candidate_dir}/dockerd"
        break
    fi
done
if [ -z "${docker_daemon_signal}" ] && command -v dockerd > /dev/null 2>&1; then
    docker_daemon_signal="$(command -v dockerd)"
fi
if [ -n "${docker_daemon_signal}" ]; then
    fail "docker-daemon-required" "found ${docker_daemon_signal} in this image. This image ships its own dockerd (or a dockerd-entrypoint.sh wrapper) and expects a reachable Docker daemon via \$DOCKER_HOST -- there is no daemon inside a CircleCI docker-executor primary container, and there never can be without --privileged (which the docker executor refuses). Use the existing machine-executor 'harness/plugin' job (docker run against a real daemon) for this image instead of 'harness/plugin-native'."
fi

# --- 2. Base tier: tar, gzip, ca-certificates --------------------------------------------------
# Required unconditionally -- attach_workspace needs tar to unpack the workspace archive it
# receives, and both attach_workspace and the plugin's own network calls need real CA certs for
# HTTPS. See CircleCI's custom-image doc linked above.
if ! command -v tar > /dev/null 2>&1; then
    fail "missing-tool: tar" "'tar' was not found in this image. attach_workspace (and checkout, if enabled) needs tar in the primary container to unpack the workspace/checkout archive -- see https://circleci.com/docs/custom-images/#adding-required-tools-to-a-custom-image"
fi
if ! command -v gzip > /dev/null 2>&1; then
    fail "missing-tool: gzip" "'gzip' was not found in this image. attach_workspace (and checkout, if enabled) needs gzip in the primary container to decompress the workspace/checkout archive -- see https://circleci.com/docs/custom-images/#adding-required-tools-to-a-custom-image"
fi

# BusyBox tar/gzip (common on Alpine-based images) is a warning, not a refusal: CircleCI's own
# guidance is to install GNU tar/gzip because BusyBox's variants have known incompatibilities that
# can silently truncate or corrupt attach_workspace/persist_to_workspace archives. Detected by
# grepping the tool's own --version/--help banner for "busybox" (GNU coreutils never prints that
# string; BusyBox's multi-call binary always does, on both `tar --help` and `busybox` alone).
if tar --version 2>&1 | grep -qi busybox || [ "$(readlink -f "$(command -v tar)" 2> /dev/null || command -v tar)" = "$(command -v busybox 2> /dev/null || echo __no_busybox__)" ]; then
    warn "busybox-tar" "tar in this image appears to be BusyBox tar, not GNU tar. CircleCI's own guidance for custom images recommends GNU tar/gzip -- BusyBox tar has known incompatibilities that can silently truncate or corrupt attach_workspace/persist_to_workspace archives. Continuing, but this is a real risk on this image."
fi
if gzip --version 2>&1 | grep -qi busybox || [ "$(readlink -f "$(command -v gzip)" 2> /dev/null || command -v gzip)" = "$(command -v busybox 2> /dev/null || echo __no_busybox__)" ]; then
    warn "busybox-gzip" "gzip in this image appears to be BusyBox gzip, not GNU gzip. CircleCI's own guidance for custom images recommends GNU tar/gzip -- BusyBox's variant has known incompatibilities that can silently truncate or corrupt attach_workspace/persist_to_workspace archives. Continuing, but this is a real risk on this image."
fi

ca_bundle_found=""
for candidate_ca in /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-bundle.crt \
    /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/cert.pem; do
    if [ -f "${candidate_ca}" ]; then
        # A CA bundle "present but a stub" is real, verified reality (plugins/slack) -- so
        # existence alone is not enough; require a size a real bundle would actually have. Debian
        # bundles run several hundred KB; even a minimal set is tens of KB. 1024 bytes is a
        # generous floor that a genuine (if pruned) bundle clears easily and an empty/stub
        # placeholder file does not.
        candidate_size="$(wc -c < "${candidate_ca}" 2> /dev/null | tr -d '[:space:]')"
        if [ -n "${candidate_size}" ] && [ "${candidate_size}" -gt 1024 ]; then
            ca_bundle_found="${candidate_ca}"
            break
        fi
    fi
done
if [ -z "${ca_bundle_found}" ]; then
    fail "missing-ca-certificates" "no usable CA certificate bundle was found in this image (checked /etc/ssl/certs/ca-certificates.crt, /etc/ssl/certs/ca-bundle.crt, /etc/pki/tls/certs/ca-bundle.crt, /etc/ssl/cert.pem -- each must exist AND be larger than 1024 bytes, since a present-but-empty/stub bundle file is a real case this orb has seen). Without real CA certificates, HTTPS calls this job needs (CircleCI's own API for attach_workspace/persist_to_workspace, and most plugin backends) will fail with certificate-verification errors."
fi

# --- 3. Checkout tier: git, ssh (only when checkout: true is requested) -----------------------
if orb_bool_is_true "${ORB_VAL_CHECKOUT:-}"; then
    if ! command -v git > /dev/null 2>&1; then
        fail "missing-tool: git" "'git' was not found in this image, but checkout: true was requested. See https://circleci.com/docs/custom-images/#adding-required-tools-to-a-custom-image -- either set checkout: false and rely on attach_workspace instead (this job's default), or use an image that includes git."
    fi
    if ! command -v ssh > /dev/null 2>&1; then
        fail "missing-tool: ssh" "'ssh' was not found in this image, but checkout: true was requested. See https://circleci.com/docs/custom-images/#adding-required-tools-to-a-custom-image -- either set checkout: false and rely on attach_workspace instead (this job's default), or use an image that includes ssh."
    fi
fi

echo "Preflight passed: ${ca_bundle_found} is a usable CA bundle, tar/gzip present$(orb_bool_is_true "${ORB_VAL_CHECKOUT:-}" && echo ', git/ssh present (checkout: true)' || echo ' (checkout: false -- git/ssh not required)')."
