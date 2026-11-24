# Agent image: everything the agent needs is baked in at build time. See docs/03-running-agents.md.
# Pin the base image by digest (docker buildx imagetools inspect node:24-bookworm-slim)
# and pass a harness plus its exact version:
#   docker build -f docker/agent.Dockerfile \
#     --build-arg HARNESS=claude --build-arg HARNESS_VERSION=<exact-version> -t agent-claude .
#   HARNESS: claude | pi | opencode
FROM node:24-bookworm-slim

ARG HARNESS=claude
ARG HARNESS_VERSION
RUN test -n "$HARNESS_VERSION" || { echo "set --build-arg HARNESS_VERSION" >&2; exit 1; }

# ripgrep and fd are installed up front so pi and opencode never download them at runtime
RUN apt-get update \
 && apt-get install -y --no-install-recommends git curl ca-certificates ripgrep fd-find \
 && rm -rf /var/lib/apt/lists/*

RUN useradd -m agent && mkdir -p /home/agent/work && chown agent:agent /home/agent/work
COPY config/harness/ /opt/harness-config/

RUN set -eu; \
    case "$HARNESS" in \
      claude) \
        npm install -g "@anthropic-ai/claude-code@${HARNESS_VERSION}" ;; \
      pi) \
        npm install -g --ignore-scripts "@earendil-works/pi-coding-agent@${HARNESS_VERSION}"; \
        install -d -o agent -g agent /home/agent/.pi/agent; \
        install -m 0644 -o agent -g agent /opt/harness-config/pi/models.json /home/agent/.pi/agent/models.json ;; \
      opencode) \
        npm install -g "@opencode/cli@${HARNESS_VERSION}"; \
        install -D -m 0644 /opt/harness-config/opencode/opencode.json /etc/opencode/opencode.json ;; \
      *) echo "unknown HARNESS: $HARNESS (claude|pi|opencode)" >&2; exit 1 ;; \
    esac; \
    echo "$HARNESS" > /etc/agent-harness

USER agent
WORKDIR /home/agent/work
