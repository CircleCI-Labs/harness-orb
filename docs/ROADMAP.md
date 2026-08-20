# Roadmap / deferred design decisions

This file records the things a recent audit of the `cci-labs` ecosystem-bridge orb family
(2026-08) found worth doing to `harness-orb`, but that this orb deliberately does **not** do, and
why. The decision is visible in the repo instead of living only in a chat transcript or a PR
description that ages out. It also carries forward the reasoning behind a handful of scope/design
calls that already shipped, so a future contributor doesn't have to re-derive "why is it built
this way" from scratch.

None of the items below are secretly half-built. If you pick one up, treat this as the starting
brief, not a patch to apply.

## Deferred / not implemented

### 1. `HARNESS_OUTPUT_SECRET_FILE`

**What it would do:** wire up Harness's separate, newer, feature-flag-gated mechanism for output
variables that Harness's own hosted UI auto-masks as secrets in logs
([Output secrets](https://developer.harness.io/docs/continuous-integration/use-ci/use-drone-plugins/plugin-step-settings-reference/#output-secrets)).

**Why it's deferred:** this orb only reads back `DRONE_OUTPUT`/`HARNESS_OUTPUT` today, and every
value it exports (declared output or not) lands in `$BASH_ENV` unmasked regardless. Adding a
second output channel without also solving log masking for it would be a half-measure that could
read as more security than it actually provides.

**What shipped instead:** the gap is stated plainly in [MIGRATING.md](MIGRATING.md) ("CIRCLE_* to
DRONE_*/HARNESS_*") and [LIMITS.md](LIMITS.md), rather than silently doing nothing with no
explanation. Any plugin's output this orb does export is documented as unmasked, full stop. See
[LIMITS.md](LIMITS.md)'s "Docker-in-Docker and `--privileged`" for the same "treat this as public
log content" framing applied consistently across the orb.

**If someone picks this up:** the real work is CircleCI-side, not orb-side. There's no hook into
CircleCI's log-masking pipeline this orb could register a value with after the fact. This is
blocked on a platform capability, not an implementation gap in this orb.

### 2. Built-in private-registry authentication

**What it would do:** add `registry-username`/`registry-password`-style parameters, matching the
sibling `bitbucket` orb, so `run-plugin` can `docker login` before pulling a private plugin image.

**Why it's deferred:** `harness-orb`'s scope started from Harness's own local-plugin-testing
contract (`docker run -e PLUGIN_X=Y image`, quoted in [ARCHITECTURE.md](ARCHITECTURE.md)), which
assumes the image is already pullable. Registry auth wasn't part of the original bridge shape, and
every verified target plugin (`plugins/docker`, `plugins/slack`, `plugins/github-actions`, and
others) is public.

**What shipped instead:** [LIMITS.md](LIMITS.md)'s "What genuinely doesn't work" table documents
the gap and its workaround explicitly: `docker login` yourself first, in a `pre-steps` step on the
`harness/plugin` job or a step before `run-plugin`/`plugin` if composing commands directly.

**If someone picks this up:** the `bitbucket` orb's `registry-username`/`registry-password`/
`registry-server` parameters (`env_var_name` type, resolved before `docker run`) are the exact
pattern to port. There's nothing plugin-specific blocking it; it just wasn't in scope when this
orb's four-command shape was designed.

## Limitations reassessment (2026-08)

Four cross-cutting questions came up while auditing this orb against its `cci-labs` siblings. Each
was already answered somewhere in this orb's design; this section is where that reasoning lives
now, instead of being spread across README prose a user has to hunt for.

### Image caching economics

The `default` executor's `docker_layer_caching` parameter defaults to **off**. Rule of thumb: most
Harness/Drone plugin images (`plugins/slack`, `plugins/git`, and similar single-purpose plugins)
are in the tens of megabytes and pull in low single-digit seconds, and DLC's own fixed overhead
plausibly exceeds that, so it isn't worth turning on for them. Larger plugin images (from
multi-hundred-MB to multi-GB: Android/ML/browser-class images, or a plugin that itself layers a
large base image) are where DLC's layer-level reuse (a patch-version bump often only changes the
top layer) starts to pay off over a full `docker pull` every run. There's no separate
`docker save`/`load` caching mechanism in this orb on top of DLC. It would be redundant with, and
strictly worse than (all-or-nothing per exact tag, versus DLC's per-layer reuse), a feature that
already ships. This is also a plan-gated, billed CircleCI feature; check plan eligibility before
relying on it. See [LIMITS.md](LIMITS.md)'s "Caching the plugin image" section for the current
user-facing guidance.

### Command-split decisions

`plugin` decomposes into four layered commands (`create-output-file`, `map-env`, `run-plugin`,
`collect-outputs`) specifically so a future multi-plugin chain could reuse pieces of it without a
breaking change. There's no CLI-install stage here at all (unlike the sibling `bitrise` orb), so
chaining needs no `skip-*` flags at all: each layer reads/writes plain files and env vars with no
shared state to skip, so chaining today just means giving each call its own `output-file`/
`env-file` pair and calling all four again. See
[`src/examples/chain_two_plugins.yml`](../src/examples/chain_two_plugins.yml) and
[COMMANDS.md](COMMANDS.md)'s "Commands and job reference" section for the current worked example.

### Workspace / parallelism fit

This orb's output-export mechanism (`$BASH_ENV`) is job-scoped, not stage-scoped the way Harness's
own output-variable expressions (`<+stages.STAGE_ID...>`) are, and no orb change was built to close
that gap. Passing a plugin's output value to a downstream job is already fully solved with zero
orb changes: write it to a file, `persist_to_workspace` it, `attach_workspace` downstream.
Branching which jobs run, based on an upstream job's runtime output, was considered and explicitly
not solved here. CircleCI has no native construct for a genuine workflow-level conditional at all,
orb or no orb; the closest real mechanism is a setup workflow plus the `circleci/continuation` orb,
and there is no way to do this with `harness/plugin` output alone. See
[MIGRATING.md](MIGRATING.md)'s "Passing data across jobs anyway" section for the current worked
examples of both mechanisms.

### Vendor-image layering

Checked against Harness's own docs (its FAQ states plainly: "Harness doesn't provide custom Docker
images for delegates") and the Drone Community's published base images while researching this orb:
unlike the sibling `bitrise` orb (whose Steps run bare on the executor, with nothing else providing
a toolchain) and unlike `buildkite` (where a current, permissively-licensed vendor base image
genuinely filled a real gap), every Harness/Drone plugin is already its own purpose-built image.
`run-plugin` just `docker run`s it directly, and there is no generic Harness base image to adopt on
top of that. The `harness/default` executor's only job is to have a real Docker daemon and
bind-mountable filesystem, which `machine` plus `ubuntu-2404` already gives it. There's genuinely
nothing to add here, unlike the layering decisions the other three sibling orbs each had to make.
See [ARCHITECTURE.md](ARCHITECTURE.md)'s "No vendor convenience-image executor here" note under
"Why `machine`, not `docker` + `setup_remote_docker`" for the user-facing form of this conclusion.
