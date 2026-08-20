# Harness Orb (Unofficial)

[![CircleCI Build Status](https://circleci.com/gh/CircleCI-Labs/harness-orb.svg?style=shield "CircleCI Build Status")](https://circleci.com/gh/CircleCI-Labs/harness-orb) [![CircleCI Orb Version](https://badges.circleci.com/orbs/cci-labs/harness.svg)](https://circleci.com/developer/orbs/orb/cci-labs/harness) [![GitHub License](https://img.shields.io/badge/license-MIT-lightgrey.svg)](https://raw.githubusercontent.com/CircleCI-Labs/harness-orb/main/LICENSE) [![CircleCI Community](https://img.shields.io/badge/community-CircleCI%20Discuss-343434.svg)](https://discuss.circleci.com/c/ecosystem/orbs)

The Harness Orb lets you run a single [Harness CI / Drone
plugin](https://developer.harness.io/docs/continuous-integration/use-ci/use-drone-plugins/run-a-drone-plugin-in-ci/),
one of the roughly 180+ Docker-image "Plugin" steps in the Harness/Drone ecosystem, as a single
step or job on CircleCI, with no Harness account, Drone runner, or `lite-engine`/
`drone-runner-docker` involved. It exists so a team with existing Harness/Drone plugin investments
can bring that work to CircleCI without rewriting it: the plugin's settings become `PLUGIN_*` env
vars exactly as Harness itself sets them, the plugin sees your checked-out code, and any output
variables it writes come back into `$BASH_ENV` under their real vendor names so ordinary native
CircleCI steps can read them.

---
**Disclaimer:**

CircleCI Labs, including this repo, is a collection of solutions developed by members of CircleCI's field engineering teams through our engagement with various customer needs.

-   ✅ Created by engineers @ CircleCI
-   ⚠️ **Not yet used by production CircleCI customers.** This orb is currently dev-published only. What *is* verified: a real, credential-free Drone/Harness plugin (`plugins/docker`, running privileged, doing a real nested Docker build) runs green in this repo's own CI, see `test_plugin_docker_privileged_complex_target` in `.circleci/test-deploy.yml`.
-   ❌ **not** officially supported by CircleCI support

---

## Table of contents

- [Quick start](#quick-start)
- [Capabilities](#capabilities)
- [Limits](#limits)
- [Resources](#resources)
- [How to contribute](#how-to-contribute)
- [How to publish an update](#how-to-publish-an-update)
- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): how it works, the command pipeline, the native primary-container execution model
- [docs/GETTING-STARTED.md](docs/GETTING-STARTED.md): a fuller walkthrough with more examples and executor choices
- [docs/COMMANDS.md](docs/COMMANDS.md): the complete command and job reference, every parameter
- [docs/MIGRATING.md](docs/MIGRATING.md): mapping a real Harness Plugin step onto this orb
- [docs/LIMITS.md](docs/LIMITS.md): the full limits, gotchas, and trust notes
- [docs/ROADMAP.md](docs/ROADMAP.md): items deliberately scoped out, with the reasoning kept

## Quick start

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

That runs `plugins/slack` with no Harness account, Drone runner, or `lite-engine` involved. See
[docs/GETTING-STARTED.md](docs/GETTING-STARTED.md) for more, including a Docker-in-Docker plugin
that needs `--privileged`, and interleaving native CircleCI steps around the plugin.

## Capabilities

| Command / job | What it does | Full reference |
|---|---|---|
| `plugin` (command, job) | Run one plugin via a real `docker run`: settings become `PLUGIN_*`, output lands in `$BASH_ENV`. | [docs/COMMANDS.md](docs/COMMANDS.md) |
| `create-output-file`, `map-env`, `run-plugin`, `collect-outputs` | The four commands `plugin` composes, callable individually for chaining or interleaving native steps. | [docs/COMMANDS.md](docs/COMMANDS.md) |
| `plugin-native` (command, job) | Runs a plugin image as the job's own primary container instead of via `docker run`. No `machine` VM boot, but no `--privileged` and no chaining multiple plugin images. | [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md#the-native-primary-container-path) |

See [docs/COMMANDS.md](docs/COMMANDS.md) for every parameter, and
[docs/MIGRATING.md](docs/MIGRATING.md) for how a real Harness Plugin step maps onto this orb.

## Limits

- **Job-scoped output only.** A plugin's output reaches later steps in the same job via
  `$BASH_ENV`, not a later job in the workflow. Real workarounds exist; see
  [docs/LIMITS.md](docs/LIMITS.md).
- **No `store_artifacts` default, and `store_test_results` is opt-in.** There's no vendor-wide
  Plugin-step convention to default against safely.
- **No built-in private-registry authentication.** `docker login` yourself first if your plugin
  image is private.
- **The native primary-container path can't run privileged plugins or chain two different plugin
  images in one job.** Use `plugin`/`harness/plugin` for those cases.

Full detail, the exact preflight refusal messages, and the security tradeoffs of `--privileged`
are in [docs/LIMITS.md](docs/LIMITS.md).

## Resources

[CircleCI Orb Registry Page](https://circleci.com/developer/orbs/orb/cci-labs/harness): the official registry page of this orb for all versions, executors, commands, and jobs described.

[CircleCI Orb Docs](https://circleci.com/docs/orb-intro/#section=configuration): docs for using, creating, and publishing CircleCI Orbs.

[Harness "Use Drone plugins" docs](https://developer.harness.io/docs/continuous-integration/use-ci/use-drone-plugins/run-a-drone-plugin-in-ci/): the vendor-side reference this orb's behavior is verified against.

## How to Contribute

We welcome [issues](https://github.com/CircleCI-Labs/harness-orb/issues) to and [pull requests](https://github.com/CircleCI-Labs/harness-orb/pulls) against this repository! See [docs/ROADMAP.md](docs/ROADMAP.md) for items deliberately scoped out of past passes, with the reasoning recorded rather than lost.

**CircleCI CLI version floor: `>= 1.0.48254`.** Older CLI builds silently pack this orb's `<<include(...)>>` directives as literal text instead of expanding them, producing a broken orb that can still pass `circleci orb validate`: a false green with no other symptom. Run `scripts/check-circleci-cli-version.sh` (also wired into `.circleci/config.yml`'s `lint-pack` workflow) before packing locally if you're not sure which build you have.

**`pre-steps`/`post-steps` are reserved job-parameter names.** `circleci orb validate` rejects a job parameter literally named `pre-steps` or `post-steps` outright. This only surfaces under `orb validate`, which needs a token, so a plain `circleci config validate`/pack will not catch it. If you're adding a new job parameter, don't pick either name.

## How to Publish An Update
1. Merge pull requests with desired changes to the main branch.
    - For the best experience, squash-and-merge and use [Conventional Commit Messages](https://conventionalcommits.org/).
2. Find the current version of the orb.
    - You can run `circleci orb info cci-labs/harness | grep "Latest"` to see the current version.
3. Create a [new Release](https://github.com/CircleCI-Labs/harness-orb/releases/new) on GitHub.
    - Click "Choose a tag" and _create_ a new [semantically versioned](http://semver.org/) tag. (ex: v1.0.0)
      - We will have an opportunity to change this before we publish if needed after the next step.
4.  Click _"+ Auto-generate release notes"_.
    - This will create a summary of all of the merged pull requests since the previous release.
    - If you have used _[Conventional Commit Messages](https://conventionalcommits.org/)_ it will be easy to determine what types of changes were made, allowing you to ensure the correct version tag is being published.
5. Now ensure the version tag selected is semantically accurate based on the changes included.
6. Click _"Publish Release"_.
    - This will push a new tag and trigger your publishing pipeline on CircleCI.
