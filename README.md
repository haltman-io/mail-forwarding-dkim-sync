# mail-forwarding-dkim-sync
This project exists to solve a real problem in **multi-domain email environments**: keeping **DKIM aligned with the visible sender domain** without manually editing OpenDKIM every time a new domain is added.

In a small setup, maintaining `KeyTable` and `SigningTable` by hand is manageable. In an environment with dozens, hundreds, or thousands of domains, that quickly becomes an operational failure point. A domain may exist in the database, but not in OpenDKIM. The result is predictable:

* the message is sent with `From: user@customer-domain.com`
* but OpenDKIM signs it with a fixed domain such as `d=dkim.example.com`
* **DKIM may still pass cryptographically**
* but **DMARC fails because the signature is not aligned with the visible sender**
* the recipient sees spoofing, phishing, or authentication warnings

So the problem is not just “having DKIM.”
The real problem is having **correct DKIM that is aligned with the domain shown in the `From:` header**.

This project exists to automate that.

It reads domains from MariaDB and automatically generates:

* `KeyTable`
* `SigningTable`

That allows each domain to be signed with its own DKIM identity, for example:

* `From: root@reads.phrack.org`
* `DKIM d=reads.phrack.org`

instead of forcing every message through a generic shared signing domain.

This improves:

* **DKIM correctness**
* **DMARC alignment**
* **deliverability**
* **operational scalability**
* **consistency across large domain inventories**

In plain terms:

**new domains added to the database should not require manual OpenDKIM maintenance.**
This project exists so DKIM stays synchronized with the domain inventory automatically, reducing configuration drift, authentication failures, and anti-spoofing warnings at recipient providers.


## Context
Mail forwarding used (in the past) Proton's SMTP servers only to send confirmation emails because we trusted them.

But, like any corporation that loves to stuff its pockets with US dollars, just like prostitutes, they sell your data to the FBI.

If you want to know specifically where it was used, it was here: https://github.com/haltman-io/mail-forwarding-api/blob/main/app/.env.example#L55-L71

With our commitment to privacy, we decided not to use Proton's outgoing SMTP servers (they can sell our data to the FBI too, who knows?).

So we created a service that updates the DKIM tables, since mail-forwarding-dns-checker already requires DKIM registration. 

All domains already had DKIM correctly pointed in the DNS, all that was left was to update the DKIM tables locally.


# OpenDKIM Domain Sync

A small automation project that keeps **OpenDKIM `KeyTable` and `SigningTable` synchronized** with the list of domains stored in a **MariaDB** database.

It is designed for environments that manage **many domains** and need DKIM signing to stay aligned with the visible sender domain automatically, without manually editing OpenDKIM tables every time a new domain is added.

---

## What this does

This project:

- reads domains from a MariaDB table
- generates `/etc/opendkim/KeyTable`
- generates `/etc/opendkim/SigningTable`
- uses a shared selector such as `s1`
- can reuse a shared private key for all domains
- creates a backup before applying changes
- restarts `opendkim` only when the domain list changes
- runs automatically every 5 minutes using `systemd timer`

This solves the common problem where OpenDKIM is configured with a single fixed signing domain such as:

```conf
*@* s1._domainkey.dkim.example.com
````

That pattern breaks **DMARC alignment** for multi-domain environments because the visible `From:` domain does not match the DKIM `d=` domain.

Instead, this project generates per-domain mappings such as:

```conf
*@reads.phrack.org s1._domainkey.reads.phrack.org
*@segfault.net s1._domainkey.segfault.net
```

And corresponding `KeyTable` entries such as:

```conf
s1._domainkey.reads.phrack.org reads.phrack.org:s1:/etc/opendkim/keys/shared/s1.private
s1._domainkey.segfault.net segfault.net:s1:/etc/opendkim/keys/shared/s1.private
```

This allows OpenDKIM to sign mail using the actual sender domain, improving DKIM alignment and helping DMARC pass.

---

## How it works

The sync script:

1. connects to MariaDB
2. reads the domain list from the `domain` table
3. compares the current result with the last known snapshot
4. exits silently if nothing changed
5. creates a backup if there was a change
6. rebuilds `KeyTable` and `SigningTable`
7. restarts OpenDKIM

The timer runs this process every 5 minutes.

---

## Requirements

* Linux server with `systemd`
* OpenDKIM installed and working
* MariaDB or MySQL client installed
* a database containing a table with domains
* root privileges
* a valid DKIM private key already available

---

## Expected database structure

The script expects a table like this:

```sql
SELECT name FROM domain ORDER BY name;
```

Example output:

```text
1337.meu.bingo
503.lat
abin.lat
reads.phrack.org
segfault.net
smokes.thc.org
the.hackerschoice.org
```

---

## File layout

Recommended paths:

```text
/usr/local/bin/opendkim-sync-domains.sh
/etc/systemd/system/opendkim-sync-domains.service
/etc/systemd/system/opendkim-sync-domains.timer
/etc/opendkim/KeyTable
/etc/opendkim/SigningTable
/etc/opendkim/keys/shared/s1.private
/var/lib/opendkim-sync/domains.last
```

---

## Configuration

Edit the script variables to match your environment:

```bash
DB_NAME="maildb"
DB_USER="root"

