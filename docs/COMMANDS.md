# Commands and job reference

The complete command and job reference for `harness-orb`, including every parameter. See
[ARCHITECTURE.md](ARCHITECTURE.md) for how these compose, and [GETTING-STARTED.md](GETTING-STARTED.md)
for runnable examples.

## Docker-run path

| Name | Kind | What it does |
|---|---|---|
| `plugin` | command, job | The aggregate most users want: create-output-file, then map-env, then run-plugin, then collect-outputs, in order. |
| `create-output-file` | command | Creates the host-side file bind-mounted into the container as `$DRONE_OUTPUT`/`$HARNESS_OUTPUT`. Truncates on every call, so when chaining, give each plugin its own `output-file` rather than reusing one path. |
| `map-env` | command | Translates `settings:` into `PLUGIN_<KEY>` vars and the verified `CIRCLE_*` to `DRONE_*`/`HARNESS_*` subset, writes a `docker --env-file`. |
| `run-plugin` | command | The `docker run` invocation itself, with bind mounts and (optionally) `--privileged`. |
| `collect-outputs` | command | Reads the output file back and exports every value verbatim into `$BASH_ENV`. |

**Reach for the granular commands instead of the `plugin` aggregate when:** you're chaining
multiple plugins in one job (each layer reads/writes plain files and env vars with no shared state
to skip, so give each call its own `output-file`/`env-file` pair and call `create-output-file`,
`map-env`, `run-plugin`, `collect-outputs` again; see
[`src/examples/chain_two_plugins.yml`](../src/examples/chain_two_plugins.yml)), or when you want
native steps interleaved between individual stages, for example inspecting the derived `env-file`
before `run-plugin` executes.

### `plugin` (command and job) parameters

| Parameter | Type | Default | What it does |
|---|---|---|---|
| `executor` *(job only)* | executor | `default` | The executor to run the plugin container in. Must be `machine`. |
| `checkout` *(job only)* | boolean | `true` | Check out the project first. |
| `image` | string | *(required)* | The plugin's Docker image reference (for example `plugins/slack`, `plugins/slack:1.4.1`). |
| `settings` | string | `""` | Flat `key: value` block; each key becomes `PLUGIN_<KEY>`. `$VAR` resolved via `circleci env subst`. |
| `privileged` | boolean | `false` | Run the container with `--privileged` (Docker-in-Docker plugins). Requires `machine`. |
| `pull` | boolean | `true` | Run `docker pull` before `docker run`, refreshing mutable tags. |
| `workspace-path` | string | `.` | Host directory bind-mounted into the container as its workspace. |
| `container-workspace-path` | string | `/harness` | Container-side workspace path (`DRONE_WORKSPACE`/`HARNESS_WORKSPACE`). |
| `output-file` | string | `/tmp/harness-orb/output.env` | Host path capturing the plugin's output variables. |
| `container-output-file` | string | `/harness-orb-output.env` | Container-side output-file path (`DRONE_OUTPUT`/`HARNESS_OUTPUT`). |
| `env-file` | string | `/tmp/harness-orb/plugin.env` | Host path of the derived `docker --env-file`. |
| `additional-docker-flags` | string | `""` | Extra flags passed through to `docker run` verbatim. Understand what some of these cost: `--network host` removes the plugin container's network isolation, putting it on the job's own network namespace where it can reach anything bound in the job, including cloud-instance metadata endpoints. It is required only when the plugin must reach a server running inside the job container, since a sibling container on the default bridge cannot, and should not be set otherwise. Mounting the Docker socket or adding capabilities has the same character: it widens what a third-party image can reach. |
| `step-name` | string | `Run Harness plugin` | Name of the step that runs the plugin container. Override when chaining plugins so job-log steps are distinguishable. |
| `test-results-path` | string | `""` | Opt-in only. When set, runs `store_test_results` against this path after the plugin finishes. Left empty (the default), nothing runs; there's no vendor-wide default path to fall back to. |

