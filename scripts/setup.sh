#!/usr/bin/env bash
# One command: start the gateway, wire Codex to it, prove it works.
#
#   ./scripts/setup.sh                 # interactive
#   ./scripts/setup.sh -y              # unattended (key must already be set)
#   ./scripts/setup.sh --enterprise    # also emit an MDM-shippable config.toml
#   ./scripts/setup.sh --no-desktop    # CLI only; skip the desktop-app LaunchAgent
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ASSUME_YES=0; ENTERPRISE=0; PORT=""; GATEWAY_PUBLIC_URL=""; DESKTOP=1

usage() {
  cat <<'USAGE'
Usage: ./scripts/setup.sh [options]

  --port <n>          host port for the gateway (default 4000)
  --public-url <url>  base URL clients will use (default http://localhost:<port>)
  -y, --yes           don't prompt; fail instead of asking
  --enterprise        also write dist/config.toml for fleet distribution
  --no-desktop        skip the LaunchAgent that lets the Codex desktop app
                      see the key (macOS only; the CLI is unaffected)
  -h, --help          show this
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --port)       PORT="${2:?}"; shift 2 ;;
    --public-url) GATEWAY_PUBLIC_URL="${2:?}"; shift 2 ;;
    -y|--yes)     ASSUME_YES=1; shift ;;
    --enterprise) ENTERPRISE=1; shift ;;
    --no-desktop) DESKTOP=0; shift ;;
    -h|--help)    usage; exit 0 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

# ---------------------------------------------------------------- preflight --
step "Checking prerequisites"
require_cmd docker "Install Docker Desktop or the Docker Engine first."
require_cmd curl   "Install curl."
docker info >/dev/null 2>&1 || die "Docker is installed but not running. Start it and re-run."
compose version >/dev/null 2>&1 || die "Docker Compose v2 not available."
ok "docker + compose"
if command -v codex >/dev/null 2>&1; then
  ok "codex $(codex --version 2>/dev/null | head -n1)"
else
  warn "codex CLI not found. Install it with:  npm i -g @openai/codex"
  info "setup will still generate the config; Codex picks it up once installed"
fi

# ------------------------------------------------------------- litellm.env --
step "Configuring the gateway"
chmod 600 "$ENV_FILE"
[[ -n "$PORT" ]] && env_set LITELLM_PORT "$PORT"
[[ -n "$(env_get LITELLM_PORT)" ]] || env_set LITELLM_PORT 4000

MASTER_KEY="$(env_get LITELLM_MASTER_KEY)"
if [[ -z "$MASTER_KEY" || "$MASTER_KEY" == "sk-1234" ]]; then
  MASTER_KEY="$(gen_key)"
  env_set LITELLM_MASTER_KEY "$MASTER_KEY"
  ok "generated a fresh master key"
else
  ok "reusing existing master key"
fi

OPENAI_KEY="$(env_get OPENAI_API_KEY)"
if [[ -z "$OPENAI_KEY" || "$OPENAI_KEY" == "sk-proj-xxx" ]]; then
  (( ASSUME_YES )) && die "set OPENAI_API_KEY in docker-compose/litellm.env, or drop --yes"
  printf '  OpenAI API key: '
  read -r OPENAI_KEY || true
  [[ -n "$OPENAI_KEY" ]] || die "an OpenAI API key is required"
  env_set OPENAI_API_KEY "$OPENAI_KEY"
  ok "OPENAI_API_KEY saved to docker-compose/litellm.env"
else
  ok "OPENAI_API_KEY already set"
fi

