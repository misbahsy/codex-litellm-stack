---
name: codex-litellm-setup
description: Stand up the LiteLLM gateway and point the Codex CLI at it. Use when someone wants Codex running against a self-hosted gateway instead of calling OpenAI directly, or says "set up the stack", "wire Codex to LiteLLM", or "run the setup".
---

# Set up Codex against a LiteLLM gateway

You are configuring a machine so the Codex CLI sends its requests to a local
LiteLLM gateway instead of straight to OpenAI. The gateway holds the real
OpenAI key; Codex only ever sees a virtual key you can revoke.

`scripts/setup.sh` does the deterministic work. Your job is to get its inputs
right, read its output, and fix what it reports. Do not reimplement it with raw
`docker` commands; it handles port interpolation, key minting, and config backup
in ways that are easy to get subtly wrong.

## Getting the repo

You may be handed this task with nothing on disk yet.

If you are not already inside the repo, clone it and change into it:

```bash
git clone https://github.com/misbahsy/codex-litellm-stack
cd codex-litellm-stack
```

If a `codex-litellm-stack` directory already exists, work in it rather than
cloning a second copy. Confirm you are at the repo root before going on:

```bash
ls scripts/setup.sh docker-compose/docker-compose.yml
```

Every path below is relative to that root.

## Before you run anything

Check these and resolve them first, because each produces a confusing failure
several steps later:

1. **Docker is running.** `docker info` must succeed. If it doesn't, tell the
   user to start Docker Desktop; you can't start it for them on macOS.
2. **An OpenAI API key exists.** Look at `docker-compose/litellm.env`. If
   `OPENAI_API_KEY` is still `sk-proj-xxx`, ask the user for a key. **Never
   invent, guess, or reuse a key from elsewhere in the conversation**, and
   don't echo the key back in your reply once you have it.
3. **Port 4000 is free.** Run `lsof -i :4000`. If something holds it, pass
   `--port <n>` rather than killing the other process.

## Running it

```bash
./scripts/setup.sh                    # prompts for the OpenAI key if needed
./scripts/setup.sh -y                 # unattended; the key must already be in litellm.env
./scripts/setup.sh --port 4123        # different host port
./scripts/setup.sh --enterprise       # also emit the fleet config (see codex-litellm-fleet)
```

If you already wrote the key into `litellm.env` yourself, use `-y` so the
script doesn't block on a prompt you can't answer.

Setup ends by running `scripts/doctor.sh`. Read that output. The "Ready."
banner above it means the script finished, not that the connection works.

## What it changed

Say this back to the user plainly, because two of these touch files outside
the repo:

- `docker-compose/litellm.env` got a generated master key, plus the OpenAI key
  if one was entered. It is now chmod 600. Do not commit it.
- `~/.codex/config.toml` was **overwritten**. Any pre-existing config was copied
  to `config.toml.bak.<timestamp>` first. If the user had settings there they
  care about (MCP servers, sandbox policy, approval mode), offer to merge them
  back from the backup.
- `dist/start-codex.sh` exports `LITELLM_API_KEY` and launches Codex. It
  contains a live credential and is gitignored. Keep it that way.
- On macOS, `~/Library/LaunchAgents/com.codex-litellm-stack.env.plist` was
  installed and loaded. It puts `LITELLM_API_KEY` into the GUI login session at
  every login, which is the only way the Codex desktop app can see it. It holds
  the key in plaintext at chmod 600. `--no-desktop` skips it;
  `scripts/uninstall-desktop-env.sh` removes it.
- Two containers, `litellm` and `postgres`, under the compose project
  `codex-litellm-stack`.

## Verifying it actually works

Don't declare success on exit code alone. Run a real turn:

```bash
export LITELLM_API_KEY="$(sed -n 's/^export LITELLM_API_KEY=//p' dist/start-codex.sh | tr -d '"')"
codex exec "reply with the word CONNECTED and nothing else"
```

Then confirm the request reached the gateway rather than OpenAI directly:

```bash
docker compose -f docker-compose/docker-compose.yml --project-directory docker-compose \
  logs litellm --tail 20
```

You should see a POST to `/v1/responses`. If Codex answered but nothing shows
in the gateway log, `~/.codex/config.toml` isn't being read. Check whether
`CODEX_HOME` is set to somewhere else.

## The desktop app

Nothing extra to run. Setup already installed the LaunchAgent, so `codex app`
or the Dock icon works with the same config and key as the CLI.

Two things to tell the user, because both look like bugs:

- **An app that was already open won't have the key.** It kept the environment
  it launched with. Quit and reopen it.
- **A session's model is fixed when the session starts,** and a custom provider
  has no in-app model picker. `codex app -c model=gpt-6-astra` sets it at
  launch; otherwise edit `model` in `~/.codex/config.toml` and start a new
  session.

Verify without opening anything:

```bash
launchctl getenv LITELLM_API_KEY   # non-empty means the app will find it
```

If the user objects to the key sitting in the login session environment, that
is a fair objection. `./scripts/setup.sh --no-desktop` keeps it CLI-only, and
`scripts/uninstall-desktop-env.sh` undoes an install.

## Choosing models

There are no aliases to configure. The gateway publishes OpenAI's model ids
under their own names plus a `"*"` catch-all, so any model id that works
against OpenAI works here. Model choice lives entirely on the Codex side:

```bash
codex                     # the default in config.toml
codex -m gpt-6-astra      # any model, ad hoc
codex --profile deep      # a saved model + reasoning-effort pair
```

Edit `docker-compose/litellm-config.yaml` only to *restrict* what the gateway
will serve, or to attach budgets and rate limits to specific models. If you
remove the `"*"` entry, every model must then be listed explicitly.

## If something fails

Use the `codex-litellm-troubleshoot` skill. Don't guess at fixes; each
`doctor.sh` check failure names its own cause.
