#!/usr/bin/env bash
# Grok Bot permanent SSH tunnel for D4M13N -> ssh.kodakgp.com (named Cloudflare tunnel)
# Separate from the play.kodakgp.com tunnel. Undo: sudo bash /tmp/g --remove
set -uo pipefail
HOSTNAME_SSH="${SSH_HOST:-ssh.kodakgp.com}"
TNAME=grokbot-ssh
UNIT=grokbot-ssh-tunnel
CFG=/etc/grokbot-ssh
PUBKEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGLQNfgMTfrNc8KgkwULD7is7tmBsenQgiUGBo0ge03h ildamienll@grokbot-d4m13n'
say(){ echo "[grokbot-perm] $*"; }; die(){ echo "[grokbot-perm] FAIL: $*"; exit 1; }
[ "$(id -u)" -eq 0 ] || die "run with sudo"
TUSER="${SUDO_USER:-blitzedbella}"; [ "$TUSER" = root ] && TUSER=blitzedbella
THOME="$(getent passwd "$TUSER" | cut -d: -f6)"; [ -n "$THOME" ] || die "user $TUSER not found"
export HOME=/root
CF="$(command -v cloudflared || true)"
HAS_SYSTEMD=""; [ "$(ps -p 1 -o comm= 2>/dev/null)" = systemd ] && HAS_SYSTEMD=1
grep -qi microsoft /proc/version 2>/dev/null && IS_WSL=1 || IS_WSL=""

if [ "${1:-}" = "--remove" ]; then
  systemctl disable --now "$UNIT" 2>/dev/null; pkill -f grokbot-ssh-run 2>/dev/null; (crontab -l 2>/dev/null | grep -v grokbot-ssh-run) | crontab - 2>/dev/null; rm -f /usr/local/bin/grokbot-ssh-run; rm -f /etc/systemd/system/$UNIT.service; systemctl daemon-reload
  [ -n "$CF" ] && { $CF tunnel cleanup "$TNAME" >/dev/null 2>&1; $CF tunnel delete -f "$TNAME" >/dev/null 2>&1; }
  rm -rf "$CFG"; sed -i '/ildamienll@grokbot-d4m13n/d' "$THOME/.ssh/authorized_keys" 2>/dev/null
  say "removed (also delete the $HOSTNAME_SSH DNS record in Cloudflare if you like)"; exit 0
fi

say "1/7 network"
getent hosts api.cloudflare.com >/dev/null || { cp -n /etc/resolv.conf /etc/resolv.conf.grokbot.bak 2>/dev/null; printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf; }
getent hosts api.cloudflare.com >/dev/null || die "no internet/DNS"

say "2/7 sshd"
if [ ! -x /usr/sbin/sshd ]; then DEBIAN_FRONTEND=noninteractive apt-get update -qq; DEBIAN_FRONTEND=noninteractive apt-get install -y -qq openssh-server || die "openssh-server install failed"; fi
mkdir -p /run/sshd; /usr/sbin/sshd -t || die "sshd config invalid (sudo /usr/sbin/sshd -t)"
systemctl enable --now ssh 2>/dev/null || systemctl enable --now sshd 2>/dev/null || service ssh start >/dev/null 2>&1 || true
SSHPORT=""
for p in 22 2222; do ss -ltn 2>/dev/null | grep -qE "[:.]$p\s" && { SSHPORT=$p; break; }; done
[ -z "$SSHPORT" ] && SSHPORT=$(ss -ltnp 2>/dev/null | awk '/sshd/{n=split($4,a,":");print a[n];exit}')
if [ -z "$SSHPORT" ]; then
  say "no sshd listening - starting one on 2222"
  /usr/sbin/sshd -p 2222 || die "could not start sshd"; sleep 1; SSHPORT=2222
  cat > /etc/systemd/system/grokbot-sshd.service <<U
[Unit]
Description=Grok Bot fallback sshd on 2222
After=network.target
[Service]
ExecStartPre=/bin/mkdir -p /run/sshd
ExecStart=/usr/sbin/sshd -D -p 2222
Restart=always
[Install]
WantedBy=multi-user.target
U
  if [ -n "$HAS_SYSTEMD" ]; then pkill -f 'sshd -p 2222' 2>/dev/null; systemctl daemon-reload; systemctl enable --now grokbot-sshd >/dev/null 2>&1; fi
fi
say "sshd on port $SSHPORT"

say "3/7 key for $TUSER"
install -d -m 700 -o "$TUSER" -g "$TUSER" "$THOME/.ssh"; touch "$THOME/.ssh/authorized_keys"
grep -qF "$PUBKEY" "$THOME/.ssh/authorized_keys" || echo "$PUBKEY" >> "$THOME/.ssh/authorized_keys"
chown "$TUSER:$TUSER" "$THOME/.ssh/authorized_keys"; chmod 600 "$THOME/.ssh/authorized_keys"; chmod go-w "$THOME"

say "4/7 cloudflared"
if [ -z "$CF" ]; then
  ARCH=$(dpkg --print-architecture 2>/dev/null || echo amd64)
  curl -fsSL -o /tmp/cloudflared.deb "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-$ARCH.deb" && dpkg -i /tmp/cloudflared.deb >/dev/null || die "cloudflared install failed"
  CF="$(command -v cloudflared)"
fi

