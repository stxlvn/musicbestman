#!/bin/bash
# Quick-start deployment for a fresh Ubuntu/Debian VPS. Installs system
# packages, lays out /opt/radio and /opt/tgstream, sets up a Python venv,
# installs the systemd units, and scaffolds /etc/musicbestman/env -- it
# does NOT start anything or fill in secrets for you, since those need a
# human (Telegram API credentials, a domain, SSL certs, Icecast's own
# source password). Run as root. Safe to re-run -- every step either
# checks for existing state first or is a plain overwrite of files this
# script itself owns.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root (sudo ./deploy.sh)." >&2
  exit 1
fi

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RADIO_DIR=/opt/radio
TGSTREAM_DIR=/opt/tgstream
ENV_DIR=/etc/musicbestman
ENV_FILE="$ENV_DIR/env"

echo "==> Installing system packages"
apt-get update -qq
apt-get install -y --no-install-recommends \
  icecast2 nginx ffmpeg python3-venv python3-pip \
  certbot python3-certbot-nginx curl ca-certificates

echo "==> Checking Liquidsoap"
# Ubuntu's own apt package lags well behind upstream (confirmed: 24.04
# caps at 2.2.4, which doesn't understand this project's radio.liq --
# source.on_track() was replaced by radio.on_track() in 2.4). Installing
# the current Savonet release .deb directly instead of relying on apt.
if ! command -v liquidsoap >/dev/null 2>&1 || [[ "$(liquidsoap --version | head -1)" != *"2.4"* ]]; then
  echo "    apt's liquidsoap is missing or too old -- fetching the current Savonet release instead"
  LIQ_DEB=$(mktemp --suffix=.deb)
  curl -fsSL -o "$LIQ_DEB" \
    "https://github.com/savonet/liquidsoap/releases/download/v2.4.5/liquidsoap_2.4.5-debian-bookworm-amd64.deb" \
    || echo "    WARNING: automatic Liquidsoap fetch failed -- install >=2.4 manually from https://github.com/savonet/liquidsoap/releases before starting radio.service"
  if [ -s "$LIQ_DEB" ]; then
    apt-get install -y "$LIQ_DEB" || dpkg -i "$LIQ_DEB" || apt-get -f install -y
  fi
  rm -f "$LIQ_DEB"
fi

