#!/usr/bin/env bash
#
# Set up SpotifyKnob on this Mac.
#
#   git clone https://github.com/agustinlinenberg/spotify-knob ~/spotify-knob
#   ~/spotify-knob/install.sh
#
# Safe to re-run. An existing init.lua is backed up rather than overwritten,
# and credentials already in the Keychain are left alone.
set -euo pipefail

HS_DIR="${HOME}/.hammerspoon"
SPOONS="${HS_DIR}/Spoons"
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE="${SPOONS}/SpotifyKnob.spoon/spotify-connect.py"

say()  { printf '\n\033[1m%s\033[0m\n' "$*"; }
ok()   { printf '  \033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$*"; }

# --- 1. Hammerspoon ---------------------------------------------------------

say "Hammerspoon"
if [ -d /Applications/Hammerspoon.app ]; then
  ok "already installed"
elif command -v brew >/dev/null 2>&1; then
  brew install --cask hammerspoon
  ok "installed"
else
  warn "Homebrew not found. Install Hammerspoon from https://www.hammerspoon.org"
  warn "then run this script again."
  exit 1
fi

# --- 2. The Spoon ----------------------------------------------------------

say "Spoon"
mkdir -p "$SPOONS"
rm -rf "${SPOONS}/SpotifyKnob.spoon"
cp -R "${SRC}/SpotifyKnob.spoon" "$SPOONS/"
chmod +x "$BRIDGE"
ok "installed to ${SPOONS}/SpotifyKnob.spoon"

# --- 3. Config -------------------------------------------------------------
# Never clobber a working config. Someone re-running this on the Mac they
# already use would otherwise lose whatever else their Hammerspoon does.

say "Config"
if [ -e "${HS_DIR}/init.lua" ] && grep -q "SpotifyKnob" "${HS_DIR}/init.lua"; then
  ok "init.lua already loads SpotifyKnob, leaving it alone"
else
  if [ -e "${HS_DIR}/init.lua" ]; then
    STAMP="${HS_DIR}/init.lua.before-spotifyknob"
    cp "${HS_DIR}/init.lua" "$STAMP"
    warn "existing init.lua saved as ${STAMP}"
    printf '\n%s\n' '-- SpotifyKnob, added by install.sh' >> "${HS_DIR}/init.lua"
  fi
  cat >> "${HS_DIR}/init.lua" <<'LUA'
hs.loadSpoon("SpotifyKnob")
-- Which speaker to drive. A name substring, or a device ID for speakers that
-- report no name. Run spotify-connect.py devices to see what yours are called.
-- spoon.SpotifyKnob.connectDevice = "Office"
-- spoon.SpotifyKnob.deviceLabel   = "Office"
spoon.SpotifyKnob:start()
LUA
  ok "wrote ${HS_DIR}/init.lua"
fi

# --- 4. Credentials --------------------------------------------------------
# Keychain, never a file, which is why they cannot ship with the repo.

say "Spotify credentials"
have() { security find-generic-password -s spotify-knob -a "$1" >/dev/null 2>&1; }

creds_ok=1
for field in client_id client_secret; do
  if have "$field"; then
    ok "${field} already in the Keychain"
    continue
  fi
  if [ ! -t 0 ]; then
    warn "${field} missing, and there is no terminal to ask on"
    creds_ok=0
    continue
  fi
  echo
  echo "  Need your ${field}."
  echo "  From another Mac that already has this working:"
  echo "    security find-generic-password -s spotify-knob -a ${field} -w"
  echo "  Or from https://developer.spotify.com/dashboard"
  printf '  paste %s: ' "$field"
  read -rs value; echo
  if [ -z "$value" ]; then
    warn "nothing pasted, skipping ${field}"
    creds_ok=0
    continue
  fi
  security add-generic-password -s spotify-knob -a "$field" -w "$value" -U
  ok "stored ${field}"
done

if have refresh_token; then
  ok "already authorised"
elif [ "$creds_ok" = 1 ]; then
  say "Authorising with Spotify"
  echo "  A browser window will open. Approve it."
  "$BRIDGE" auth
else
  warn "skipping authorisation until the credentials above are in place"
  warn "then run: ${BRIDGE} auth"
fi

# --- 5. What is left, which is only the parts a script cannot do -----------

say "Three things left, all by hand"
cat <<'TXT'
  1. System Settings > Privacy & Security: give Hammerspoon Accessibility and
     Screen Recording. Screen Recording is what lets the card read the desktop
     behind it and choose light or dark. Without it you get a flat fill.

  2. Plug the knob in. macOS will ask ANSI / ISO / JIS: pick ANSI, or just
     close the window. The knob only sends F16 to F20, which are the same on
     every layout.

  3. Open Hammerspoon and choose Reload Config. Then press the knob.
TXT

say "Picking your speaker"
if "$BRIDGE" devices 2>/dev/null; then
  cat <<'TXT'

  A speaker showing a long hex string instead of a name is one Spotify refuses
  to name. Transfer to it to find out which room it is in:

    ~/.hammerspoon/Spoons/SpotifyKnob.spoon/spotify-connect.py transfer <id>

  Then uncomment connectDevice and deviceLabel in ~/.hammerspoon/init.lua.
TXT
else
  warn "could not reach Spotify yet. Once Spotify is open and playing, run:"
  warn "  ${BRIDGE} devices"
fi

say "Done."
