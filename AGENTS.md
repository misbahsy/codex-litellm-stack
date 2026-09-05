# Working in this repo

This repo puts a LiteLLM gateway between the Codex CLI and OpenAI. The gateway
holds the real OpenAI key and every request is logged and budgeted there; Codex
gets a virtual key that can be revoked without touching anything else.

If you are setting this up for someone, read `.codex/skills/` first; those
files contain the actual procedures, including the failure modes. This file
covers layout and rules only.

## How model selection works

The Codex config changes where requests go. It does not change which models
exist. There are no aliases: the gateway publishes OpenAI's model ids under
their real names plus a `"*"` catch-all, so model choice stays on the Codex
side, via `codex -m <model>` or a profile. Don't add an indirection layer
between them; it was removed deliberately.

## Layout

| Path | What it is |
|---|---|
| `scripts/setup.sh` | brings up the gateway, mints a key, writes `~/.codex/config.toml`, verifies |
| `scripts/doctor.sh` | five checks along the real request path; the source of truth for "does it work" |
| `scripts/lib.sh` | shared helpers: Compose invocation, `litellm.env` read/write |
| `scripts/uninstall-desktop-env.sh` | removes the macOS LaunchAgent that feeds the desktop app |
| `docker-compose/litellm-config.yaml` | which models the gateway serves, and their limits |
| `docker-compose/litellm.env` | **secrets.** chmod 600, never commit an edited copy |
| `docker-compose/codex-config.toml` | template for the client config; `__BASE_URL__` is substituted at setup |
| `dist/` | generated, gitignored, **contains a live credential** |
| `docs/index.html` | the landing page |

## Rules

- **Run the scripts, don't reimplement them.** `setup.sh` and `doctor.sh`
  handle port interpolation, key minting, and config backup correctly. Raw
  `docker compose` calls miss the `LITELLM_PORT` export in `lib.sh` and bind
  the wrong port.
- **Never print a key.** Not `OPENAI_API_KEY`, not `LITELLM_MASTER_KEY`, not a
  virtual key: not in a reply, a commit, a log, or a file outside
  `litellm.env` and `dist/`. Never invent one to get past a prompt.
- **`~/.codex/config.toml` belongs to the user.** Setup backs it up before
  overwriting, but say so, and offer to merge their MCP servers or sandbox
  settings back from the `.bak` file.
- **The desktop app gets its key from a LaunchAgent, not a shell.** Apps
  launched from Finder or the Dock receive the GUI login session's environment,
  so `dist/start-codex.sh` and any `export` reach the CLI only. Setup installs
  `~/Library/LaunchAgents/com.codex-litellm-stack.env.plist` for the app. It
  contains a live credential; treat it like `dist/`.
- **`down -v` deletes every issued key and all spend history** along with the
  Postgres volume. Use `restart litellm` unless a clean slate was requested.
- **Verify with a real turn.** `doctor.sh` passing is necessary, not
  sufficient. Run `codex exec` and confirm the request appears in the gateway
  logs. That's the only proof the client is going through the proxy.

## Useful commands

```bash
# state of the world
docker compose -f docker-compose/docker-compose.yml --project-directory docker-compose ps
docker compose -f docker-compose/docker-compose.yml --project-directory docker-compose logs litellm --tail 50

# what the gateway will serve
curl -s -H "Authorization: Bearer $LITELLM_API_KEY" http://localhost:4000/v1/models

# after editing litellm-config.yaml
docker compose -f docker-compose/docker-compose.yml --project-directory docker-compose restart litellm
```
