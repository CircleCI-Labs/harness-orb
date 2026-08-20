# Migrating from Harness

How to translate a real Harness CI Plugin step into this orb's config, concept by concept.

## A worked comparison

Here's a real Harness CI Plugin step (Harness's own pipeline YAML, not Drone's) next to this orb's
equivalent:

```yaml
# Harness CI pipeline.yaml (Plugin step)
- step:
    type: Plugin
    name: Notify Slack
    identifier: notify_slack
    spec:
      connectorRef: account.harnessImage
      image: plugins/slack
      settings:
        webhook: <+secrets.getValue("slack_webhook")>
        channel: dev
```

```yaml
# .circleci/config.yml (this orb)
version: 2.1
orbs:
  harness: cci-labs/harness@x.y.z
workflows:
  notify:
    jobs:
      - harness/plugin:
          image: plugins/slack
          settings: |
            webhook: $SLACK_WEBHOOK
            channel: dev
```

What actually changed, concept by concept:

- **A Harness "Plugin step" becomes a `harness/plugin` command** (inline, among native steps) **or
  job** (standalone). `spec.image` maps straight onto this orb's `image` parameter, verbatim. There
  is no version resolution on either side of the bridge.
- **`spec.settings` (a real nested YAML map) becomes this orb's flat `settings:` string**, one
  `key: value` per line. See "Settings to `PLUGIN_*`" below for exactly how each Harness type
  (scalar, boolean, list, nested map) flattens. Both sides ultimately produce the same
  `PLUGIN_<KEY>` env vars the plugin's own binary reads; Harness just hides that translation behind
  its UI and backend, while this orb makes it a parameter you write directly.
- **Where the vendor's secrets come from is the concept that changes the most.** Harness resolves
  `<+secrets.getValue("slack_webhook")>` against its own Secret Manager at pipeline-run time,
  inside Harness's SaaS control plane. There is no equivalent backend here. Put the real value in a
  CircleCI context or project environment variable instead, and reference it as plain
  `$SLACK_WEBHOOK` inside `settings:`. `map-env` resolves it via `circleci env subst` before the
  plugin container ever starts, so the secret's value never enters your committed config: the same
  security property Harness's secret-reference syntax gives you.
- **`connectorRef`** is Harness's abstraction for which credential set to pull the image with (its
  own container registry connector). This orb has no equivalent; it always does a plain,
  unauthenticated `docker pull`. If your plugin image is private, log in yourself first (a
  `pre-steps` `run: docker login ...`, or bake credentials into the executor) before
  `harness/plugin` runs. See [LIMITS.md](LIMITS.md).
- **What Harness's platform does for you that CircleCI does natively instead:** Harness's own
  stage-level artifact/test-report conventions have no fixed Plugin-step equivalent to begin with,
  so this orb deliberately doesn't default `store_artifacts`/`store_test_results` for the same
  reason Harness itself has nothing to point them at. If you know the specific plugin's own output
  path, wire your own `store_artifacts`/`store_test_results` step (or `post-steps:` on the
  `harness/plugin` job). See [LIMITS.md](LIMITS.md)'s "Artifacts and test results" for the full
  reasoning.

## Settings to `PLUGIN_*`

`settings` is a plain multi-line string (orb parameters have no map type), one `key: value` per
line:

```yaml
settings: |
  webhook: $SLACK_WEBHOOK
  channel: dev
  icon_url: https://unsplash.it/256/256/?random
  tags: latest,1.0.1,1.0
  with: {"path":"pom.xml","destination":"cie-demo-pipeline/github-action"}
```

becomes:

```
PLUGIN_WEBHOOK=<resolved value of $SLACK_WEBHOOK>
PLUGIN_CHANNEL=dev
PLUGIN_ICON_URL=https://unsplash.it/256/256/?random
PLUGIN_TAGS=latest,1.0.1,1.0
PLUGIN_WITH={"path":"pom.xml","destination":"cie-demo-pipeline/github-action"}
```

