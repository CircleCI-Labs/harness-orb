# Limits, gotchas, and trust notes

The full list of what doesn't work through this orb, the security tradeoffs worth understanding
before you turn a knob, and the gotchas found while building and testing it.

## What genuinely doesn't work

| Doesn't work | Why |
|---|---|
| **`HARNESS_OUTPUT_SECRET_FILE`** | Not wired up: Harness's separate, feature-flag-gated auto-masked-output mechanism. A plugin using it has no equivalent here. See [MIGRATING.md](MIGRATING.md) and [ROADMAP.md](ROADMAP.md) item 1. |
| **Output variables spanning more than one CircleCI job** | This orb's `$BASH_ENV` mechanism is job-scoped; Harness's own output-variable expressions are stage-scoped (cross-job). See [MIGRATING.md](MIGRATING.md)'s "Passing data across jobs anyway" for the real `persist_to_workspace`/`continuation`-orb workarounds. |
| **No `store_artifacts` default, and `store_test_results` is opt-in only** | No vendor-wide Plugin-step convention exists to default `store_artifacts` against at all. See "Artifacts and test results" below. `store_test_results` has an explicit opt-in via the `test-results-path` parameter (empty by default, so nothing runs) once you know your specific plugin's own JUnit XML output path. There is still no default path, since none exists to default to. |
| **No built-in private-registry authentication** | Unlike this orb's sibling `bitbucket` orb (which has `registry-username`/`registry-password` parameters), `run-plugin` always does a plain, unauthenticated `docker pull`. For a private plugin image, `docker login` yourself first: a `pre-steps` step on the `harness/plugin` job, or a step before `run-plugin`/`plugin` if you're composing commands directly. See [ROADMAP.md](ROADMAP.md) item 2. |
| **Harness's `connectorRef` / SaaS control plane** | No account, delegate, or `lite-engine` involved at all; this orb only ever shells out to `docker run` locally. Anything that requires Harness's own backend (audit trails, approval gates, template library) has no equivalent. |
| **A Drone/Harness plugin with no public Docker image** | This orb only runs a plugin by its Docker image reference. A plugin only ever distributed as a Harness-hosted "built-in" step with no separate pullable image can't be targeted. |

## Docker-in-Docker and `--privileged`: what it actually grants

`privileged: true` is not a narrow "let Docker-in-Docker work" carve-out. Combined with the
`machine` executor's real host-device access, `--privileged` grants the plugin container
`CAP_SYS_ADMIN`. From there, a compromised or supply-chain-tampered plugin image can mount a host
block device and read or write the entire job VM's filesystem: a full host-compromise primitive.
Only set `privileged: true` for a plugin image you trust, the same way you'd trust any other binary
you run with root on CI.

More generally: `run-plugin` always runs the plugin's Docker image with the job's full environment
available to it via `--env-file` and a bind-mounted checkout. Treat every plugin image the same way
you'd treat a third-party dependency you added to your build. It is not sandboxed against the job's
secrets or filesystem beyond what a plain `docker run` container boundary already gives you.

## Workspace ownership

