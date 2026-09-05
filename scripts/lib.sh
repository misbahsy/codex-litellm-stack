# shellcheck shell=bash
# Shared helpers for the Codex + LiteLLM stack scripts.

set -euo pipefail

if [[ -t 1 ]]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GRN=$'\033[32m'
  YLW=$'\033[33m'; CYN=$'\033[36m'; RST=$'\033[0m'
else
  BOLD=''; DIM=''; RED=''; GRN=''; YLW=''; CYN=''; RST=''
fi

step()  { printf '%s==>%s %s\n' "$CYN$BOLD" "$RST$BOLD" "$*$RST"; }
ok()    { printf '  %s✓%s %s\n' "$GRN" "$RST" "$*"; }
warn()  { printf '  %s!%s %s\n' "$YLW" "$RST" "$*"; }
fail()  { printf '  %s✗%s %s\n' "$RED" "$RST" "$*"; }
info()  { printf '    %s%s%s\n' "$DIM" "$*" "$RST"; }
die()   { fail "$*"; exit 1; }

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE_DIR="$ROOT_DIR/docker-compose"
ENV_FILE="$COMPOSE_DIR/litellm.env"
DIST_DIR="$ROOT_DIR/dist"
CODEX_HOME="${CODEX_HOME:-$HOME/.codex}"

# The Codex desktop app is launched by Finder/Dock/Spotlight, so it never sees
# anything a shell exported. A LaunchAgent puts LITELLM_API_KEY into the GUI
# login session instead, once, surviving reboots.
LAUNCH_AGENT_LABEL="com.codex-litellm-stack.env"
LAUNCH_AGENT_DIR="$HOME/Library/LaunchAgents"
LAUNCH_AGENT_PLIST="$LAUNCH_AGENT_DIR/$LAUNCH_AGENT_LABEL.plist"

# compose <args...>: normalise `docker compose` vs `docker-compose`.
# litellm.env is an env_file for the container, so Compose does NOT read it for
# ${VAR} interpolation; export LITELLM_PORT here so the published port matches.
compose() {
  local port; port="$(env_get LITELLM_PORT)"
  export LITELLM_PORT="${port:-4000}"
  if docker compose version >/dev/null 2>&1; then
    docker compose -f "$COMPOSE_DIR/docker-compose.yml" --project-directory "$COMPOSE_DIR" "$@"
  else
    docker-compose -f "$COMPOSE_DIR/docker-compose.yml" --project-directory "$COMPOSE_DIR" "$@"
  fi
}

# env_get KEY: read a value out of litellm.env without sourcing it
env_get() {
  [[ -f "$ENV_FILE" ]] || return 0
  sed -n "s/^$1=//p" "$ENV_FILE" | tail -n1 | sed 's/^"//; s/"$//'
}

# env_set KEY VALUE: idempotent upsert, keeping the file's quoted style
env_set() {
  local key="$1" val="$2" tmp
  touch "$ENV_FILE"
  tmp="$(mktemp)"
  grep -v "^${key}=" "$ENV_FILE" > "$tmp" || true
  printf '%s="%s"\n' "$key" "$val" >> "$tmp"
  mv "$tmp" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
}

gen_key() {
  printf 'sk-%s' "$(LC_ALL=C tr -dc 'a-zA-Z0-9' </dev/urandom | head -c 40)"
}

gateway_url() {
  local port; port="$(env_get LITELLM_PORT)"
  printf 'http://localhost:%s' "${port:-4000}"
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "\`$1\` not found on PATH. $2"
}
