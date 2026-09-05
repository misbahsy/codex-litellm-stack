#!/usr/bin/env bash
# Removes the LaunchAgent that puts LITELLM_API_KEY into the macOS GUI session.
# The Codex CLI is unaffected; only the desktop app loses the key.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[[ "$(uname -s)" == "Darwin" ]] || die "macOS only; nothing to remove elsewhere"

step "Removing the desktop-app LaunchAgent"
launchctl bootout "gui/$UID/$LAUNCH_AGENT_LABEL" >/dev/null 2>&1 || true
launchctl unsetenv LITELLM_API_KEY >/dev/null 2>&1 || true
if [[ -f "$LAUNCH_AGENT_PLIST" ]]; then
  rm -f "$LAUNCH_AGENT_PLIST"
  ok "deleted $LAUNCH_AGENT_PLIST"
else
  ok "no LaunchAgent was installed"
fi
info "already-running apps keep the old value until you quit them"