# ------------------------------------------------------------ port conflict --
# A tunnel or dev server already on this port answers every request with a 200,
# which makes the checks below pass against the wrong server. Catch it now.
WANT_PORT="$(env_get LITELLM_PORT)"; WANT_PORT="${WANT_PORT:-4000}"
if command -v lsof >/dev/null 2>&1; then
  # `|| true`: lsof exits 1 when the port is free, and pipefail would abort here.
  HOLDER="$(lsof -nP -iTCP:"$WANT_PORT" -sTCP:LISTEN 2>/dev/null | awk 'NR==2 {print $1" (pid "$2")"}' || true)"
  if [[ -n "$HOLDER" ]] && ! compose ps --status running 2>/dev/null | grep -q litellm; then
    fail "port $WANT_PORT is already held by $HOLDER"
    info "pick another port:  ./scripts/setup.sh --port 4010"
    info "or stop that process first; do not assume it is a stale gateway"
    exit 1
  fi
fi

# -------------------------------------------------------------- bring it up --
step "Starting the gateway"
compose up -d --remove-orphans
BASE="$(gateway_url)"
printf '  waiting for %s' "$BASE"
for i in $(seq 1 60); do
  LIVE="$(curl -fsS "$BASE/health/liveliness" 2>/dev/null || true)"
  if [[ -n "$LIVE" ]]; then
    printf '\n'
    if printf '%s' "$LIVE" | grep -qi 'alive'; then
      ok "gateway is live"
    else
      fail "something on port $WANT_PORT answered, but it is not LiteLLM"
      info "it replied: $(printf '%s' "$LIVE" | head -c 120)"
      info "free the port or re-run with --port <n>"
      exit 1
    fi
    break
  fi
  printf '.'; sleep 2
  if (( i == 60 )); then
    printf '\n'; fail "gateway did not come up in 120s"
    info "logs: docker compose -f docker-compose/docker-compose.yml logs litellm --tail 50"
    exit 1
  fi
done

# ------------------------------------------------------------- virtual key --
step "Minting a Codex virtual key"
KEY_JSON="$(curl -fsS -X POST "$BASE/key/generate" \
  -H "Authorization: Bearer $MASTER_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"key_alias":"codex-cli-'"$(date +%s)"'","metadata":{"issued_by":"codex-litellm-stack"}}' \
  2>/dev/null || true)"
CODEX_KEY="$(printf '%s' "$KEY_JSON" | sed -n 's/.*"key"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
if [[ -n "$CODEX_KEY" ]]; then
  ok "virtual key issued (revoke or budget it in the LiteLLM UI)"
else
  warn "could not mint a virtual key; falling back to the master key"
  info "fine locally; for shared deployments issue per-user keys in the UI"
  CODEX_KEY="$MASTER_KEY"
fi

# --------------------------------------------------------- codex config.toml --
step "Configuring Codex"
[[ -n "$GATEWAY_PUBLIC_URL" ]] || GATEWAY_PUBLIC_URL="$BASE"
mkdir -p "$DIST_DIR"
render_toml() {
  sed -e "s|__BASE_URL__|${GATEWAY_PUBLIC_URL}/v1|g" \
      -e "s|__GENERATED_AT__|$(date -u '+%Y-%m-%dT%H:%M:%SZ')|g" \
      "$COMPOSE_DIR/codex-config.toml"
}

mkdir -p "$CODEX_HOME"
TARGET="$CODEX_HOME/config.toml"
if [[ -f "$TARGET" ]] && ! grep -q 'Codex + LiteLLM Stack' "$TARGET"; then
  BACKUP="$TARGET.bak.$(date +%Y%m%d%H%M%S)"
  if (( ASSUME_YES )); then
    cp "$TARGET" "$BACKUP"; warn "existing config backed up to $(basename "$BACKUP")"
  else
    printf '  %s already exists. Back it up and replace? [Y/n] ' "$TARGET"
    read -r ans || true
    case "${ans:-Y}" in
      [Nn]*) render_toml > "$DIST_DIR/config.toml.new"
             warn "left your config alone; wrote dist/config.toml.new for you to merge"
             TARGET="" ;;
      *) cp "$TARGET" "$BACKUP"; ok "backed up to $(basename "$BACKUP")" ;;
    esac
  fi