Individual commands (`create-output-file`, `map-env`, `run-plugin`, `collect-outputs`) expose the
matching subset of these parameters under the same names. See each command's own description on the
[Orb Registry page](https://circleci.com/developer/orbs/orb/cci-labs/harness) for the exhaustive,
always-current list.

### Worked example: composing the granular commands by hand

```yaml
version: 2.1
orbs:
  harness: cci-labs/harness@x.y.z
jobs:
  notify:
    machine:
      image: ubuntu-2404:current
    steps:
      - checkout
      - harness/create-output-file
      - harness/map-env:
          settings: |
            webhook: $SLACK_WEBHOOK
            channel: dev
      - harness/run-plugin:
          image: plugins/slack
      - harness/collect-outputs
      - run: echo "plugin finished; anything it exported is already in \$BASH_ENV"
workflows:
  main:
    jobs:
      - notify
```

## Native primary-container path

See [ARCHITECTURE.md](ARCHITECTURE.md#the-native-primary-container-path) for how this path works
and why it needs a preflight check, and [LIMITS.md](LIMITS.md) for what it gives up.

| Name | Kind | What it does |
|---|---|---|
| `plugin-native` | command, job | The aggregate: preflight-native, then checkout/attach_workspace, then create-output-file, then map-env-native, then run-plugin-native, then collect-outputs. |
| `preflight-native` | command | Refuses an ineligible image with a specific reason. Runs first, always. |
| `map-env-native` | command | `settings:` to `PLUGIN_<KEY>` and the verified `CIRCLE_*` subset, exported into `$BASH_ENV`. |
| `run-plugin-native` | command | Execs `entrypoint` as an ordinary `run:` step. |
| `native` | executor | `docker` executor whose primary container is the plugin's own `image`. |

### `plugin-native` (command and job) parameters

| Parameter | Type | Default | What it does |
|---|---|---|---|
| `image` *(job only)* | string | *(required)* | The plugin's Docker image reference, becomes the job's primary container. Same verbatim, no-version-resolution contract as `plugin`'s `image` parameter. |
| `resource-class` *(job only)* | string | `medium` | Resource class for the native executor. |
| `entrypoint` | string | *(required)* | The plugin's real entrypoint command (for example `/bin/drone-slack`, `python3 /pipe.py`), vendor-chosen and arbitrary; cannot be auto-detected from inside a docker-executor primary container (no Docker daemon there to `docker inspect` with). Find it in the plugin's own Dockerfile/documentation. See [ARCHITECTURE.md](ARCHITECTURE.md#why-entrypoint-is-required-with-no-default) for why it has no default. |
| `settings` | string | `""` | Plugin settings, one `key: value` per line, identical format/rules to the `plugin` command's `settings` parameter. |
| `checkout` | boolean | `false` | Check out the project first. Defaults to `false` here (mirrored, not the same value as `plugin`'s `true`): leave it false and use `attach_workspace` against `workspace-root` unless the plugin's own image already has git/ssh/ca-certs, the stricter tier `preflight-native` enforces only when this is `true`. |
| `workspace-root` | string | `.` | Passed to `attach_workspace`'s `at` when `checkout` is `false` (the default). Ignored when `checkout` is `true`. |
| `output-file` | string | `/tmp/harness-orb/native-output.env` | Host-side (real, unmounted) path used to capture the plugin's output variables. |
| `test-results-path` | string | `""` | Opt-in only. When set, runs `store_test_results` against this path after the plugin finishes. Left empty (the default), nothing runs. |
| `step-name` | string | `Run Harness plugin (native primary container)` | Name of the step that execs the plugin's entrypoint. |

Individual commands (`preflight-native`, `map-env-native`, `run-plugin-native`) expose the matching
subset of these parameters under the same names. See each command's own description on the
[Orb Registry page](https://circleci.com/developer/orbs/orb/cci-labs/harness) for the exhaustive,
always-current list.

This is a separate job/command from `plugin`/`harness/plugin`, deliberately, never a parameter flip
on the existing one, so nobody lands in this narrower contract (no `privileged`, one image per job,
`preflight-native` gating) by accident.
