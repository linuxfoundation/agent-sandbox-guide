# Agent image: everything the agent needs is baked in at build time.
# Pin the base image by digest (docker buildx imagetools inspect node:22-bookworm-slim)
# and pass an exact CLI version:
#   docker build -f docker/agent.Dockerfile --build-arg CLAUDE_CODE_VERSION=<exact-version> -t agent-image:latest .
FROM node:22-bookworm-slim

ARG CLAUDE_CODE_VERSION
RUN test -n "$CLAUDE_CODE_VERSION" || { echo "set --build-arg CLAUDE_CODE_VERSION" >&2; exit 1; }

RUN apt-get update \
 && apt-get install -y --no-install-recommends git curl ca-certificates \
 && rm -rf /var/lib/apt/lists/*
RUN npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}"

RUN useradd -m agent && mkdir -p /home/agent/work && chown agent:agent /home/agent/work
USER agent
WORKDIR /home/agent/work
