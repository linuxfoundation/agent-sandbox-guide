# 3. Running an agent

[← Network allowlist and logging](02-network.md) · Next: [macOS workstations →](04-macos.md)

## Choose a harness

The sandbox doesn't care which coding agent runs inside it. The image and launcher support three. Each one reaches the model only through the credential proxy, and everything else only through the egress proxy.

| | Claude Code | pi | opencode |
| --- | --- | --- | --- |
| npm package | `@anthropic-ai/claude-code` | `@earendil-works/pi-coding-agent` | `@opencode/cli` (v2) |
| Runtime | Node | Node (22.19 or later) | Bun-compiled binary |
| Headless command | `claude -p … --output-format stream-json --verbose` | `pi --mode json …` | `opencode run --standalone --format json …` |
| Turn limit | `--max-turns` | **None built in**. `run-agent.sh` counts `turn_end` events and stops the VM. | `agents.build.steps` in config |
| Approval in headless mode | `--permission-mode auto` (auto-mode classifier) | **None.** Every tool call runs. | Allow by default. `ask` rules are auto-rejected. Explicit `deny` always holds. |
| Built-in web tools | WebFetch, WebSearch (go through the egress proxy) | None (bash, MCP or extensions only) | `webfetch`, `websearch`: denied in the shipped config |
| Phone-home disabled by | `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` | `PI_OFFLINE=1`, `PI_TELEMETRY=0` | `OPENCODE_DISABLE_MODELS_FETCH=1`, `OPENCODE_DISABLE_AUTOUPDATE=1`, `"update": "disable"`, `"share": "disabled"` |

Claude Code is the only one of the three with a classifier that checks actions inside the sandbox, which the Anthropic articles recommend keeping on. With pi and opencode, the microVM and the network boundary are the only controls, so keep their allowlists especially tight.

The package names moved recently. pi was `@mariozechner/pi-coding-agent`, now deprecated. opencode v1 is still published as `opencode-ai`, but its config syntax differs from v2, and the shipped config here is v2 syntax.

## Build the agent image

Bake every tool and dependency into the image at build time. Don't fetch anything during a run.

[`docker/agent.Dockerfile`](../docker/agent.Dockerfile) installs one harness at an exact version that you pass in, together with `git`, `ripgrep` and `fd`, so pi and opencode never download those at runtime. For pi it also installs [`config/harness/pi/models.json`](../config/harness/pi/models.json), and for opencode [`config/harness/opencode/opencode.json`](../config/harness/opencode/opencode.json) as the system-level config, which overrides user and project config. Pin the base image by digest too: look it up with `docker buildx imagetools inspect node:24-bookworm-slim`.

```bash
# Find current versions
npm view @anthropic-ai/claude-code version
npm view @earendil-works/pi-coding-agent version
npm view @opencode/cli version

docker build -f docker/agent.Dockerfile --build-arg HARNESS=claude   --build-arg HARNESS_VERSION=<exact-version> -t agent-claude .
docker build -f docker/agent.Dockerfile --build-arg HARNESS=pi       --build-arg HARNESS_VERSION=<exact-version> -t agent-pi .
docker build -f docker/agent.Dockerfile --build-arg HARNESS=opencode --build-arg HARNESS_VERSION=<exact-version> -t agent-opencode .
```

pi and opencode need an explicit model ID. List them with `pi --list-models anthropic` or `opencode models anthropic` at build time, while you still have network access.

## Launch with `run-agent.sh`

[`scripts/run-agent.sh`](../scripts/run-agent.sh) does the following:

1. **Refuses to launch** unless `/dev/kvm` exists, the `kata-fc` runtime is registered, the egress proxy is running, the limits are valid numbers, and pi or opencode have a `MODEL`.
2. Starts a **companion** `busybox sleep` container on `agents` with a static IP. A microVM's network interface must exist at boot, so the agent joins this container's network namespace.
3. Starts the **agent microVM** with `--runtime kata-fc`, no mounts, a memory cap, and only proxy, placeholder-key and harness settings in its environment. It then checks that the image was built for the requested harness.
4. **Streams the workspace in** with `tar` over `docker exec` (`docker cp` doesn't work with Firecracker).
5. Runs the harness headless with a turn limit and a hard wall-clock `timeout`. The JSONL transcript is written **on the host** under `/var/log/agent-sandbox/transcripts/`.
6. Removes both containers on exit, including on error, timeout, turn limit, or Ctrl-C. Removing the microVM is what actually stops the agent.

```bash
sudo install -m 0755 scripts/run-agent.sh /usr/local/bin/run-agent.sh

run-agent.sh a1 11 ./repo "Describe the task and its scope here"                       # Claude Code
HARNESS=pi       MODEL=<model-id> run-agent.sh a2 12 ./repo "Describe the task…"
HARNESS=opencode MODEL=<model-id> run-agent.sh a3 13 ./repo "Describe the task…"
```

| Setting | Default | Meaning |
| --- | --- | --- |
| `HARNESS` | `claude` | `claude`, `pi` or `opencode` |
| `AGENT_IMAGE` | `agent-<HARNESS>:latest` | Image built for that harness |
| `MODEL` | unset | Model ID. Required for pi and opencode, optional for Claude Code. |
| `MAX_TURNS` | `50` | Turn limit. For opencode, set `agents.build.steps` in its config and rebuild instead. |
| `LIMIT` | `3600` | Wall-clock seconds before the run is killed |

Notes:

- **⚠ verify:** check that `--permission-mode auto` is accepted by your Claude Code version (`claude --help`). The articles recommend keeping auto mode on inside the sandbox and describing the sandbox to it.
- **⚠ verify:** pi's turn guard matches `"type":"turn_end"` lines in its JSON output. Check that against a real transcript from your pi version.
- opencode runs without `--auto`, so anything its config marks `ask` is rejected rather than approved.
- State scope in the prompt as intent, for example "do not access hosts outside 10.0.3.0/24". Enforce it in the network as well.
- Each VM is sized at boot as `default_memory` plus `--memory`: 4096 MiB + `4g` = 8 GiB per agent, so ten agents need about 80 GiB.
- Stop a runaway agent with `docker rm -f agent-<ID>`. An engineer should watch any network-enabled run live.
- Split work into a setup phase (internet, with a human approving each tool call) and the sandboxed run phase. Bake what setup produced into the image.

---

Next: [macOS workstations →](04-macos.md)
