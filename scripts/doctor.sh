#!/usr/bin/env bash
# Checks whether Codex -> LiteLLM -> OpenAI works, over the same wire path Codex
# uses (/v1/responses) rather than a generic ping.
#
#   ./scripts/doctor.sh
#   LITELLM_API_KEY=sk-... ./scripts/doctor.sh --base https://llm-gw.corp.example
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE=""; MODEL="gpt-5.6-terra"; FAILURES=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --base)  BASE="${2:?}"; shift 2 ;;
    --model) MODEL="${2:?}"; shift 2 ;;
    -h|--help) printf 'Usage: ./scripts/doctor.sh [--base URL] [--model NAME]\n'; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ -n "$BASE" ]] || BASE="$(gateway_url)"
BASE="${BASE%/}"
KEY="${LITELLM_API_KEY:-$(env_get LITELLM_MASTER_KEY)}"
[[ -n "$KEY" ]] || die "no key: set LITELLM_API_KEY or run scripts/setup.sh first"

LOGS_HINT="docker compose -f docker-compose/docker-compose.yml logs litellm --tail 50"

jsonpath() { # jsonpath '<python expr>' <key-for-sed-fallback>
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "import sys,json
try: d=json.load(sys.stdin)
except Exception: sys.exit(1)
print($1)" 2>/dev/null
  else
    sed -n 's/.*"'"$2"'"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p'
  fi
}

printf '\n  %sTarget%s %s   %smodel%s %s\n\n' "$BOLD" "$RST" "$BASE" "$BOLD" "$RST" "$MODEL"

# 1. Is the gateway there at all?
step "1/5  Gateway reachable"
LIVE="$(curl -fsS --max-time 10 "$BASE/health/liveliness" 2>/dev/null || true)"
if [[ -z "$LIVE" ]]; then
  fail "cannot reach $BASE"
  info "is it running?   docker compose -f docker-compose/docker-compose.yml ps"
  info "what went wrong? $LOGS_HINT"
  exit 1
fi
# Something answered, but is it ours? A tunnel, dev server or stray proxy on
# this port will happily return 200 to everything and make checks 2 and 4 lie.
if ! printf '%s' "$LIVE" | grep -qi 'alive'; then
  fail "something is listening on $BASE, but it is not LiteLLM"
  info "it replied: $(printf '%s' "$LIVE" | head -c 120)"
  info "another process is holding that port. Find it with:"
  info "  lsof -nP -iTCP:${BASE##*:} -sTCP:LISTEN"
  info "then re-run setup on a free port:  ./scripts/setup.sh --port 4010"
  exit 1
fi
ok "$BASE responds"

# 2. Is the key accepted?
step "2/5  Key accepted"
CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 \
  -H "Authorization: Bearer $KEY" "$BASE/v1/models")"
case "$CODE" in
  200) ok "authenticated (HTTP 200)" ;;
  401|403) fail "gateway rejected the key (HTTP $CODE)"
           info "regenerate one: ./scripts/setup.sh"
           exit 1 ;;
  *) fail "unexpected HTTP $CODE from /v1/models"; FAILURES=$((FAILURES+1)) ;;
esac

# 3. Does the model Codex asks for exist on the gateway?
step "3/5  Model published"
MODELS="$(curl -fsS --max-time 15 -H "Authorization: Bearer $KEY" "$BASE/v1/models" 2>/dev/null || true)"
if printf '%s' "$MODELS" | grep -q "\"$MODEL\""; then
  ok "'$MODEL' is served by the gateway"
  AVAIL="$(printf '%s' "$MODELS" | jsonpath '", ".join(m["id"] for m in d.get("data",[]))' id | head -c 200)"
  [[ -n "$AVAIL" ]] && info "available: $AVAIL"
else
  fail "'$MODEL' is not in the gateway's model list"
  info "add it to model_list in docker-compose/litellm-config.yaml, or keep the"
  info "\"*\" catch-all entry so any OpenAI model id passes through"
  AVAIL="$(printf '%s' "$MODELS" | jsonpath '", ".join(m["id"] for m in d.get("data",[]))' id | head -c 200)"
  [[ -n "$AVAIL" ]] && info "currently listed: $AVAIL"
  FAILURES=$((FAILURES+1))
fi

# 4. A /v1/responses round trip to OpenAI, the call Codex actually makes.
step "4/5  Provider round trip (/v1/responses)"
BODY="$(curl -s --max-time 90 -w '\n%{http_code}' -X POST "$BASE/v1/responses" \
  -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"model":"'"$MODEL"'","input":"Reply with exactly: PONG","max_output_tokens":32}' 2>/dev/null)"
