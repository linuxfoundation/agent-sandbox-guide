# 7. Subscription logins: Claude Team/Enterprise and GitHub Copilot

[← Logs and retention](06-logging.md) · [Overview](../README.md)

This page covers using a subscription (an OAuth login) instead of an Anthropic API key. The sandbox rule stays the same: **the real credential lives only in the credential proxy on the host**, and the agent's VM gets a placeholder.

> Compiled 2026-11-24 from vendor docs, terms and harness source. Subscription terms change. Re-check the linked policies before you rely on this, and treat **⚠ verify** items as untested.

## What works

| Harness | Claude Pro/Max/Team/Enterprise seat | GitHub Copilot |
| --- | --- | --- |
| **Claude Code** | ✅ Supported and permitted. Use `claude setup-token` with `AUTH=claude-oauth`. | ❌ No Copilot backend. |
| **opencode** | ❌ Removed in Feb 2026 at Anthropic's request. | ✅ Officially supported by GitHub since [2026-01-16](https://github.blog/changelog/2026-01-16-github-copilot-now-supports-opencode/), for Copilot Pro, Pro+, Business and Enterprise. Use `AUTH=copilot`. |
| **pi** | ⛔ Works only by posing as Claude Code, which Anthropic's terms prohibit. Not supported here. | ⚠️ Works by posing as the VS Code Copilot client, which GitHub has not sanctioned. Not supported here. |

`run-agent.sh` enforces this matrix. It refuses `AUTH=claude-oauth` with pi or opencode, and `AUTH=copilot` with anything but opencode.

### Why pi and opencode can't use a Claude seat

Anthropic's [legal and compliance page](https://code.claude.com/docs/en/legal-and-compliance) says subscription OAuth is for "ordinary use of Claude Code and other native Anthropic applications", and that developers may not "collect, store, or intermediate" claude.ai credentials. Using an unmodified Claude Code binary with your own subscription is explicitly allowed. For pi and opencode, use an API key, workload identity federation, Bedrock or Vertex instead.

If you run Claude Code for other people (a hosted or shared sandbox rather than your own workstation), the Commercial Terms apply. Each user must log in with their own credential. Read that page before setting it up.

## Claude Code with a Claude seat (`AUTH=claude-oauth`)