STATE_DIR="/var/lib/opendkim-sync"
STATE_FILE="$STATE_DIR/domains.last"

KEYTABLE="/etc/opendkim/KeyTable"
SIGNINGTABLE="/etc/opendkim/SigningTable"
PRIVATE_KEY="/etc/opendkim/keys/shared/s1.private"
SELECTOR="s1"
```

### Important notes

* `SELECTOR` must match the DKIM selector published in DNS
* `PRIVATE_KEY` must point to the private key OpenDKIM should use
* if you use a shared key, every managed domain must publish the corresponding selector record
* if you use CNAME-based DKIM, each domain must point its selector to the shared DKIM record

Example:

```dns
s1._domainkey.reads.phrack.org CNAME s1._domainkey.dkim.example.com.
```

---

## OpenDKIM configuration

Your `opendkim.conf` should reference the generated files:

```conf
KeyTable                refile:/etc/opendkim/KeyTable
SigningTable            refile:/etc/opendkim/SigningTable
```

Recommended canonicalization:

```conf
Canonicalization        relaxed/relaxed
```

This is important because `relaxed/relaxed` is usually more tolerant of harmless transport changes than `relaxed/simple`.

---

## Installation

### 1. Create the script

Save the script as:

```text
/usr/local/bin/opendkim-sync-domains.sh
```

Example script:

```bash
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
```

Make it executable:

```bash
chmod +x /usr/local/bin/opendkim-sync-domains.sh
```

---

### 2. Create the service

Save as:

```text
/etc/systemd/system/opendkim-sync-domains.service
```

Content:

```ini
[Unit]
Description=Sync OpenDKIM tables from MariaDB domains
After=network-online.target mariadb.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/opendkim-sync-domains.sh
```

---

### 3. Create the timer

Save as:

```text
/etc/systemd/system/opendkim-sync-domains.timer
```

Content:

```ini
[Unit]
Description=Run OpenDKIM domain sync every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Unit=opendkim-sync-domains.service
Persistent=true

[Install]
WantedBy=timers.target
```

---

### 4. Reload systemd and enable the timer

```bash
systemctl daemon-reload
systemctl enable --now opendkim-sync-domains.timer
```

---

## Manual test

Run the service manually:

```bash
systemctl start opendkim-sync-domains.service
```

Check logs:

```bash
journalctl -u opendkim-sync-domains.service -n 50 --no-pager
```

Check timer state:

```bash
systemctl list-timers --all | grep opendkim-sync
```

---

## Backup and recovery

Before writing new files, the script creates a full backup:

```text
/root/backup-opendkim-YYYY-MM-DD-HHMMSS
```

This backup includes:

* `/etc/opendkim.conf`
* `/etc/opendkim`

### Restore example

```bash
BK="/root/backup-opendkim-YYYY-MM-DD-HHMMSS"

cp -a "$BK"/opendkim.conf /etc/opendkim.conf
rm -rf /etc/opendkim
cp -a "$BK"/opendkim /etc/opendkim
systemctl restart opendkim
```

---

## DNS requirements

This project only generates OpenDKIM tables. It does **not** publish DNS automatically.

For each domain, you must ensure the selector exists in DNS.

### Shared-key model

If you use one shared key for many domains, publish a CNAME per domain:

```dns
s1._domainkey.reads.phrack.org CNAME s1._domainkey.dkim.example.com.
s1._domainkey.segfault.net CNAME s1._domainkey.dkim.example.com.
```

### Direct TXT model

Or publish the TXT record directly for each domain:

```dns
s1._domainkey.reads.phrack.org TXT "v=DKIM1; k=rsa; p=..."
```

---

## Why this matters

In multi-domain mail systems, using a fixed signing domain for all mail often causes this:

* SPF may pass for the envelope domain
* DKIM may pass for the signing domain
* DMARC still fails because the visible `From:` domain is different

This project avoids that by mapping each sender domain to its own DKIM identity.

Example:

* visible sender: `root@reads.phrack.org`
* DKIM signature: `d=reads.phrack.org`
* result: better alignment, better DMARC behavior

---

## Limitations

* this does not create DNS records
* this does not validate whether domains are ready for DKIM
* this assumes OpenDKIM is already installed and functional
* this assumes MariaDB is reachable from the host running the script
* this example uses a shared private key, which may not fit every security model

---

## Suggested improvements

Possible future enhancements:

* validate domains before writing tables
* generate DNS export files automatically
* support one private key per domain
* log to a dedicated file
* run `opendkim-testkey` automatically before restart
* skip invalid or duplicated domains
* integrate with your provisioning workflow

---

## Summary

This project automates OpenDKIM table generation for large multi-domain environments.

It is useful when:

* domains are stored in MariaDB
* new domains are added frequently
* manual OpenDKIM table maintenance is no longer practical
* DKIM alignment must follow the actual sender domain

In plain words:

**new domain enters the database, the timer detects the change, OpenDKIM tables are rebuilt, and mail can be signed with the correct domain automatically.**
