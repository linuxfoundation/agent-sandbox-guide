# 5. Verify before you trust it

[← macOS workstations](04-macos.md) · Next: [Logs and retention →](06-logging.md)

Run these on every new host, and again after any Kata, Docker, or model change. Start an agent that only sleeps, by running steps 1–3 of [`run-agent.sh`](../scripts/run-agent.sh) by hand, and set `A=agent-<ID>`.

| Check | Command | Expect |
| --- | --- | --- |
| Separate kernel | `docker exec $A uname -r; uname -r` | Different |
| Jailed Firecracker | `P=$(pgrep -n firecracker); grep -E 'Seccomp:\|NoNewPrivs' /proc/$P/status; sudo ls -l /proc/$P/ns /proc/1/ns` | `Seccomp: 2`, `NoNewPrivs: 1`, namespaces differ from PID 1 |
| No host files | `echo canary \| sudo tee /tmp/canary; docker exec $A cat /tmp/canary` | Not found |
| Model API not allowlisted | `docker exec $A curl -sS -o /dev/null -w '%{http_code}\n' https://api.anthropic.com` | Fails with CONNECT 403. `TCP_DENIED/403 … api.anthropic.com:443` in Squid log |
| Random host refused | Same command with `https://example.com` | Same: 403 plus a deny line |
| Allowlisted host works | Same command with a host from your allowlist | Connects, `TCP_TUNNEL/200` in log |
| No direct route | `docker exec $A curl --noproxy '*' -m 5 https://1.1.1.1` | Fails |
| Host access logged | `docker exec $A curl --noproxy '*' -m 5 http://172.30.0.1:22`, then `journalctl -k \| grep agent-to-host-drop` | Times out, and a log line appears (if the bridge has a host address) |
| Metadata unreachable | `docker exec $A curl -m 5 -x http://172.30.0.2:3128 http://169.254.169.254/`, then again with `--noproxy '*'` instead of `-x` (curl ignores uppercase `HTTP_PROXY`, so pass the proxy explicitly) | Proxy returns 403 and logs `TCP_DENIED`. The direct attempt fails. |
| No real credential | `docker exec $A env \| grep -Ei 'anthropic\|claude\|aws\|google\|vertex'` | Only the placeholder, proxy URLs and provider flags |
| Clean teardown | After a run: `docker ps -a; pgrep -a firecracker` | No leftover agent, companion, VM or cred-proxy |

Then:

1. Have Claude review the setup **on the host**: `configuration.toml`, `daemon.json`, `squid.conf`, the allowlist, the credential proxy, `run-agent.sh`, and the mount list.
2. Run a **supervised escape test** through the real `run-agent.sh` on a throwaway host. Name the boundary in the prompt: the host, other containers, the runtime socket, the metadata service, and non-allowlisted hosts. Read the whole transcript for proxy bypass attempts, credential or metadata reads, socket use, writes outside the workspace, and attempts to change the agent's settings.
3. Run a small batch end to end with your real credential mode (API key, Bedrock, Vertex or WIF each behave differently). Afterwards, the egress log should show only the deny lines from your probes, and the credential-proxy log only model calls.

---

Next: [Logs and retention →](06-logging.md)
