# 3. Running an agent

[← Network allowlist and logging](02-network.md) · Next: [macOS workstations →](04-macos.md)

## Build the agent image

Bake every tool and dependency into the image at build time. Don't fetch anything during a run.

[`docker/agent.Dockerfile`](../docker/agent.Dockerfile) installs the Claude Code CLI at an exact version that you pass in. Pin the base image by digest too: look it up with `docker buildx imagetools inspect node:22-bookworm-slim`.

```bash
docker build -f docker/agent.Dockerfile \
  --build-arg CLAUDE_CODE_VERSION=<exact-version> -t agent-image:latest .
```

To find the current version, run `npm view @anthropic-ai/claude-code version`.

## Launch with `run-agent.sh`

[`scripts/run-agent.sh`](../scripts/run-agent.sh) does the following:

1. **Refuses to launch** unless `/dev/kvm` exists, the `kata-fc` runtime is registered, the egress proxy is running, and the limits are valid numbers.
2. Starts a **companion** `busybox sleep` container on `agents` with a static IP. A microVM's network interface must exist at boot, so the agent joins this container's network namespace.
3. Starts the **agent microVM** with `--runtime kata-fc`, no mounts, a memory cap, and only proxy and placeholder environment variables.
4. **Streams the workspace in** with `tar` over `docker exec` (`docker cp` doesn't work with Firecracker).
5. Runs `claude -p` with `--max-turns` and a hard wall-clock `timeout`. The stream-JSON transcript is written **on the host** under `/var/log/agent-sandbox/transcripts/`.
6. Removes both containers on exit, including on error or Ctrl-C.

```bash
sudo install -m 0755 scripts/run-agent.sh /usr/local/bin/run-agent.sh
MAX_TURNS=50 LIMIT=3600 run-agent.sh a1 11 ./repo "Describe the task and its scope here"
```

| Setting | Default | Meaning |
| --- | --- | --- |
| `MAX_TURNS` | `50` | Claude Code turn limit |
| `LIMIT` | `3600` | Wall-clock seconds before the run is killed |
| `AGENT_IMAGE` | `agent-image:latest` | Image to run |

Notes:

- **⚠ verify:** check that `--permission-mode auto` is accepted by your Claude Code version (`claude --help`). The articles recommend keeping auto mode on inside the sandbox and describing the sandbox to it.
- State scope in the prompt as intent, for example "do not access hosts outside 10.0.3.0/24". Enforce it in the network as well.
- Each VM is sized at boot as `default_memory` plus `--memory`: 4096 MiB + `4g` = 8 GiB per agent, so ten agents need about 80 GiB.
- Stop a runaway agent with `docker rm -f agent-<ID>`. An engineer should watch any network-enabled run live.
- Split work into a setup phase (internet, with a human approving each tool call) and the sandboxed run phase. Bake what setup produced into the image.

---

Next: [macOS workstations →](04-macos.md)
