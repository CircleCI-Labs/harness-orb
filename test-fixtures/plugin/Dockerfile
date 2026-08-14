# Test fixture only - not a published Drone/Harness plugin, and no PolyForm-licensed
# Harness/Drone source was read or reused to write this. Modeled purely on Harness's own
# PUBLIC DOCS walkthrough for authoring a custom plugin (script + Dockerfile + ENTRYPOINT),
# used by this repo's acceptance test and CI to exercise the orb's scripts end-to-end
# against a real, credential-free Docker image.
FROM alpine:3.20
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