say "5/7 Cloudflare login"
mkdir -p /root/.cloudflared
[ -f /root/.cloudflared/cert.pem ] || for c in "$THOME/.cloudflared/cert.pem" /etc/cloudflared/cert.pem; do [ -f "$c" ] && cp "$c" /root/.cloudflared/cert.pem && break; done
if [ ! -f /root/.cloudflared/cert.pem ]; then
  echo; echo ">>> A link will appear below. Open it, log in to Cloudflare, click kodakgp.com, then Authorize. <<<"; echo
  $CF tunnel login || die "Cloudflare login failed - rerun the command"
fi
[ -f /root/.cloudflared/cert.pem ] || die "login did not finish - rerun the command"

say "6/7 named tunnel $TNAME -> $HOSTNAME_SSH"
TID=$($CF tunnel list -n "$TNAME" -o json 2>/dev/null | grep -oE '"id":"[0-9a-f-]{36}"' | head -1 | cut -d'"' -f4)
mkdir -p "$CFG"
if [ -n "$TID" ] && [ ! -f "$CFG/$TID.json" ] && [ ! -f "/root/.cloudflared/$TID.json" ]; then
  say "old tunnel has no credentials here - recreating"
  $CF tunnel cleanup "$TNAME" >/dev/null 2>&1; $CF tunnel delete -f "$TNAME" >/dev/null 2>&1; TID=""
fi
if [ -z "$TID" ]; then
  $CF tunnel create "$TNAME" || die "tunnel create failed"
  TID=$($CF tunnel list -n "$TNAME" -o json 2>/dev/null | grep -oE '"id":"[0-9a-f-]{36}"' | head -1 | cut -d'"' -f4)
fi
[ -n "$TID" ] || die "could not read tunnel id"
[ -f "/root/.cloudflared/$TID.json" ] && cp "/root/.cloudflared/$TID.json" "$CFG/$TID.json"
[ -f "$CFG/$TID.json" ] || die "tunnel credentials missing"
chmod 600 "$CFG/$TID.json"
cat > "$CFG/config.yml" <<C
tunnel: $TID
credentials-file: $CFG/$TID.json
ingress:
  - hostname: $HOSTNAME_SSH
    service: ssh://localhost:$SSHPORT
  - service: http_status:404
C
$CF tunnel --config "$CFG/config.yml" ingress validate >/dev/null || die "bad tunnel config"
$CF tunnel route dns --overwrite-dns "$TID" "$HOSTNAME_SSH" || $CF tunnel route dns "$TID" "$HOSTNAME_SSH" || die "DNS route for $HOSTNAME_SSH failed (did you pick kodakgp.com at login?)"

say "7/7 keep it running"
RUNNER=/usr/local/bin/grokbot-ssh-run
cat > $RUNNER <<R
#!/bin/sh
mkdir -p /run/sshd
ss -ltn | grep -qE "[:.]$SSHPORT[[:space:]]" || /usr/sbin/sshd -p $SSHPORT
while true; do $CF --no-autoupdate --config $CFG/config.yml tunnel run >>/var/log/grokbot-ssh.log 2>&1; sleep 5; done
R
chmod 755 $RUNNER
OK=""
if [ -n "$HAS_SYSTEMD" ]; then
  cat > /etc/systemd/system/$UNIT.service <<U
[Unit]
Description=Grok Bot permanent SSH tunnel ($HOSTNAME_SSH)
After=network-online.target
Wants=network-online.target
[Service]
ExecStart=$CF --no-autoupdate --config $CFG/config.yml tunnel run
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
U
  systemctl daemon-reload; systemctl enable "$UNIT" >/dev/null 2>&1
  T0=$(date +%s); systemctl restart "$UNIT"
  for i in $(seq 1 30); do journalctl -u "$UNIT" --since "@$T0" --no-pager 2>/dev/null | grep -q "Registered tunnel connection" && { OK=1; break; }; sleep 2; done
  [ -n "$OK" ] || die "tunnel did not connect - run: journalctl -u $UNIT -n 40 --no-pager"
  say "systemd service enabled - starts on boot"
else
  say "no systemd (WSL) - using background runner + @reboot cron"
  pkill -f grokbot-ssh-run 2>/dev/null; pkill -f "$CFG/config.yml" 2>/dev/null; sleep 1
  : > /var/log/grokbot-ssh.log
  nohup $RUNNER >/dev/null 2>&1 &
  (crontab -l 2>/dev/null | grep -v grokbot-ssh-run; echo "@reboot $RUNNER >/dev/null 2>&1") | crontab - 2>/dev/null || say "warn: cron not available"
  service cron start >/dev/null 2>&1 || true
  for i in $(seq 1 30); do grep -q "Registered tunnel connection" /var/log/grokbot-ssh.log && { OK=1; break; }; sleep 2; done
  [ -n "$OK" ] || die "tunnel did not connect - run: tail -40 /var/log/grokbot-ssh.log"
fi
if [ -n "$IS_WSL" ]; then
  if [ -z "$HAS_SYSTEMD" ] && ! grep -q 'systemd=true' /etc/wsl.conf 2>/dev/null; then
    printf '[boot]\nsystemd=true\n' >> /etc/wsl.conf
    say "WSL: enabled systemd for next start (it already works now)"
  fi
  say "WSL note: the tunnel runs while this Ubuntu is running in Windows"
fi
echo; echo "================ SEND THIS LINE TO GROK BOT ================"
echo "GROKBOT_SSH user=$TUSER host=$HOSTNAME_SSH permanent=yes"
echo "============================================================"
echo "Remove anytime: sudo bash /tmp/g --remove"
