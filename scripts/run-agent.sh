#!/usr/bin/env bash
# Launch one Claude Code agent in its own Firecracker microVM. See docs/03-running-agents.md.
# Usage: run-agent.sh <id> <ip-last-octet 10-254> <workdir> "<prompt>"
#   env: MAX_TURNS (default 50), LIMIT seconds (default 3600), AGENT_IMAGE (default agent-image:latest)
set -euo pipefail
[[ $# -eq 4 ]] || { echo "usage: $0 <id> <octet> <workdir> <prompt>" >&2; exit 2; }
ID="$1"; N="$2"; WORKDIR="$3"; PROMPT="$4"
MAX_TURNS="${MAX_TURNS:-50}"; LIMIT="${LIMIT:-3600}"
AGENT_IMAGE="${AGENT_IMAGE:-agent-image:latest}"
LOG_DIR=/var/log/agent-sandbox/transcripts
LOG="$LOG_DIR/${ID}-$(date -u +%Y%m%dT%H%M%SZ).jsonl"

# Refuse to launch unless the sandbox is really there
[[ -c /dev/kvm ]] || { echo "no /dev/kvm" >&2; exit 1; }
docker info --format '{{json .Runtimes}}' | grep -q '"kata-fc"' || { echo "kata-fc runtime not registered" >&2; exit 1; }
[[ "$(docker inspect -f '{{.State.Running}}' egress-proxy 2>/dev/null)" == true ]] || { echo "egress proxy down" >&2; exit 1; }
[[ "$MAX_TURNS" =~ ^[0-9]+$ && "$LIMIT" =~ ^[0-9]+$ ]] || { echo "bad MAX_TURNS/LIMIT" >&2; exit 1; }
if ! [[ "$N" =~ ^[0-9]+$ ]] || (( N < 10 || N > 254 )); then echo "octet must be 10-254" >&2; exit 1; fi
[[ -d "$WORKDIR" ]] || { echo "no such workdir: $WORKDIR" >&2; exit 1; }
mkdir -p "$LOG_DIR"

# shellcheck disable=SC2329  # invoked via trap
cleanup() { docker rm -f "agent-$ID" "agent-$ID-net" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# 1) Companion holds the network namespace; the microVM's NIC must exist at boot
docker run -d --name "agent-$ID-net" --network agents --ip "172.30.0.$N" busybox sleep 2147483647

# 2) Agent microVM: no mounts, no extra privileges
docker run -d --name "agent-$ID" --runtime kata-fc --network "container:agent-$ID-net" \
  --memory 4g --pids-limit 1024 --security-opt no-new-privileges \
  -e HTTPS_PROXY=http://172.30.0.2:3128 -e HTTP_PROXY=http://172.30.0.2:3128 \
  -e NO_PROXY=172.30.0.3 \
  -e ANTHROPIC_BASE_URL=http://172.30.0.3:8080 -e ANTHROPIC_API_KEY=sk-placeholder-not-a-real-key \
  -e CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1 \
  "$AGENT_IMAGE" sleep infinity

# 3) Stream the workspace in (docker cp does not work with Firecracker)
tar -C "$WORKDIR" -cf - . | docker exec -i "agent-$ID" tar -C /home/agent/work -xf -

# 4) Run with a turn limit and a hard wall clock; the transcript is written on the host
rc=0
timeout --kill-after=30 "$LIMIT" \
  docker exec "agent-$ID" claude -p "$PROMPT" \
    --max-turns "$MAX_TURNS" --permission-mode auto \
    --output-format stream-json --verbose > "$LOG" 2>&1 || rc=$?
echo "agent $ID exited with status $rc; transcript: $LOG"
exit "$rc"
