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

### Image caching economics (measured, 2026-08)

The `default` executor's `docker_layer_caching` parameter defaults to **off**, and this was
measured on real CircleCI rather than left as the rule-of-thumb guess this section used to make
(small images not worth it, large ones "should" pay off). Per the CircleCI Labs orb-family
caching-defaults standard (a cache defaults to `true` only where it measurably speeds up
execution, paid features included; see the sibling `act-orb`'s
[ROADMAP.md item 10](https://github.com/CircleCI-Labs/act-orb/blob/main/docs/ROADMAP.md) for the
full statement of the rule), `docker_layer_caching` is exactly the kind of paid feature that
should default `true` if the evidence supports it -- so it was tested against `plugins/docker`
(~208MB amd64/linux, one of the larger plugin images and already used elsewhere in this orb's own
test-deploy.yml), the size class this section previously predicted DLC "should" help most.

**What was measured:** two independent CircleCI pipeline runs on a branch, each pulling
`plugins/docker` once with `docker_layer_caching: false` and once with `docker_layer_caching:
true` (job numbers 686-687 and 713-714 on `CircleCI-Labs/harness-orb`):

| | DLC off | DLC on |
|---|---|---|
| Run 1 pull step | 4.64s | 4.89s |
| Run 2 pull step | 5.01s | 4.88s |
| DLC's own overhead | -- | +1.9-2.0s "Spin up environment" + 1.2-1.4s "DLC Teardown" |

**The result:** DLC produced **no measurable pull-time improvement** across two separate pipeline
runs on the same branch/image -- the second run (which should be the one that benefits from any
cross-run layer reuse) was not measurably faster than the first, and was statistically
indistinguishable from the `docker_layer_caching: false` runs. DLC also adds ~3s of its own fixed
spin-up/teardown overhead per job that a plain pull never pays, on top of being a billed,
plan-gated feature. This is the expected result, not a surprising one, once you look at the
mechanism rather than just the benchmark: DLC caches the layers a `docker build` produces. It is
built for `docker build`, not for `docker pull`, and it can only incidentally help a pull when an
image's layers already happen to be present and unchanged from an earlier build on the same host.
This orb's own workload never builds an image -- `run-plugin`/`run-plugin.sh` only `docker
pull`s and `docker run`s a pre-built vendor plugin image verbatim -- so there is no build output
for DLC to cache here, and no amount of image size shifts that. `docker_layer_caching` stays
`false` by this measurement, including for larger plugin images, correcting the previous, untested
assumption in this section that size alone would tip the balance. There's no separate `docker
save`/`load` caching mechanism in this orb; building one would only add the exact same
registry-pull-vs-cache-pull tradeoff the sibling `act-orb` measured and rejected for its own
`cache-images` parameter (see the link above). The one case where DLC would genuinely matter for a
job using this orb is a user's own `pre-steps`/`post-steps` running a real `docker build` --
outside what this orb itself does, but exactly the case DLC exists for. See
[LIMITS.md](LIMITS.md)'s "Caching the plugin image" section for the current user-facing guidance.
`docker_layer_caching` remains available as an opt-in for anyone whose own plugin image, build
steps, or network conditions differ from what was measured here.

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