HTTP="$(printf '%s' "$BODY" | tail -n1)"
JSON="$(printf '%s' "$BODY" | sed '$d')"
TEXT=""
[[ "$HTTP" == "200" ]] && TEXT="$(printf '%s' "$JSON" | jsonpath '"".join(c.get("text","") for o in d.get("output",[]) for c in o.get("content",[]))' text)"
if [[ "$HTTP" == "200" && -n "$TEXT" ]]; then
  ok "OpenAI replied: ${TEXT:0:60}"
elif [[ "$HTTP" == "200" ]]; then
  fail "HTTP 200 but the response carried no output"
  info "$(printf '%s' "$JSON" | head -c 200)"
  info "an empty 200 usually means something other than LiteLLM answered"
  FAILURES=$((FAILURES+1))
else
  fail "round trip failed (HTTP $HTTP)"
  ERR="$(printf '%s' "$JSON" | head -c 400)"
  [[ -n "$ERR" ]] && info "$ERR"
  case "$HTTP" in
    400) info "usually a model name that doesn't exist upstream" ;;
    401|403) info "OpenAI rejected the key. Check OPENAI_API_KEY in docker-compose/litellm.env" ;;
    404) info "the gateway accepted the name, but OpenAI has no such model" ;;
    429) info "rate limited or out of quota on the OpenAI account" ;;
    5*)  info "upstream error. $LOGS_HINT" ;;
  esac
  FAILURES=$((FAILURES+1))
fi

# 5. Streaming, because Codex streams every turn.
step "5/5  Streaming"
STREAM="$(curl -s --max-time 90 -N -X POST "$BASE/v1/responses" \
  -H "Authorization: Bearer $KEY" -H 'Content-Type: application/json' \
  -d '{"model":"'"$MODEL"'","input":"Count: 1 2 3","stream":true,"max_output_tokens":32}' 2>/dev/null | head -c 4000)"
if printf '%s' "$STREAM" | grep -q '^data:'; then
  ok "SSE stream flowing"
else
  fail "no SSE frames received"
  info "Codex will hang on every turn until this passes"
  FAILURES=$((FAILURES+1))
fi

# Client-side config. The gateway can be fine and Codex still not be pointed at it.
step "Codex client config"
TOML="$CODEX_HOME/config.toml"
if [[ -f "$TOML" ]]; then
  if grep -q "base_url *= *\"$BASE/v1\"" "$TOML"; then
    ok "config.toml points at $BASE/v1"
  else
    warn "config.toml base_url doesn't match $BASE/v1"
    info "$(grep -m1 'base_url' "$TOML" || echo '(no base_url found)')"
  fi
  grep -q 'wire_api *= *"responses"' "$TOML" && ok 'wire_api = "responses"' || warn 'wire_api is not "responses"'
else
  warn "no $TOML. Run ./scripts/setup.sh"
fi
if [[ -n "${LITELLM_API_KEY:-}" ]]; then ok "LITELLM_API_KEY is exported"
else warn "LITELLM_API_KEY not exported. Use ./dist/start-codex.sh"; fi

# The desktop app is a separate delivery path for the same key. Finder, Dock and
# Spotlight give an app the GUI login session's environment, never a shell's, so
# an exported key reaches the CLI and not the app.
if [[ "$(uname -s)" == "Darwin" ]]; then
  step "Codex desktop app"
  GUI_KEY="$(launchctl getenv LITELLM_API_KEY 2>/dev/null || true)"
  if [[ -z "$GUI_KEY" ]]; then
    if [[ -f "$LAUNCH_AGENT_PLIST" ]]; then
      warn "the LaunchAgent exists but has not run in this login session"
      info "log out and back in, or: launchctl bootstrap gui/\$UID $LAUNCH_AGENT_PLIST"
    else
      warn "the desktop app has no key; only the CLI will work"
      info "install it once with: ./scripts/setup.sh"
    fi
  elif [[ "$GUI_KEY" == "$KEY" ]]; then
    ok "the GUI session carries the same key the CLI is using"
  else
    warn "the GUI session carries a different key than this check is using"
    info "re-run ./scripts/setup.sh to put the current key in both places"
    info "then quit and reopen Codex.app"
  fi
fi

printf '\n'
if (( FAILURES == 0 )); then
  printf '  %s%sAll checks passed.%s Codex is wired to your gateway.\n\n' "$BOLD" "$GRN" "$RST"
  exit 0
fi
printf '  %s%s%d check(s) failed.%s\n\n' "$BOLD" "$RED" "$FAILURES" "$RST"
exit 1