Plugin containers commonly run as root, so files they create in the bind-mounted workspace can be
left root-owned on the host, breaking subsequent CircleCI steps. `run-plugin` reclaims ownership
after every invocation, regardless of whether the plugin succeeded, trying `sudo chown` (what
CircleCI's machine executor images document as available), then plain `chown`, then a throwaway
container-based `chown` as a last resort, so the fix-up doesn't strictly depend on host sudo being
configured.

## Defaults that deviate from a bare `docker run`

This orb intentionally overrides one of the defaults its own execution contract (`docker run -e
PLUGIN_X=Y image`) would otherwise carry:

| Parameter | A bare `docker run`'s own default | This orb's default | Why |
|---|---|---|---|
| `pull` | Docker's own default pull policy only pulls when the image isn't already present locally; an already-cached image is reused as-is, even for a mutable tag. | `true` | `run-plugin` runs `docker pull` before every invocation, refreshing mutable tags on every run rather than silently reusing a stale cached copy. See "Immutable pinning" below for why an unpinned reference is worth refreshing eagerly instead of trusting whatever happens to be cached. |

Every other default (`privileged: false`, an unauthenticated `docker pull`, no automatic
`store_artifacts`/`store_test_results`) matches what a bare `docker run`, or the absence of any
Harness Plugin-step convention to default against, would already do. See "Artifacts and test
results" below and "Docker-in-Docker and `--privileged`" above for why those specifically aren't
deviations dressed up as defaults.

## Artifacts and test results: deliberately not auto-defaulted

Other orbs in the `cci-labs` ecosystem-bridge family default to running `store_artifacts`/
`store_test_results` for you against a vendor-documented directory, with zero config (this orb's
sibling `bitrise` orb, for example). This orb does not, on either axis, and that's a deliberate
per-vendor decision rather than an oversight. There's no matching Harness convention to default
against:

- **No `store_artifacts` default.** Harness's only documented Plugin-step artifact hook is
  `PLUGIN_ARTIFACT_FILE` ([CI environment
  variables](https://developer.harness.io/docs/continuous-integration/ci-technical-reference/ci-env-var/#other-variables)),
  and that's a link-manifest file Harness's own hosted UI resolves into clickable links, not a
  directory of real artifact bytes. There is no Harness-documented fixed directory a Plugin step
  writes actual output files into (unlike Bitrise's `$BITRISE_DEPLOY_DIR`). Wiring
  `store_artifacts` at some invented directory here would either silently upload nothing or upload
  the wrong thing, which is worse than no default at all.
- **No `store_test_results` default.** Harness's JUnit-XML/`reports:` mechanism ([Report
  paths](https://developer.harness.io/docs/continuous-integration/use-ci/run-step-settings/#report-paths))
  is a feature of Run/Test step types only. The Plugin step type this orb wraps has no `reports:`
  field and no documented test-report convention at all. Plugin-step vendor images (Slack notify,
  Docker build/push, and similar) generally aren't test runners in the first place.

If you know the specific plugin you're running writes artifacts or test reports to a predictable
path inside the bind-mounted checkout, add your own `store_artifacts`/`store_test_results` step (or
`post-steps:` on the `harness/plugin` job) pointed at that path. There's just no vendor-wide
convention this orb can default against safely.

## Immutable pinning

`image` is passed through verbatim, with no version resolution of any kind. Any reference other
than a full digest pin can silently point at different image content later with no diff in this
repo to review: an omitted tag means `:latest` (the most mutable case), but even an explicit
version tag (`plugins/slack:1.4.1`) can be force-moved by the image's own maintainer. `run-plugin`
prints a one-line `WARNING` to the step's stderr whenever `image` doesn't contain `@sha256:...`,
mirroring the identical unpinned-`#ref` warning the sibling `buildkite` orb already prints for a
plugin reference with no ref pinned. To pin by digest, pull the image once and read its digest
back:

```shell
docker pull plugins/slack:1.4.1
docker inspect --format '{{.RepoDigests}}' plugins/slack:1.4.1
# => [plugins/slack@sha256:1a2b3c...]
```

then use that full `image@sha256:...` string as `image`. This is a warning, not an enforced gate.
Pinning is recommended, not required, since some plugins (and this orb's own examples) are
deliberately shown against a floating tag for readability.

## Caching the plugin image

The `default` executor's `docker_layer_caching` parameter (off by default) enables CircleCI's
Docker Layer Caching for the `machine` executor's Docker daemon. DLC caches the layers a `docker
build` produces; it is a cache for building an image, not for pulling one. It can incidentally
speed up a pull when the target image's layers already happen to be present and unchanged from an
earlier build on the same host, but that is not what the feature is for and it is not something to
rely on. This orb never builds an image: `run-plugin`/`run-plugin.sh` only `docker pull`s and
`docker run`s the vendor-published plugin image verbatim (see [ARCHITECTURE.md](ARCHITECTURE.md)),
so there is no build step here for DLC to cache -- which is exactly why it stays off by default,
and why measurement bears that out: against `plugins/docker` (~208MB), it produced no measurable
improvement to a repeat plugin-image pull across two independent pipeline runs, while adding its
own ~3s of spin-up/teardown overhead plus its billed, plan-gated cost -- see
[ROADMAP.md](ROADMAP.md)'s "Image caching economics" section for the full numbers and job
references. The one way DLC could matter for a job using this orb is if your own `pre-steps` or
`post-steps` (accepted by every CircleCI 2.1+ job, including `plugin`/`plugin-native`) run a real
`docker build` of your own -- that is what DLC is built for, and it sits entirely outside what this
orb itself does. It remains available as an opt-in for anyone whose own build steps, plugin image,
or network conditions differ from what was measured; see [CircleCI's Docker Layer Caching
docs](https://circleci.com/docs/docker-layer-caching/) for current plan eligibility and pricing.

## Preflight verification drift (native path)

Verified directly (`docker run --entrypoint sh <image>` against each real image, not taken on
faith) against the five images sampled while designing the native path, the results have drifted
from that design pass for two of them, confirmed while wiring up this repo's own CI:

| Image | Preflight verdict (checkout: false) | Why |
|---|---|---|
| `bitbucketpipelines/git-secrets-scan:3.2.0` | Passes | Has everything the custom-image guide requires; entrypoint `python3 /pipe.py`. The only one of the five this repo's own CI runs the full working path against. |
| `plugins/docker` | Refused: `docker-daemon-required` | Ships `dockerd`/`dockerd-entrypoint.sh`, needs `$DOCKER_HOST`. Matches the design pass. |
| `plugins/s3` | Refused: `missing-tool: tar` (also has no `git`/`gzip`) | Fails the very first tool check. Matches the design pass. |
| `plugins/slack` | Passes with `checkout: false`; refused (`missing-tool: git`) only with `checkout: true` | Drifted from the design pass's "CA bundle is a stub" call: as of this writing `plugins/slack:latest` ships a real, roughly 220KB `/etc/ssl/certs/ca-certificates.crt`. It does still lack `git`, so this repo's own CI uses it (a real image, not a fixture) for the `checkout: true` missing-`git` branch instead. |
| `bitbucketpipelines/demo-pipe-bash:0.1.0` | Passes with `checkout: false` | Also drifted: the design pass's "zero CA certificates" call no longer holds; it now ships a real roughly 230KB `/etc/ssl/cert.pem`. |

That drift is exactly the risk "Immutable pinning" above warns about: neither sampled image was
pinned by digest, so both floated to different real content between the design pass and this
writing. Net effect: none of the five sampled images currently demonstrates the
`missing-ca-certificates` refusal. Both candidates the design pass named for it have since gained
real CA bundles. That branch is still real code with a still-real test, just not one backed by a
still-eligible sampled image; this repo's own CI covers it with a small synthetic fixture (Alpine
with both known CA bundle file paths truncated to empty) built on the fly instead, documented as a
real, current gap rather than silently passed off as sampled-image coverage.

## What the native path gives up, and what you don't get for free

- **No `privileged: true`.** The `docker` executor refuses privileged containers outright,
  matching CircleCI's own docker-vs-machine executor table (privileged is unsupported on `docker`).
  Any plugin needing Docker-in-Docker or Kaniko-root-mode needs the machine-executor
  `plugin`/`harness/plugin` path instead.
- **No chaining two different plugin images in one job.** The primary container is fixed for the
  whole job's lifetime. That's the platform mechanism
  [`chain_two_plugins.yml`](../src/examples/chain_two_plugins.yml) relies on `machine` plus
  repeated `docker run` to get around, and this path structurally cannot.
- **Not cheaper than `setup_remote_docker`.** Since June 2023, CircleCI bills remote Docker at the
  same rate as `machine`. The real saving here is against a `machine`-executor VM's 30-60s boot
  time and its per-second-of-VM billing, at the plain `docker`-executor rate, not against
  `setup_remote_docker` specifically. This only pays off for a plugin that genuinely needs no
  Docker daemon of its own at all.
- **What it does buy:** no `machine` VM boot, the plain `docker`-executor billing rate, and no
  post-run `chown`, because nothing ever wrote into a bind-mounted, differently-UID'd container in
  the first place.
