#!/usr/bin/env bash
set -euo pipefail

DB_NAME="maildb"
DB_USER="root"

STATE_DIR="/var/lib/opendkim-sync"
STATE_FILE="$STATE_DIR/domains.last"
TMP_DOMAINS="$(mktemp)"
TMP_KEYTABLE="$(mktemp)"
TMP_SIGNINGTABLE="$(mktemp)"

KEYTABLE="/etc/opendkim/KeyTable"
SIGNINGTABLE="/etc/opendkim/SigningTable"
PRIVATE_KEY="/etc/opendkim/keys/shared/s1.private"
SELECTOR="s1"

mkdir -p "$STATE_DIR"

mysql -u "$DB_USER" -D "$DB_NAME" -N -e "SELECT name FROM domain ORDER BY name;" > "$TMP_DOMAINS"

if [ ! -f "$STATE_FILE" ]; then
  cp "$TMP_DOMAINS" "$STATE_FILE"
fi

if cmp -s "$TMP_DOMAINS" "$STATE_FILE"; then
  echo "[ok] no changes detected"
  rm -f "$TMP_DOMAINS" "$TMP_KEYTABLE" "$TMP_SIGNINGTABLE"
  exit 0
fi

BK="/root/backup-opendkim-$(date +%F-%H%M%S)"
mkdir -p "$BK"
cp -a /etc/opendkim.conf "$BK"/
cp -a /etc/opendkim "$BK"/

while read -r domain; do
  [ -z "$domain" ] && continue
  echo "*@${domain} ${SELECTOR}._domainkey.${domain}" >> "$TMP_SIGNINGTABLE"
  echo "${SELECTOR}._domainkey.${domain} ${domain}:${SELECTOR}:${PRIVATE_KEY}" >> "$TMP_KEYTABLE"
done < "$TMP_DOMAINS"

install -o root -g opendkim -m 0640 "$TMP_KEYTABLE" "$KEYTABLE"
install -o root -g opendkim -m 0640 "$TMP_SIGNINGTABLE" "$SIGNINGTABLE"

cp "$TMP_DOMAINS" "$STATE_FILE"

rm -f "$TMP_DOMAINS" "$TMP_KEYTABLE" "$TMP_SIGNINGTABLE"

systemctl restart opendkim

echo "[ok] files updated and opendkim restarted"
echo "[ok] backup saved in: $BK"
