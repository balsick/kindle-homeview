#!/bin/sh
# Copies to the clipboard the environment variables for a Claude Code cloud
# environment, so a cloud session can see the local configuration that's kept
# out of git:
#   KINDLE_CONFIG_SH  kindle/config.sh, in base64
#   HOME_CONFIG_H     arduino/kindle_gateway/home_config.h, in base64
#
# Secrets stay out: arduino_secrets.h and kindle/qr/ aren't read, and lines
# that look like passwords, tokens or the home's coordinates are dropped.
#
#   tools/cloud_env.sh           copies to the clipboard
#   tools/cloud_env.sh --print   prints instead (to check what goes out)

set -e
cd "$(dirname "$0")/.."

# Lines that must not leave the computer
strip() { grep -v -i -e 'pass' -e 'token' -e 'secret' -e 'LATITUDE' -e 'LONGITUDE' "$1" || true; }

# base64 on one line: GNU wants -w0, macOS doesn't wrap anyway
b64() { base64 | tr -d '\n'; }

env_lines() {
  local found=0
  if [ -f kindle/config.sh ]; then
    printf 'KINDLE_CONFIG_SH=%s\n' "$(strip kindle/config.sh | b64)"
    found=1
  else
    echo "kindle/config.sh not found: skipped" >&2
  fi
  if [ -f arduino/kindle_gateway/home_config.h ]; then
    printf 'HOME_CONFIG_H=%s\n' "$(strip arduino/kindle_gateway/home_config.h | b64)"
    found=1
  else
    echo "arduino/kindle_gateway/home_config.h not found: skipped" >&2
  fi
  [ $found = 1 ] || { echo "Nothing to copy" >&2; exit 1; }
}

if [ "$1" = --print ]; then
  env_lines
  exit 0
fi

out=$(env_lines)
if which pbcopy >/dev/null 2>&1; then printf '%s\n' "$out" | pbcopy
elif which wl-copy >/dev/null 2>&1; then printf '%s\n' "$out" | wl-copy
elif which xclip >/dev/null 2>&1; then printf '%s\n' "$out" | xclip -selection clipboard
elif which clip.exe >/dev/null 2>&1; then printf '%s\n' "$out" | clip.exe
else
  echo "No clipboard tool found (pbcopy, wl-copy, xclip, clip.exe): here they are" >&2
  printf '%s\n' "$out"
  exit 0
fi
echo "Copied $(printf '%s\n' "$out" | wc -l | tr -d ' ') variables: paste them into the cloud environment's variables (Edit)."
