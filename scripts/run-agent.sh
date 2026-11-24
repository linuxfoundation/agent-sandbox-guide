#!/usr/bin/env bash
# Launch one coding agent (Claude Code, pi or opencode) in its own Firecracker microVM.
# See docs/03-running-agents.md and docs/07-subscription-logins.md.
# Usage: run-agent.sh <id> <ip-last-octet 10-254> <workdir> "<prompt>"
#   env: HARNESS      claude | pi | opencode (default claude)
#        AUTH         api-key (default, any harness)
#                     claude-oauth (Claude Code only: Pro/Max/Team/Enterprise via `claude setup-token`)
#                     copilot (opencode only: GitHub Copilot)
#        AGENT_IMAGE  image built with that harness (default agent-<HARNESS>:latest)
#        MODEL        model id; required for pi and opencode (e.g. from `pi --list-models anthropic`)
#        MAX_TURNS    turn limit (default 50; opencode uses agents.build.steps in its image config)
#        LIMIT        wall-clock seconds (default 3600)
set -euo pipefail
[[ $# -eq 4 ]] || { echo "usage: $0 <id> <octet> <workdir> <prompt>" >&2; exit 2; }
ID="$1"; N="$2"; WORKDIR="$3"; PROMPT="$4"
HARNESS="${HARNESS:-claude}"
AUTH="${AUTH:-api-key}"
AGENT_IMAGE="${AGENT_IMAGE:-agent-${HARNESS}:latest}"
MODEL="${MODEL:-}"
MAX_TURNS="${MAX_TURNS:-50}"; LIMIT="${LIMIT:-3600}"
LOG_DIR=/var/log/agent-sandbox/transcripts
LOG="$LOG_DIR/${ID}-${HARNESS}-$(date -u +%Y%m%dT%H%M%SZ).jsonl"

EGRESS_PROXY=http://172.30.0.2:3128
CRED_PROXY=http://172.30.0.3:8080
PLACEHOLDER=placeholder-not-a-real-credential   # never real; the credential proxy adds the credential

# Refuse to launch unless the sandbox is really there and the settings make sense
[[ -c /dev/kvm ]] || { echo "no /dev/kvm" >&2; exit 1; }
docker info --format '{{json .Runtimes}}' | grep -q '"kata-fc"' || { echo "kata-fc runtime not registered" >&2; exit 1; }
[[ "$(docker inspect -f '{{.State.Running}}' egress-proxy 2>/dev/null)" == true ]] || { echo "egress proxy down" >&2; exit 1; }
[[ "$MAX_TURNS" =~ ^[0-9]+$ && "$LIMIT" =~ ^[0-9]+$ ]] || { echo "bad MAX_TURNS/LIMIT" >&2; exit 1; }
if ! [[ "$N" =~ ^[0-9]+$ ]] || (( N < 10 || N > 254 )); then echo "octet must be 10-254" >&2; exit 1; fi
[[ -d "$WORKDIR" ]] || { echo "no such workdir: $WORKDIR" >&2; exit 1; }
case "$HARNESS" in
  claude) ;;
  pi|opencode) [[ -n "$MODEL" ]] || { echo "MODEL is required for $HARNESS" >&2; exit 1; } ;;
  *) echo "HARNESS must be claude, pi or opencode" >&2; exit 1 ;;
esac
case "$HARNESS/$AUTH" in
  */api-key|claude/claude-oauth|opencode/copilot) ;;
  pi/claude-oauth|opencode/claude-oauth)
    echo "AUTH=claude-oauth is only permitted with Claude Code (see docs/07-subscription-logins.md)" >&2; exit 1 ;;
  *) echo "AUTH=$AUTH is not supported with HARNESS=$HARNESS" >&2; exit 1 ;;
esac
mkdir -p "$LOG_DIR"

