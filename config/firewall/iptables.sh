#!/bin/sh
# Log and drop anything leaving the agent bridge, or aimed at the host.
# For Docker's default iptables backend. See docs/02-network.md.
# -I inserts at the top, so add DROP first, then LOG (LOG ends up above DROP).
set -eu
BR="${1:-br-agents}"

iptables -I DOCKER-USER -i "$BR" ! -o "$BR" -j DROP
iptables -I DOCKER-USER -i "$BR" ! -o "$BR" -j LOG --log-prefix "agent-egress-drop: "
iptables -I INPUT -i "$BR" -j DROP
iptables -I INPUT -i "$BR" -j LOG --log-prefix "agent-to-host-drop: "