**1. Check the seat.** Every Team seat includes Claude Code. On older Enterprise plans, an Owner has to assign a seat type that includes Claude Code ("Chat + Claude Code" or Premium) under Organization settings. See [Use Claude Code with your Team or Enterprise plan](https://support.claude.com/en/articles/11845131-use-claude-code-with-your-team-or-enterprise-plan).

**2. Mint the token on a trusted machine,** not in an agent VM:

```bash
claude setup-token        # opens a browser login and prints a token valid for 1 year
```

`claude setup-token` does **not** enforce a managed `forceLoginOrgUUID` setting, so it can mint a token for a different organization than you intended. Log in as the right account, and check usage shows up under the expected org.

**3. Give it to the credential proxy** the same way as an API key, with `docker exec` into a tmpfs. Never put it in an environment variable or an image. Set a reminder to rotate it before it expires, and revoke it straight away if a transcript looks suspicious.

**4. What the credential proxy must do** in this mode:

- Forward to `https://api.anthropic.com`, sending the token as `Authorization: Bearer <token>` in place of whatever the agent sent.
- **Pass the `anthropic-beta` header through unchanged.** It carries the OAuth capability. Strip it and requests fail with 401.
- Allow the extra requests Claude Code makes: `POST /v1/messages` (with `?beta=true`), `POST /v1/messages/count_tokens`, `GET /v1/models`, and `HEAD /api/hello`. Return 403 for anything else.
- The token doesn't refresh, so the proxy just holds a fixed value.

**5. Run:**

```bash
AUTH=claude-oauth run-agent.sh a1 11 ./repo "Describe the task…"
```

The agent gets `ANTHROPIC_BASE_URL` pointing at the proxy and a placeholder `CLAUDE_CODE_OAUTH_TOKEN`. In this mode the launcher deliberately does **not** set `ANTHROPIC_API_KEY`, because Claude Code would use it in preference to the OAuth token.

## opencode with GitHub Copilot (`AUTH=copilot`)

**1. Check the entitlement.** The account needs Copilot Free, a Copilot subscription, or an org seat. For Business and Enterprise, the org's Copilot policies (clients, models) still apply.

**2. Get a token on a trusted machine.** opencode sends the GitHub token directly to the Copilot API, with no exchange step. Two ways to get one:

- **Fine-grained personal access token** with the **Copilot Requests** permission. GitHub [documents these](https://docs.github.com/en/copilot/how-tos/copilot-cli/set-up-copilot-cli/authenticate-copilot-cli) for `COPILOT_GITHUB_TOKEN`. Classic `ghp_` tokens don't work. **⚠ verify** that opencode accepts a fine-grained token.
- **opencode's own login.** Run `opencode`, then `/connect` → GitHub Copilot on the trusted machine, and take the token it stores. This token comes from opencode's own OAuth app, which GitHub officially supports. **⚠ verify** where v2 stores it (`opencode debug paths` lists the locations).

GitHub OAuth tokens have no fixed expiry, but they are revoked after a year without use. Store the token in the credential proxy as above.

**3. Route Copilot traffic through the credential proxy.** opencode sends requests to `https://api.githubcopilot.com` (or `copilot-api.<domain>` for GitHub Enterprise with data residency). The paths are `/models`, `/chat/completions`, `/responses`, `/v1/messages` and `/auto`, and opencode sends GitHub version and intent headers that the proxy must pass through. There are two ways to route it:

- **Preferred, ⚠ verify:** point opencode at the proxy in [`config/harness/opencode/opencode.json`](../config/harness/opencode/opencode.json), then rebuild the image. The source suggests opencode works out the Copilot base URL itself, so this setting may be ignored. Test it.

  ```jsonc
  "providers": {
    "github-copilot": { "settings": { "baseURL": "http://172.30.0.3:8080" } }
  }
  ```

  The proxy then swaps the `Authorization: Bearer` value and forwards to `https://api.githubcopilot.com`.

- **Fallback: TLS interception.** Run the credential proxy as a TLS endpoint for `api.githubcopilot.com` with its own CA, add that CA to the agent image (`NODE_EXTRA_CA_CERTS` is supported), and have the egress proxy send that host's CONNECT to the credential proxy. This is more work, and a mistake here could put the agent on a path straight to GitHub. Run all the [verify](05-verify.md) checks again afterwards.

**Do not** fix this by allowlisting `api.githubcopilot.com` in Squid and putting the real token in the VM. That breaks the main rule of this design.

**4. Run.** `MODEL` is an opencode Copilot model ID. List them on the trusted machine with `opencode models github-copilot` (**⚠ verify** the provider ID for your version).

```bash
HARNESS=opencode AUTH=copilot MODEL=<model-id> run-agent.sh a3 13 ./repo "Describe the task…"
```

The agent gets a placeholder `COPILOT_GITHUB_TOKEN`, and the launcher runs `opencode run -m github-copilot/<model-id>`. When the token comes from the environment, opencode skips its account lookup at `api.github.com` and goes straight to `api.githubcopilot.com`. So the agent never needs to reach `api.github.com`.

## Other Claude Enterprise options for unattended runs

| Option | Billed to | Fits the proxy design |
| --- | --- | --- |
| `claude setup-token` (above) | The user's seat | Yes. Claude Code only. |
| [Workload identity federation](https://platform.claude.com/docs/en/manage-claude/workload-identity-federation) | A Claude Console API organization, per token (not seats) | Yes. The proxy holds the identity token and refreshes the short-lived access token. The guest gets a placeholder `CLAUDE_CODE_OAUTH_TOKEN`. |
| Bedrock / Vertex | Your cloud provider | Yes. The proxy signs or mints tokens. The guest gets `CLAUDE_CODE_SKIP_BEDROCK_AUTH=1` or `CLAUDE_CODE_SKIP_VERTEX_AUTH=1`. |

Whether your Enterprise contract includes a Console organization for workload identity federation is a question for your Anthropic account team. The [sandboxing article](https://support.claude.com/en/articles/17316105-agent-containment-best-practices-sandboxing-private-beta) lists what the proxy holds and what the guest gets for each of these routes.

---

[← Overview](../README.md)
