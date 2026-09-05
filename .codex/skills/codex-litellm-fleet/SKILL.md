---
name: codex-litellm-fleet
description: Produce the secret-free Codex config to distribute to a whole team via MDM, and plan the gateway deployment behind it. Use for questions about rolling Codex out company-wide, shipping config.toml to every laptop, per-user keys, or centralizing spend.
---

# Roll Codex out to a fleet

The single-machine setup and the fleet rollout differ in exactly two ways: the
gateway lives somewhere everyone can reach, and the config file that goes to
laptops contains no credential.

## Generate the artifact

```bash
./scripts/setup.sh --enterprise --public-url https://llm.internal.example.com
```

Without `--public-url` the generated config says `http://localhost:4000`, which
works on the machine that ran setup and fails on every other one. It must be a
URL an engineer's laptop can resolve.

This writes `dist/config.toml`. **Verify it carries no secret before you send
it anywhere:**

```bash
grep -Ei 'sk-|api[_-]?key *=|secret|token' dist/config.toml
```

The only credential reference should be `env_key = "LITELLM_API_KEY"`, the name
of a variable rather than a value. If that grep returns anything else, stop and
say so instead of shipping it.

## What goes where

| Artifact | Destination | Carries a secret |
|---|---|---|
| `dist/config.toml` | `~/.codex/config.toml` on every laptop, via MDM | no |
| `LITELLM_API_KEY` | each user's environment, via your secret manager | yes, one per person |
| a LaunchAgent plist | `~/Library/LaunchAgents/` on macOS, if people use the desktop app | yes, that user's key |
| `litellm.env` | the gateway host only | yes, and it never leaves the host |

Issue **one virtual key per person**. Per-user spend, rate limits, and
revocation on offboarding all depend on it:

```bash
curl -s -X POST https://llm.internal.example.com/key/generate \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H 'Content-Type: application/json' \
  -d '{"key_alias":"alice@example.com","max_budget":200,"budget_duration":"30d"}'
```

## Before you ship it

Walk the user through these. Each one is a real incident if missed:

- **The gateway is reachable and stays up.** `--public-url` assumes you already
  deployed LiteLLM somewhere. The repo's Compose file is a local dev target,
  not a production deployment; it has no TLS, no replicas, and a Postgres with
  a default password.
- **Postgres is durable.** Virtual keys and spend live there. If it's the
  container volume from this repo, a `down -v` deletes every key you issued.
- **Streaming survives the path in.** Any nginx or ALB in front of the gateway
  needs response buffering off, and an idle timeout above the longest expected
  Codex turn. Buffered SSE is the most common fleet-wide breakage and it looks
  like "Codex is slow" rather than an error.
- **Overwriting `~/.codex/config.toml` is destructive.** MDM will clobber
  whatever an engineer had: MCP servers, sandbox settings, approval policy.
  Tell people before the push, not after.
- **There's a way back.** Someone will need to bypass the gateway to debug.
  Document that `codex --profile <their own>` or a `CODEX_HOME` override lets
  them, unless you're deliberately preventing it.
- **The desktop app needs its own key delivery on macOS.** Shipping
  `config.toml` is not enough. Apps launched from the Dock or Spotlight get the
  GUI login session's environment, so a key in a shell profile or a secret
  manager's shell hook never reaches them. Telling people to run
  `launchctl setenv` themselves fails twice over: it is a command most users
  won't run, and it is gone after the next reboot. Ship a per-user LaunchAgent
  with `RunAtLoad`, the way `scripts/setup.sh` writes one locally, and have MDM
  place it with the user's own key.

## The desktop app on managed machines

`launchctl setenv` puts the key in the environment of every process in that
login session. On a shared or highly-monitored machine, say so during the
rollout rather than after. Two things keep the exposure small: issue a virtual
key with a budget rather than distributing the master key, and rotate through
the same MDM push you used to install the agent, since replacing the plist and
reloading it is all a rotation takes.

If a team decides against that exposure, the fallback is CLI-only: distribute
`config.toml`, skip the agent, and tell people to launch Codex from a terminal
where their key is already exported. They lose the desktop app.

## Restricting what the fleet can reach

The default `litellm-config.yaml` includes a `"*"` catch-all so any OpenAI
model works. For a fleet you may want the opposite. Delete that entry and list
only approved models. Requests for anything else then fail at the gateway.
