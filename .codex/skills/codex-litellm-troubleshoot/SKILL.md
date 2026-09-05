---
name: codex-litellm-troubleshoot
description: Diagnose a Codex CLI that won't reach its LiteLLM gateway: connection refused, 401s, model not found, hanging streams, or requests bypassing the gateway. Use when setup failed, doctor.sh reports a failure, or Codex errors after previously working.
---

# Diagnose Codex ↔ LiteLLM

Start here, always:

```bash
./scripts/doctor.sh
./scripts/doctor.sh --model gpt-6-astra --base http://localhost:4123   # non-defaults
```

The five checks run in dependency order along the real request path. **Fix the
first failure and re-run.** A later check failing is usually a symptom of an
earlier one, and chasing check 5 while check 2 is red wastes the user's time.

## Reading each failure

**1 · Gateway reachable.** Nothing is listening on that port.

```bash
docker compose -f docker-compose/docker-compose.yml --project-directory docker-compose ps
docker compose -f docker-compose/docker-compose.yml --project-directory docker-compose logs litellm --tail 50
```

If the container is up but the port is wrong, check `LITELLM_PORT` in
`litellm.env`. Compose does *not* read `litellm.env` for `${VAR}` substitution;
it's an `env_file` for the container. `scripts/lib.sh` exports the port before
invoking Compose, which is why you should go through the scripts rather than
calling `docker compose` directly.

If the container is restarting, it's almost always a malformed
`litellm-config.yaml`. The logs name the line.

**2 · Key accepted.** The gateway is up but rejected the credential.
`LITELLM_API_KEY` is unset, stale, or was revoked. Mint a fresh one:

```bash
MASTER=$(sed -n 's/^LITELLM_MASTER_KEY=//p' docker-compose/litellm.env | tr -d '"')
curl -s -X POST http://localhost:4000/key/generate \
  -H "Authorization: Bearer $MASTER" -H 'Content-Type: application/json' \
  -d '{"key_alias":"codex-cli-manual"}'
```

**3 · Model published.** The id Codex asked for isn't served. Either add it to
`model_list` in `docker-compose/litellm-config.yaml`, or confirm the `"*"`
catch-all entry is still present. After editing, restart the gateway:
`docker compose -f docker-compose/docker-compose.yml --project-directory docker-compose restart litellm`.

**4 · Provider round trip.** The gateway is fine; OpenAI rejected the call. The
HTTP code tells you which:

| Code | Cause | Fix |
|---|---|---|
| 401 / 403 | `OPENAI_API_KEY` invalid, revoked, or wrong org | replace it in `litellm.env`, restart |
| 404 | model id doesn't exist upstream | check spelling against OpenAI's model list |
| 429 | rate limited or out of quota | check billing; add `rpm`/`tpm` limits in `litellm-config.yaml` |
| 5xx | upstream fault | retry; if persistent, read the gateway logs for the raw error |

**5 · Streaming.** Non-streaming worked but SSE frames didn't arrive. Every
Codex turn streams, so this one is not optional. Look for a proxy, VPN, or
corporate TLS interceptor buffering the response. If the gateway is remote, an
nginx or ALB in front of it needs response buffering turned off.

## Failures doctor.sh can't see

**Codex hangs mid-turn, then errors.** The client gave up before the model
finished. Raise `stream_idle_timeout_ms` in `~/.codex/config.toml` (the
generated value is 7200000, two hours) and confirm `request_timeout` in
`litellm-config.yaml` is at least as generous.

**Codex works but nothing appears in the gateway logs.** Requests are going
straight to OpenAI. Check, in order: `CODEX_HOME` pointing elsewhere;
`model_provider` not set to `litellm` in `config.toml`; an `OPENAI_API_KEY` in
the user's shell that Codex prefers; or a `--profile` whose provider differs.

**The CLI works but the desktop app says the key is missing.** Expected, and
not a config problem. Finder, the Dock and Spotlight give an app the GUI login
session's environment, so nothing a shell exported reaches it. Check what the
GUI session actually has:

```bash
launchctl getenv LITELLM_API_KEY          # empty means the app sees nothing
ls -l ~/Library/LaunchAgents/com.codex-litellm-stack.env.plist
```

If the plist is missing, re-run `./scripts/setup.sh`. If it exists but
`getenv` is empty, it hasn't been loaded in this session:
`launchctl bootstrap gui/$UID ~/Library/LaunchAgents/com.codex-litellm-stack.env.plist`.
If `getenv` returns a key but the app still fails, the app is older than the
key; quit and reopen it, since it kept the environment it started with.

**The desktop app is stuck on one model.** Codex fixes a session's model when
the session is created, and with a custom provider there is no in-app picker
(openai/codex#15364). Change `model` in `~/.codex/config.toml` and start a new
session, or launch with an override: `codex app -c model=gpt-6-astra`.

**"Unsupported wire API" or malformed responses.** `wire_api` must be
`"responses"`. LiteLLM serves `/v1/responses` natively and bridges providers
that lack it, so don't switch this to `"chat"` to work around a different bug.

**Everything passes but Codex still fails.** Compare what Codex sends against
what you tested:

```bash
codex exec --profile deep "say OK" 2>&1 | tail -20
```

Profiles override the model *and* the provider. A profile pointing at a model
the gateway doesn't serve fails while the default works fine.

## Rules

- Never print or paste `OPENAI_API_KEY`, `LITELLM_MASTER_KEY`, or a virtual key
  into your reply, a commit, or a file outside `litellm.env` / `dist/`.
- Prefer `restart litellm` over `down -v`. **`down -v` destroys the Postgres
  volume**, taking every issued virtual key and all spend history with it. Only
  do that if the user asks for a clean slate.
- Report what you actually observed, including which checks are still failing.
  A partially working gateway described as working costs more time than the
  original bug.