echo "==> Laying out $RADIO_DIR and $TGSTREAM_DIR"
mkdir -p "$RADIO_DIR" "$TGSTREAM_DIR" "$TGSTREAM_DIR/fonts"
cp "$REPO_DIR"/backend/*.py "$RADIO_DIR/"
cp "$REPO_DIR"/liquidsoap/radio.liq "$RADIO_DIR/"
cp "$REPO_DIR"/tgstream/*.py "$REPO_DIR"/tgstream/*.sh "$TGSTREAM_DIR/"
chmod +x "$TGSTREAM_DIR/stream.sh"
mkdir -p "$RADIO_DIR/queue" "$RADIO_DIR/cache" "$RADIO_DIR/prefetch_enrich"

echo "==> Fetching fallback fonts for the tgstream video frame renderer"
# render_frame.py's headline font is Google's "Product Sans" -- proprietary,
# can't ship it in this repo. Noto (fully open, Google-published) stands in
# for it under the same filenames the code expects; swap in your own
# ProductSansBold.ttf/ProductSansRegular.ttf in /opt/tgstream/fonts
# afterward if you have a license for it and want the exact original look.
FONTS_BASE="https://raw.githubusercontent.com/googlefonts/noto-fonts/main/hinted/ttf"
if [ ! -f "$TGSTREAM_DIR/fonts/NotoSans.ttf" ]; then
  curl -fsSL -o "$TGSTREAM_DIR/fonts/NotoSans.ttf" "$FONTS_BASE/NotoSans/NotoSans-Regular.ttf" || echo "    WARNING: NotoSans fetch failed, fetch manually into $TGSTREAM_DIR/fonts/"
  curl -fsSL -o "$TGSTREAM_DIR/fonts/ProductSansBold.ttf" "$FONTS_BASE/NotoSans/NotoSans-Bold.ttf" || true
  curl -fsSL -o "$TGSTREAM_DIR/fonts/ProductSansRegular.ttf" "$FONTS_BASE/NotoSans/NotoSans-Regular.ttf" || true
  curl -fsSL -o "$TGSTREAM_DIR/fonts/NotoSansJP.ttf" "$FONTS_BASE/NotoSansJP/NotoSansJP-Regular.ttf" || echo "    WARNING: NotoSansJP fetch failed, fetch manually into $TGSTREAM_DIR/fonts/"
  curl -fsSL -o "$TGSTREAM_DIR/fonts/NotoEmoji.ttf" "$FONTS_BASE/NotoEmoji/NotoEmoji-Regular.ttf" || echo "    WARNING: NotoEmoji fetch failed, fetch manually into $TGSTREAM_DIR/fonts/"
fi
cp "$REPO_DIR/frontend/avatar.jpg" "$TGSTREAM_DIR/avatar.jpg"

echo "==> Python venv + dependencies (shared by both /opt/radio and /opt/tgstream)"
python3 -m venv "$RADIO_DIR/venv"
"$RADIO_DIR/venv/bin/pip" install --upgrade pip -q
"$RADIO_DIR/venv/bin/pip" install -q -r "$REPO_DIR/requirements.txt"

echo "==> Secrets scaffold"
mkdir -p "$ENV_DIR"
if [ ! -f "$ENV_FILE" ]; then
  cp "$REPO_DIR/.env.example" "$ENV_FILE"
  chmod 600 "$ENV_FILE"
  echo "    Wrote a blank $ENV_FILE -- fill in the required values before starting anything (see below)."
else
  echo "    $ENV_FILE already exists, leaving it alone."
fi

echo "==> Installing systemd units"
cp "$REPO_DIR"/systemd/*.service /etc/systemd/system/
systemctl daemon-reload
for svc in queue-filler radio radio-monitor admin-app icy-flac-proxy publish-listeners tgstream subscriber-count; do
  systemctl enable "$svc.service" >/dev/null 2>&1 || true
done

echo "==> Frontend"
echo "    Copy frontend/index.html and frontend/avatar.jpg into your nginx"
echo "    webroot (e.g. /var/www/your-domain.com/) yourself -- this script"
echo "    doesn't know your domain or webroot path."

cat <<'EOF'

==============================================================================
Installed, but nothing is running yet. Before starting services:

  1. Fill in /etc/musicbestman/env (Telegram API id/hash from
     https://my.telegram.org, the channel username, an Icecast source
     password of your choosing, your Telegram RTMP URL from the target
     chat/channel's "Start streaming" dialog, optionally Discogs/YouTube
     API keys).

  2. Set the SAME Icecast source password in /etc/icecast2/icecast.xml's
     <source-password>. Also raise <limits><sources> to at least 3 (radio.liq
     opens 3 concurrent source connections: MP3, FLAC, and a metadata-free
     FLAC copy for the web player -- Icecast's own default of 2 rejects the
     third with a 403). Then: systemctl restart icecast2

  3. Build the initial track index (one-time, needs step 1's Telegram
     creds already in the environment):
       export $(grep -v '^#' /etc/musicbestman/env | xargs)
       /opt/radio/venv/bin/python /opt/radio/tg_index_build.py

  4. Copy frontend/index.html + avatar.jpg to your nginx webroot, adapt
     nginx/your-domain-*.conf to your actual domain/IPs (edge.conf if this
     is a relay-only edge node, relay.conf if it talks to the backend
     directly), symlink into /etc/nginx/sites-enabled/, get a cert:
       certbot --nginx -d your-domain.com

  5. Start the backend services:
       systemctl start queue-filler radio radio-monitor admin-app \
         icy-flac-proxy publish-listeners

  6. Once radio.service is confirmed playing, start the Telegram
     broadcast (needs a group video call already active in the target
     chat, or ensure_call.py will try to start one):
       systemctl start tgstream subscriber-count

  7. journalctl -u <service> -f to watch any of the above come up.
==============================================================================
EOF
