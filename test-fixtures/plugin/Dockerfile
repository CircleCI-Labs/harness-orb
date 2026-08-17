# Test fixture only - not a published Drone/Harness plugin, and no PolyForm-licensed
# Harness/Drone source was read or reused to write this. Modeled purely on Harness's own
# PUBLIC DOCS walkthrough for authoring a custom plugin (script + Dockerfile + ENTRYPOINT),
# used by this repo's acceptance test and CI to exercise the orb's scripts end-to-end
# against a real, credential-free Docker image.
#
# `bash` is installed deliberately (not part of Harness's own walkthrough): this fixture also
# stands in as a native-primary-container test target (see test-deploy.yml's
# test_plugin_native_fixture_settings), and every native-path orb script
# (create-output-file.sh/map-env-native.sh/run-plugin-native.sh/collect-outputs.sh) is a bash
# script fed to a `run:` step's default bash shell -- a bash-less primary container fails on the
# very first native-path step with "bash: not found" (a real, separate gap: preflight-native.sh
# checks tar/gzip/git/ssh/CA certs but not bash itself). Installing bash here keeps this fixture
# usable as that test target without masking that gap -- it's flagged separately, not fixed here.
FROM alpine:3.20
RUN apk add --no-cache bash
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
