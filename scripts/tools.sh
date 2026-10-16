#!/usr/bin/env sh
# Fetch the lint/format tools into deps/ (gitignored).
#
# Versions are pinned: `make format-check` is only meaningful if the tool that
# produced the formatting is pinned too.  Anything already present is left
# alone, so calling this on every `make` target is cheap.
set -eu

STYLUA_VERSION=v2.3.1
LUACHECK_VERSION=v1.2.0

root=$(cd "$(dirname "$0")/.." && pwd)
deps="$root/deps"
mkdir -p "$deps"

fail() {
  printf 'vcssign tools: %s\n' "$1" >&2
  exit 1
}

case "$(uname -s)" in
  MINGW* | MSYS* | CYGWIN*)
    asset=stylua-windows-x86_64.zip
    exe=.exe
    windows=yes
    ;;
  Darwin)
    if [ "$(uname -m)" = arm64 ]; then
      asset=stylua-macos-aarch64.zip
    else
      asset=stylua-macos-x86_64.zip
    fi
    exe=
    windows=no
    ;;
  *)
    asset=stylua-linux-x86_64.zip
    exe=
    windows=no
    ;;
esac

# ── stylua ───────────────────────────────────────────────────────────────────
if [ ! -x "$deps/stylua$exe" ]; then
  command -v curl >/dev/null 2>&1 || fail 'curl is required to download stylua'
  command -v unzip >/dev/null 2>&1 || fail 'unzip is required to unpack stylua'
  printf 'vcssign tools: downloading stylua %s (%s)\n' "$STYLUA_VERSION" "$asset"
  curl -fsSL -o "$deps/stylua.zip" \
    "https://github.com/JohnnyMorganz/StyLua/releases/download/$STYLUA_VERSION/$asset" ||
    fail "could not download stylua $STYLUA_VERSION"
  unzip -o -q "$deps/stylua.zip" -d "$deps" || fail 'could not unpack stylua'
  rm -f "$deps/stylua.zip"
fi

# ── luacheck ─────────────────────────────────────────────────────────────────
# Only Windows gets a prebuilt binary; elsewhere luacheck comes from luarocks.
if [ ! -x "$deps/luacheck$exe" ]; then
  if [ "$windows" = yes ]; then
    command -v curl >/dev/null 2>&1 || fail 'curl is required to download luacheck'
    printf 'vcssign tools: downloading luacheck %s\n' "$LUACHECK_VERSION"
    curl -fsSL -o "$deps/luacheck.exe" \
      "https://github.com/lunarmodules/luacheck/releases/download/$LUACHECK_VERSION/luacheck.exe" ||
      fail "could not download luacheck $LUACHECK_VERSION"
  elif command -v luacheck >/dev/null 2>&1; then
    ln -sf "$(command -v luacheck)" "$deps/luacheck"
  else
    fail "luacheck not found: install it with 'luarocks install luacheck'"
  fi
fi

printf 'vcssign tools: stylua%s + luacheck%s ready in deps/\n' "$exe" "$exe"
