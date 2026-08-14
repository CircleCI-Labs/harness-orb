# Harness Orb (Unofficial) [![CircleCI Build Status](https://circleci.com/gh/cci-labs/harness-orb.svg?style=shield "CircleCI Build Status")](https://circleci.com/gh/cci-labs/harness-orb) [![CircleCI Orb Version](https://badges.circleci.com/orbs/cci-labs/harness.svg)](https://circleci.com/developer/orbs/orb/cci-labs/harness) [![GitHub License](https://img.shields.io/badge/license-MIT-lightgrey.svg)](https://raw.githubusercontent.com/cci-labs/harness-orb/main/LICENSE) [![CircleCI Community](https://img.shields.io/badge/community-CircleCI%20Discuss-343434.svg)](https://discuss.circleci.com/c/ecosystem/orbs)

The Harness Orb lets you run a single [Harness CI / Drone plugin](https://developer.harness.io/docs/continuous-integration/use-ci/use-drone-plugins/run-a-drone-plugin-in-ci/) - one of the ~180+ Docker-image "Plugin" steps in the Harness/Drone ecosystem - as a single step or job on CircleCI, with no Harness account, Drone runner, or `lite-engine`/`drone-runner-docker` involved. The plugin's settings become `PLUGIN_*` env vars exactly as Harness itself sets them, the plugin sees your checked-out code, and any output variables it writes come back into `$BASH_ENV` under their real vendor names so ordinary native CircleCI steps can read them.

---
**Disclaimer:**

CircleCI Labs, including this repo, is a collection of solutions developed by members of CircleCI's field engineering teams through our engagement with various customer needs.

-   ✅ Created by engineers @ CircleCI
-   ✅ Used by real CircleCI customers
-   ❌ **not** officially supported by CircleCI support

---

## How it works

A Harness/Drone plugin's entire execution contract is `docker run -e PLUGIN_X=Y image` - confirmed directly from Harness's own [local-plugin-testing instructions](https://developer.harness.io/docs/continuous-integration/use-ci/use-drone-plugins/custom_plugins/#test-plugins-locally). This orb reduces to exactly that, decomposed into four layered commands so a future multi-plugin chain could reuse pieces of it without a breaking change:

1. **`create-output-file`** - creates the host-side file that becomes the plugin's `$DRONE_OUTPUT`/`$HARNESS_OUTPUT_FILE`.
2. **`map-env`** - turns your `settings:` block into `PLUGIN_<KEY>` env vars (case rule verified against real plugin source, not assumed), maps the CIRCLE_\* vars that have a verified DRONE_\*/HARNESS_\* equivalent, and resolves `$VAR`/`${VAR}` references at runtime via [`circleci env subst`](https://circleci.com/changelog/new-cli-command-env-subst) so secrets never sit in orb config.
3. **`run-plugin`** - the actual `docker run`, bind-mounting your checkout and the output file into the container. No failure wrapping, no retries: the plugin's own exit code and stderr reach the job unchanged.
4. **`collect-outputs`** - reads the plugin's output file back and exports every value **verbatim**, under the plugin's own key, into `$BASH_ENV`.

The `plugin` command composes all four; the `plugin` job wraps that command with `checkout` and an executor.

### Why `machine`, not `docker` + `setup_remote_docker`

Plugin containers need a real bind-mount of the checkout, and some need `--privileged`. With `setup_remote_docker`, the job's container and the Docker daemon it talks to are two separate machines - CircleCI's own docs are explicit that you can't bind-mount there, only `docker cp`. The `docker` executor and the self-hosted Container Runner also both refuse privileged containers outright. `machine` sidesteps all of it with a real bind mount and real root, at the cost of `docker` executor's per-second billing profile - exactly the tradeoff [`CircleCI-Labs/act-orb`](https://github.com/CircleCI-Labs/act-orb) already makes for the analogous GitHub Actions case.

### Settings -> `PLUGIN_*`

`settings` is a plain multi-line string (orb parameters have no map type), one `key: value` per line:

```yaml
settings: |
  webhook: $SLACK_WEBHOOK
  channel: dev
  icon-url: https://unsplash.it/256/256/?random
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

- **Scalars and kebab-case keys**: uppercased, `-`/`.` -> `_` (Harness's own docs: `PLUGIN_PATH` <- `path`, `PLUGIN_REPO_URL` <- `repo_url`; kebab-case is normalized the same way since env var names can't contain hyphens).
- **Booleans**: passed through as the literal string (`true`/`false`).
- **Lists**: written as a single comma-joined string, the same convention [Harness's own Drone-to-Harness migration guide](https://developer.harness.io/docs/continuous-integration/use-ci/use-drone-plugins/run-a-drone-plugin-in-ci/#convert-drone-yaml-to-harness-yaml) uses.
- **Nested maps**: written by you as a literal JSON string - that already *is* the wire format (Harness itself JSON-encodes `settings.with` into a single `PLUGIN_WITH` string; well-behaved plugins `json.Unmarshal` it, e.g. `plugins/github-actions`).
- **Secrets**: reference `$MY_ENV_VAR` / `${MY_ENV_VAR}` - resolved at runtime against the job's real context/project env vars via `circleci env subst`, so the secret never appears in orb config.

### CIRCLE_\* -> DRONE_\*/HARNESS_\*

Only vars with a verified equivalent are mapped: `DRONE_REPO`, `DRONE_REPO_OWNER`, `DRONE_REPO_NAME`, `DRONE_COMMIT`, `DRONE_COMMIT_BRANCH`, `DRONE_BUILD_NUMBER`, `DRONE_WORKSPACE`/`HARNESS_WORKSPACE`, `DRONE_OUTPUT`/`HARNESS_OUTPUT_FILE`. Deliberately **not** shimmed, because no CircleCI equivalent exists without inventing one: `DRONE_BUILD_EVENT`, `DRONE_STAGE_STATUS`, `DRONE_BUILD_STATUS`, `DRONE_FAILED_STEPS`, `DRONE_COMMIT_AUTHOR*`, `HARNESS_ACCOUNT_ID`/`ORG_ID`/`PROJECT_ID`/`PIPELINE_ID`/`EXECUTION_ID`/`DELEGATE_ID`, `DRONE_NETRC_*`, `DRONE_SEMVER*`/`DRONE_CALVER`.

### Workspace ownership

Plugin containers commonly run as root, so files they create in the bind-mounted workspace can be left root-owned on the host, breaking subsequent CircleCI steps. `run-plugin` reclaims ownership after every invocation - regardless of whether the plugin succeeded - trying `sudo chown` (what CircleCI's machine executor images document as available), then plain `chown`, then a throwaway container-based `chown` as a last resort, so the fix-up doesn't strictly depend on host sudo being configured.

## Features

- Run any Harness/Drone Plugin-step Docker image as one step among native CircleCI steps, or as a standalone job.
- Real vendor `PLUGIN_*` settings, verified against Harness's own docs and real plugin source - not guessed.
- Plugin output variables land in `$BASH_ENV` under their own vendor names, so a native `run` step right after can just read them.
- `--privileged` support for Docker-in-Docker plugins (e.g. `plugins/github-actions`).

## Resources

[CircleCI Orb Registry Page](https://circleci.com/developer/orbs/orb/cci-labs/harness) - the official registry page of this orb for all versions, executors, commands, and jobs described.

[CircleCI Orb Docs](https://circleci.com/docs/orb-intro/#section=configuration) - docs for using, creating, and publishing CircleCI Orbs.

[Harness "Use Drone plugins" docs](https://developer.harness.io/docs/continuous-integration/use-ci/use-drone-plugins/run-a-drone-plugin-in-ci/) - the vendor-side reference this orb's behavior is verified against.

## Examples

For the most up to date examples, please visit the Orb Registry's [usage examples](https://circleci.com/developer/orbs/orb/cci-labs/harness#usage-examples).

### Run a plugin as a job

```yaml
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

### Run a plugin inline, then read its output in a native step

```yaml
version: 2.1
orbs:
  harness: cci-labs/harness@x.y.z
jobs:
  build:
    machine:
      image: ubuntu-2404:current
    steps:
      - checkout
      - harness/plugin:
          image: plugins/slack
          settings: |
            webhook: $SLACK_WEBHOOK
            channel: dev
      - run:
          command: echo "Plugin reported: $OUTPUT_VAR_NAME"
workflows:
  main:
    jobs:
      - build
```

### A Docker-in-Docker plugin that needs `--privileged`

```yaml
version: 2.1
orbs:
  harness: cci-labs/harness@x.y.z
workflows:
  main:
    jobs:
      - harness/plugin:
          image: plugins/github-actions
          privileged: true
          settings: |
            uses: actions/hello-world-javascript-action@v1.1
            with: {"who-to-greet":"Mona the Octocat"}
```

## Legal note

This orb implements the `docker run` invocation described above purely from Harness's own public documentation and from Apache-2.0-licensed plugin images' own documentation (e.g. `drone-plugins/*`, `plugins/*`). It does not read, copy, fork, or consult the source of `harness/lite-engine` or `drone-runners/drone-runner-docker`, both of which are PolyForm-licensed specifically to prevent a competing CI product from reusing their runner engine.

## How to Contribute

We welcome [issues](https://github.com/cci-labs/harness-orb/issues) to and [pull requests](https://github.com/cci-labs/harness-orb/pulls) against this repository!

## How to Publish An Update
1. Merge pull requests with desired changes to the main branch.
    - For the best experience, squash-and-merge and use [Conventional Commit Messages](https://conventionalcommits.org/).
2. Find the current version of the orb.
    - You can run `circleci orb info cci-labs/harness | grep "Latest"` to see the current version.
3. Create a [new Release](https://github.com/cci-labs/harness-orb/releases/new) on GitHub.
    - Click "Choose a tag" and _create_ a new [semantically versioned](http://semver.org/) tag. (ex: v1.0.0)
      - We will have an opportunity to change this before we publish if needed after the next step.
4.  Click _"+ Auto-generate release notes"_.
    - This will create a summary of all of the merged pull requests since the previous release.
    - If you have used _[Conventional Commit Messages](https://conventionalcommits.org/)_ it will be easy to determine what types of changes were made, allowing you to ensure the correct version tag is being published.
5. Now ensure the version tag selected is semantically accurate based on the changes included.
6. Click _"Publish Release"_.
    - This will push a new tag and trigger your publishing pipeline on CircleCI.