fi
if [[ -n "$TARGET" ]]; then
  render_toml > "$TARGET"
  ok "wrote $TARGET"
fi

# One command to start Codex with the key already in the environment.
cat > "$DIST_DIR/start-codex.sh" <<LAUNCH
#!/usr/bin/env bash
# Generated by codex-litellm-stack. Starts Codex against your gateway.
export LITELLM_API_KEY="$CODEX_KEY"
exec codex "\$@"
LAUNCH
chmod 700 "$DIST_DIR/start-codex.sh"
ok "dist/start-codex.sh"

# The CLI reads the key from the shell. The desktop app is launched by Finder,
# Dock or Spotlight, which hand it the login session's environment and nothing
# from any shell profile. A LaunchAgent writes the key into that session at
# login, so the app works from then on with no per-launch step.
if (( DESKTOP )) && [[ "$(uname -s)" == "Darwin" ]]; then
  step "Configuring the Codex desktop app"
  mkdir -p "$LAUNCH_AGENT_DIR"
  # Create it locked down before the key goes in, not after.
  : > "$LAUNCH_AGENT_PLIST"; chmod 600 "$LAUNCH_AGENT_PLIST"
  cat > "$LAUNCH_AGENT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LAUNCH_AGENT_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/launchctl</string>
    <string>setenv</string>
    <string>LITELLM_API_KEY</string>
    <string>$CODEX_KEY</string>
  </array>
  <key>RunAtLoad</key><true/>
</dict>
</plist>
PLIST

  # bootout first so a re-run replaces the old key instead of racing it
  launchctl bootout "gui/$UID/$LAUNCH_AGENT_LABEL" >/dev/null 2>&1 || true
  if launchctl bootstrap "gui/$UID" "$LAUNCH_AGENT_PLIST" >/dev/null 2>&1; then
    ok "LaunchAgent installed; the key is in the GUI session at every login"
  else
    # Older macOS, or a login session launchctl can't address from here.
    launchctl setenv LITELLM_API_KEY "$CODEX_KEY" >/dev/null 2>&1 || true
    warn "could not load the LaunchAgent; set the key for this session only"
    info "log out and back in, or run: launchctl bootstrap gui/\$UID $LAUNCH_AGENT_PLIST"
  fi

  if [[ -d /Applications/Codex.app || -d "$HOME/Applications/Codex.app" ]]; then
    info "quit and reopen Codex.app to pick it up"
  else
    info "the desktop app is not installed yet; \`codex app\` will install it"
  fi
  info "undo with: ./scripts/uninstall-desktop-env.sh"
fi

if (( ENTERPRISE )); then
  step "Enterprise artifact"
  render_toml > "$DIST_DIR/config.toml"
  ok "dist/config.toml is secret-free and ships via MDM to every laptop"
  info "each user only needs LITELLM_API_KEY in their environment"
fi

# ------------------------------------------------------------------- verify --
step "Verifying end to end"
LITELLM_API_KEY="$CODEX_KEY" "$ROOT_DIR/scripts/doctor.sh" --base "$GATEWAY_PUBLIC_URL" || {
  fail "the stack is up but the round trip failed, see above"
  exit 1
}

cat <<DONE

${BOLD}${GRN}Ready.${RST}

  ${BOLD}Start Codex:${RST}    ./dist/start-codex.sh
  ${BOLD}Or manually:${RST}    export LITELLM_API_KEY=$CODEX_KEY && codex
  ${BOLD}Desktop app:${RST}    codex app   ${DIM}(already has the key; no export needed)${RST}

  Gateway UI   $GATEWAY_PUBLIC_URL/ui   (login: any user / $MASTER_KEY)
  Any model    codex -m gpt-6-astra   |   codex --profile deep
  Model list   $GATEWAY_PUBLIC_URL/v1/models ${DIM}(what the gateway will serve)${RST}

DONE
