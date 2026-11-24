# 6. Logs and retention (30 days or more)

[← Verify before you trust it](05-verify.md) · [Overview](../README.md)

| Source | Location |
| --- | --- |
| Agent transcripts | `/var/log/agent-sandbox/transcripts/*.jsonl` |
| Egress allow/deny | `/var/log/agent-sandbox/squid/access.log` |
| Model calls | `/var/log/agent-sandbox/credproxy/` |
| Bypass drops | `journalctl -k` (`agent-egress-drop`, `agent-to-host-drop`) |
| Runtime | `journalctl -t kata`, `journalctl -u containerd`, `journalctl -u docker` |

journald can't guarantee a minimum retention, so export the firewall drops daily to files and rotate them along with the rest:

```bash
sudo install -m 0755 config/logging/agent-kernel-log /etc/cron.daily/agent-kernel-log
sudo install -m 0644 config/logging/logrotate-agent-sandbox /etc/logrotate.d/agent-sandbox
```

- [`config/logging/agent-kernel-log`](../config/logging/agent-kernel-log) saves yesterday's drop lines from the kernel log to `/var/log/agent-sandbox/kernel/`, and deletes transcripts and kernel exports older than 45 days.
- [`config/logging/logrotate-agent-sandbox`](../config/logging/logrotate-agent-sandbox) rotates the Squid and credential-proxy logs daily and keeps 45 days.

Copy everything to an archive that agents can't reach. Review the logs during and after runs. Tell your Anthropic account team if an agent acted outside its scope.

---

[← Overview](../README.md)
