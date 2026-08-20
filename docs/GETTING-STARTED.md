# Getting started

A fuller walkthrough of `harness-orb` beyond the README's quick start: more runnable examples, how
to interleave native CircleCI steps around a plugin, and how to choose between the two execution
paths.

For the most up to date examples, visit the Orb Registry's [usage
examples](https://circleci.com/developer/orbs/orb/cci-labs/harness#usage-examples).

## Three runnable examples

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
          command: |
            echo "Plugin reported: $OUTPUT_VAR_NAME"
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

## Interleaving native CircleCI steps around the plugin

The `harness/plugin` job (only when invoked from a workflow's `jobs:` list, not the `plugin`
command inside another job's own `steps:`) accepts CircleCI's own built-in `pre-steps`/`post-steps`
arguments, available on every 2.1+ job and not something this orb declares. Pass them at the call
site:

```yaml
- harness/plugin:
    image: plugins/slack
    settings: |
      webhook: $SLACK_WEBHOOK
      channel: dev
    pre-steps:
      - run: echo "before checkout AND before the plugin container"
    post-steps:
      - run: echo "after the plugin; its outputs are already in $BASH_ENV"
```

**One real platform caveat:** `pre-steps` run before every step in the job, including this job's
own internal `checkout`, not just before the plugin. If a pre-step needs the repo checked out
first, either do that checkout yourself inside the pre-step, or use `checkout: false` on the job
plus an explicit `checkout` as the first entry of `pre-steps` so you control exactly where it lands
relative to your other pre-steps.

Need several native steps and several plugin invocations interleaved in a specific order within one
job? Reach for the `plugin` command (or the individual `create-output-file`/`map-env`/`run-plugin`/
`collect-outputs` commands) in a hand-rolled job instead. See "Chaining two plugins" in
[`src/examples/chain_two_plugins.yml`](../src/examples/chain_two_plugins.yml).

### Attaching a workspace before the plugin runs

`pre-steps` run before the job's own internal `checkout` (see the caveat just above), which happens
to be exactly the order a workspace attach needs: `attach_workspace` has to land before `checkout`,
or checkout risks clobbering files a prior job wrote into the same paths. That means the correct
CircleCI-native ordering already works today, with zero orb changes. Just put `attach_workspace` in
`pre-steps`:

```yaml
- harness/plugin:
    image: plugins/slack
    settings: |
      webhook: $SLACK_WEBHOOK
    pre-steps:
      - attach_workspace:
          at: .
```

## Choosing an executor: docker-run vs. native primary container

`harness/plugin` runs on `machine` and does a real `docker run` of the plugin image: use it when
the plugin needs `--privileged`, when you're chaining more than one plugin image in the same job, or
when you just want the well-tested default path.

`harness/plugin-native` skips the `machine` VM boot and the `docker run` entirely by giving the
plugin's own image straight to a `docker` executor as the job's primary container: use it when the
plugin needs no Docker daemon of its own, doesn't need `--privileged`, and you only need one plugin
image for the whole job. See [ARCHITECTURE.md](ARCHITECTURE.md) for how that path works and
[LIMITS.md](LIMITS.md) for exactly what it gives up in exchange.