- **Scalars and kebab-case keys** are uppercased, with `-`/`.` becoming `_` (Harness's own docs:
  `PLUGIN_PATH` from `path`, `PLUGIN_REPO_URL` from `repo_url`; kebab-case is normalized the same
  way since env var names can't contain hyphens). A key that doesn't produce a legal env var name
  after this transform (one with a stray space, for example) is rejected with an error naming the
  offending settings line, rather than silently writing a broken `--env-file`.
- **Booleans** are passed through as the literal string (`true`/`false`).
- **Lists** are written as a single comma-joined string, the same convention [Harness's own
  Drone-to-Harness migration
  guide](https://developer.harness.io/docs/continuous-integration/use-ci/use-drone-plugins/run-a-drone-plugin-in-ci/#convert-drone-yaml-to-harness-yaml)
  uses.
- **Nested maps** are written by you as a literal JSON string. That already is the wire format
  (Harness itself JSON-encodes `settings.with` into a single `PLUGIN_WITH` string; well-behaved
  plugins `json.Unmarshal` it, for example `plugins/github-actions`). This is the one place a
  Harness user has to hand-translate: Harness lets you write `with:` as genuine indented nested
  YAML, but this orb's `settings` is a flat string, so you flatten it into single-line JSON
  yourself. Get a quote or comma wrong and `map-env` rejects it immediately with the offending
  settings key and value, rather than letting a malformed string reach the plugin's own
  JSON-unmarshal call, which would fail with an opaque error deep inside the vendor's binary. This
  validation only runs if `python3` is on the executor image; if it isn't, the string is passed
  through unvalidated.
- **Secrets** are referenced as `$MY_ENV_VAR`/`${MY_ENV_VAR}`, resolved at runtime against the
  job's real context/project env vars via `circleci env subst`, so the secret never appears in orb
  config.

## `CIRCLE_*` to `DRONE_*`/`HARNESS_*`

Only vars with a verified equivalent are mapped:

| CircleCI source | Drone/Harness var(s) set |
|---|---|
| `$CIRCLE_PROJECT_USERNAME` | `DRONE_REPO_OWNER` |
| `$CIRCLE_PROJECT_REPONAME` | `DRONE_REPO_NAME` |
| `$CIRCLE_PROJECT_USERNAME`/`$CIRCLE_PROJECT_REPONAME` | `DRONE_REPO` (`owner/name`) |
| `$CIRCLE_SHA1` | `DRONE_COMMIT` |
| `$CIRCLE_BRANCH` | `DRONE_COMMIT_BRANCH` |
| `$CIRCLE_BUILD_NUM` | `DRONE_BUILD_NUMBER` |
| container-workspace-path (parameter) | `DRONE_WORKSPACE`, `HARNESS_WORKSPACE` |
| container-output-file (parameter) | `DRONE_OUTPUT`, `HARNESS_OUTPUT`, `HARNESS_OUTPUT_FILE` |

Deliberately not shimmed, because no CircleCI equivalent exists without inventing one:
`DRONE_BUILD_EVENT`, `DRONE_STAGE_STATUS`, `DRONE_BUILD_STATUS`, `DRONE_FAILED_STEPS`,
`DRONE_COMMIT_AUTHOR*`, `HARNESS_ACCOUNT_ID`/`ORG_ID`/`PROJECT_ID`/`PIPELINE_ID`/`EXECUTION_ID`/
`DELEGATE_ID`, `DRONE_NETRC_*`, `DRONE_SEMVER*`/`DRONE_CALVER`.

Two further gaps are worth calling out explicitly, since these are the closest thing this orb has
to a "what doesn't work" list:

- **`HARNESS_OUTPUT_SECRET_FILE`** is not wired up. This is Harness's separate, newer,
  feature-flag-gated mechanism for output variables that Harness auto-masks as secrets in logs
  ([Output
  secrets](https://developer.harness.io/docs/continuous-integration/use-ci/use-drone-plugins/plugin-step-settings-reference/#output-secrets)).
  This orb only reads back `DRONE_OUTPUT`/`HARNESS_OUTPUT`; a plugin that writes secret-flagged
  output via `$HARNESS_OUTPUT_SECRET_FILE` has no equivalent here, and any value it does export the
  normal way lands in `$BASH_ENV` unmasked, same as everything else this orb exports verbatim.
- **Output variables are job-scoped here, not stage-scoped like Harness's.** Harness's own
  output-variable expressions work cross-stage (`<+stages.STAGE_ID...>`); this orb's mechanism
  (`$BASH_ENV`) only lives for the remainder of the current CircleCI job. A plugin's output can
  reach a later native step in the same job, but not a later CircleCI job in the same workflow.

### Passing data across jobs anyway

CircleCI has two real, native mechanisms for this. Neither needs an orb change, and the right one
depends on what you're actually trying to do:

- **Passing a plugin's output value to a downstream job** (the common case): after
  `harness/plugin` runs, write the value you need to a file and `persist_to_workspace` it, then
  `attach_workspace` in the downstream job and read the file with a plain `run` step:

  ```yaml
  - harness/plugin:
      image: plugins/slack
      settings: |
        webhook: $SLACK_WEBHOOK
  - run:
      command: echo "$OUTPUT_VAR_NAME" > /tmp/workspace/plugin-output.txt
  - persist_to_workspace:
      root: /tmp/workspace
      paths: [plugin-output.txt]
  # downstream job
  - attach_workspace:
      at: /tmp/workspace
  - run:
      command: OUTPUT_VAR_NAME="$(cat /tmp/workspace/plugin-output.txt)"; echo "$OUTPUT_VAR_NAME"
  ```

- **Branching which jobs run based on an upstream job's output** (the harder ask, a genuine
  workflow-level conditional): CircleCI has no native construct for this at all. The closest real
  mechanism is a setup workflow plus the
  [`circleci/continuation`](https://circleci.com/developer/orbs/orb/circleci/continuation) orb,
  where an early job computes a value and calls `continuation/continue` with a config whose
  `workflows:` block is shaped by that value. There is no way to do this with `harness/plugin`
  output alone. See [ROADMAP.md](ROADMAP.md)'s "Workspace / parallelism fit" for why.
