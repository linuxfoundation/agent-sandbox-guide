# 2. Network: allowlist, credential proxy, and logging

[← Linux host setup](01-linux-host.md) · Next: [Running an agent →](03-running-agents.md)

## Networks

```bash
docker network create --internal \
  -o com.docker.network.bridge.name=br-agents --subnet 172.30.0.0/24 agents
docker network create -o com.docker.network.bridge.name=br-egress egress
sudo mkdir -p /etc/agent-sandbox /var/log/agent-sandbox/{squid,credproxy,transcripts,kernel}
```

MicroVM guests can't reach Docker's embedded DNS. Give proxies and in-scope targets **static IPs** and pass them as IPs. The proxies resolve names themselves.

| Address | Role |
| --- | --- |
| `172.30.0.2` | Egress proxy (Squid, port 3128) |
| `172.30.0.3` | Credential proxy (port 8080) |
| `172.30.0.10`–`.254` | Agent companions, one per running agent |

## Egress proxy (Squid)

Files:

- [`config/squid/squid.conf`](../config/squid/squid.conf): denies everything by default, allows CONNECT only to allowlisted hosts on allowed ports, blocks localhost and link-local (cloud metadata), and logs one line per request.
- [`config/squid/allowlist-443.txt`](../config/squid/allowlist-443.txt): one host per line. It starts empty. Add only what the engagement needs, such as a package mirror or an in-scope target. Prefix a name with `.` to include its subdomains.

**Do not add the model-API host** (`api.anthropic.com`, a Bedrock endpoint, or a Vertex endpoint). Agents reach the model only through the credential proxy.

Notes on the config:

- `dstdomain -n` stops Squid from doing reverse-DNS lookups on raw-IP requests. Without it, an attacker who controls the PTR record for their own IP could make it match an allowlisted name.
- Refused requests are logged as `TCP_DENIED/403`. For CONNECT, the URL field is the `host:port` that was asked for.
- Squid can't pair hosts with ports in one ACL. For another port, add an `allowlist-<port>.txt` and the matching `acl` and `http_access` lines (commented examples are in the config).
- If in-scope targets don't live on private ranges, also deny `10.0.0.0/8 172.16.0.0/12 192.168.0.0/16` with a `dst` ACL.
- Squid matches the CONNECT target, not the TLS SNI, so domain fronting through an allowlisted CDN is still possible. Fixing that needs `ssl_bump peek` and `ssl::server_name`.

Install the config and run the proxy on both networks. Pin the image by digest: look it up with `docker buildx imagetools inspect ubuntu/squid:latest`, then use `ubuntu/squid@sha256:…`.

```bash
sudo install -m 0644 config/squid/squid.conf config/squid/allowlist-443.txt /etc/agent-sandbox/

docker create --name egress-proxy --network egress --restart unless-stopped \
  --read-only --tmpfs /var/spool/squid --tmpfs /run \
  -v /etc/agent-sandbox/squid.conf:/etc/squid/squid.conf:ro \
  -v /etc/agent-sandbox/allowlist-443.txt:/etc/squid/allowlist-443.txt:ro \
  -v /var/log/agent-sandbox/squid:/var/log/squid \
  ubuntu/squid:latest                      # replace with @sha256 digest
docker network connect --ip 172.30.0.2 agents egress-proxy
docker start egress-proxy
docker exec egress-proxy squid -k parse && docker exec egress-proxy squid -k check
```

When you change the allowlist, `docker restart egress-proxy`. This drops live connections, so do it **between batches**. Then confirm what loaded with `docker exec egress-proxy cat /etc/squid/allowlist-443.txt`.

## Credential proxy (brief)

This is a small HTTP forwarder that **you supply**. The [sandboxing article](https://support.claude.com/en/articles/17316105-agent-containment-best-practices-sandboxing-private-beta) gives the full spec. Its key properties:

- A separate **runc** container on `agents` (172.30.0.3) and `egress`, with `--read-only` and `--cap-drop ALL` (add back only what it needs).
- It forwards only model-API paths to the configured provider over verified HTTPS. Anything else gets a 403.
- It strips incoming auth headers and adds the real credential.
- It logs **one line per request**: client, method, path, status, and size. No headers or bodies. Write the log to `/var/log/agent-sandbox/credproxy/`.
- Deliver the key with `docker exec` into a tmpfs, never through env or argv. For example:
  `docker exec -i cred-proxy sh -c 'cat > /run/secret/key' < key-file`.
- Start one per launch, remove it after the run, and check for leftovers. Use a narrowly scoped key and rotate it after any suspicious transcript.

The agent container gets only:

```bash
ANTHROPIC_BASE_URL=http://172.30.0.3:8080
ANTHROPIC_API_KEY=sk-placeholder-not-a-real-key
CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1
```

For Bedrock or Vertex, the agent gets `CLAUDE_CODE_SKIP_BEDROCK_AUTH=1` or `CLAUDE_CODE_SKIP_VERTEX_AUTH=1` plus `AWS_REGION` or `CLOUD_ML_REGION`. For Vertex, limit the proxy to `:rawPredict`, `:streamRawPredict` and `:countTokens`, and use an IAM role that holds only `aiplatform.endpoints.predict`.

## Host firewall: log and drop bypass attempts

The `--internal` bridge already has no route out. These rules add a logged drop as a second layer, which catches anything that leaves `br-agents` or targets the host.

With Docker's default iptables backend, run [`config/firewall/iptables.sh`](../config/firewall/iptables.sh) and persist the rules with iptables-persistent or your config management:

```bash
sudo sh config/firewall/iptables.sh
```

If Docker uses `"firewall-backend": "nftables"`, there is no `DOCKER-USER` chain. Load [`config/firewall/agent-egress.nft`](../config/firewall/agent-egress.nft) instead. It uses its own table that runs before Docker's:

```bash
sudo nft -f config/firewall/agent-egress.nft
```

Read the drops with `journalctl -k | grep -E 'agent-(egress|to-host)-drop'`. Guest-to-proxy traffic stays on the bridge, so it doesn't hit these rules. Squid logs it instead. **⚠ verify:** test on your host that Kata guest traffic reaches these hooks ([Verify](05-verify.md)).

---

Next: [Running an agent →](03-running-agents.md)