# Credential placeholder for the guest. The real credential lives only in the credential proxy.
case "$AUTH" in
  api-key)      AUTH_ENV=(-e "ANTHROPIC_API_KEY=$PLACEHOLDER"); PROVIDER=anthropic ;;
  claude-oauth) AUTH_ENV=(-e "CLAUDE_CODE_OAUTH_TOKEN=$PLACEHOLDER"); PROVIDER=anthropic ;;
  copilot)      AUTH_ENV=(-e "COPILOT_GITHUB_TOKEN=$PLACEHOLDER"); PROVIDER=github-copilot ;;
esac

# Per-harness environment and command. Model traffic goes only to the credential proxy.
HARNESS_ENV=(); CMD=()
case "$HARNESS" in
  claude)
    HARNESS_ENV=(-e "ANTHROPIC_BASE_URL=$CRED_PROXY" -e CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1)
    CMD=(claude -p "$PROMPT" --max-turns "$MAX_TURNS" --permission-mode auto
         --output-format stream-json --verbose)
    [[ -n "$MODEL" ]] && CMD+=(--model "$MODEL") ;;
  pi)
    # Base URL comes from ~/.pi/agent/models.json in the image (pi ignores ANTHROPIC_BASE_URL)
    HARNESS_ENV=(-e PI_OFFLINE=1 -e PI_TELEMETRY=0)
    CMD=(pi --mode json --no-approve --no-mcp --no-session --model "$PROVIDER/$MODEL" "$PROMPT") ;;
  opencode)
    # Base URL, step limit and web-tool denies come from /etc/opencode/opencode.json in the image
    HARNESS_ENV=(-e OPENCODE_DISABLE_MODELS_FETCH=1 -e OPENCODE_DISABLE_AUTOUPDATE=1
                 -e OPENCODE_DISABLE_PROJECT_CONFIG=1)
    CMD=(opencode run --standalone --format json -m "$PROVIDER/$MODEL" "$PROMPT") ;;
esac

# shellcheck disable=SC2329  # invoked via trap
cleanup() { docker rm -f "agent-$ID" "agent-$ID-net" >/dev/null 2>&1 || true; }
trap cleanup EXIT

# 1) Companion holds the network namespace; the microVM's NIC must exist at boot
docker run -d --name "agent-$ID-net" --network agents --ip "172.30.0.$N" busybox sleep 2147483647

# 2) Agent microVM: no mounts, no extra privileges
docker run -d --name "agent-$ID" --runtime kata-fc --network "container:agent-$ID-net" \
  --memory 4g --pids-limit 1024 --security-opt no-new-privileges \
  -e "HTTPS_PROXY=$EGRESS_PROXY" -e "HTTP_PROXY=$EGRESS_PROXY" \
  -e "NO_PROXY=localhost,127.0.0.1,::1,172.30.0.3" \
  "${AUTH_ENV[@]}" "${HARNESS_ENV[@]}" \
  "$AGENT_IMAGE" sleep infinity

# The image must match the requested harness
[[ "$(docker exec "agent-$ID" cat /etc/agent-harness)" == "$HARNESS" ]] \
  || { echo "$AGENT_IMAGE was not built with HARNESS=$HARNESS" >&2; exit 1; }

# 3) Stream the workspace in (docker cp does not work with Firecracker)
tar -C "$WORKDIR" -cf - . | docker exec -i "agent-$ID" tar -C /home/agent/work -xf -

# 4) Run with a hard wall clock; the transcript is written on the host.
#    pi has no turn limit of its own, so count its turn_end events and stop at MAX_TURNS.
#    Leaving the script removes the microVM (trap), which stops the agent inside it.
rc=0
if [[ "$HARNESS" == pi ]]; then
  timeout --kill-after=30 "$LIMIT" docker exec "agent-$ID" "${CMD[@]}" 2>&1 \
    | tee "$LOG" \
    | awk -v max="$MAX_TURNS" '/"type": *"turn_end"/ { if (++n >= max) { print "turn limit reached" > "/dev/stderr"; exit 3 } }' \
    || rc=$?
else
  timeout --kill-after=30 "$LIMIT" docker exec "agent-$ID" "${CMD[@]}" > "$LOG" 2>&1 || rc=$?
fi
echo "agent $ID ($HARNESS, $AUTH) exited with status $rc; transcript: $LOG"
exit "$rc"
