#!/bin/sh
# Installed by HSTracker_CHS after macOS administrator authorization.
set -eu

ACTION=${1:-}
LABEL=com.local.hstracker-chs-skipd
PLIST=/Library/LaunchDaemons/$LABEL.plist
BINARY=/Library/PrivilegedHelperTools/$LABEL
SOCKET=/var/run/hstracker-chs-skip.sock
OLD_LABEL=com.local.hsbgskipd
OLD_PLIST=/Library/LaunchDaemons/$OLD_LABEL.plist
OLD_BINARY=/usr/local/libexec/hsbgskipd
OLD_SOCKET=/var/run/hsbgskip.sock
SOURCE=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)/HSBGSkip/hsbgskipd

if [ "$(id -u)" -ne 0 ]; then echo 'Administrator authorization is required' >&2; exit 1; fi
case "$ACTION" in install|uninstall) ;; *) echo 'Usage: install|uninstall' >&2; exit 2 ;; esac

clear_rules() {
    /sbin/pfctl -a com.apple/hstracker_chs_skip -F rules >/dev/null 2>&1 || true
}
stop_service() {
    /bin/launchctl bootout system/"$1" >/dev/null 2>&1 || true
}
start_service() {
    /bin/launchctl bootstrap system "$1"
    /bin/launchctl kickstart -k system/"$2"
}

if [ "$ACTION" = uninstall ]; then
    stop_service "$LABEL"
    if /bin/launchctl print system/"$LABEL" >/dev/null 2>&1; then
        echo 'Could not stop HSTracker_CHS skip service' >&2
        exit 1
    fi
    clear_rules
    /bin/rm -f "$SOCKET" "$PLIST" "$BINARY"
    echo 'HSTracker_CHS skip service removed'
    exit 0
fi

if [ ! -f "$SOURCE" ]; then echo "Bundled daemon missing: $SOURCE" >&2; exit 1; fi
BACKUP=$(/usr/bin/mktemp -d /private/tmp/hstracker-skip-install.XXXXXX)
OLD_RUNNING=0
NEW_RUNNING=0
if [ -f "$OLD_PLIST" ] && /bin/launchctl print system/"$OLD_LABEL" >/dev/null 2>&1; then OLD_RUNNING=1; fi
if [ -f "$PLIST" ] && /bin/launchctl print system/"$LABEL" >/dev/null 2>&1; then NEW_RUNNING=1; fi
[ ! -f "$OLD_PLIST" ] || /bin/cp -p "$OLD_PLIST" "$BACKUP/old.plist"
[ ! -f "$OLD_BINARY" ] || /bin/cp -p "$OLD_BINARY" "$BACKUP/old.binary"
[ ! -f "$PLIST" ] || /bin/cp -p "$PLIST" "$BACKUP/new.plist"
[ ! -f "$BINARY" ] || /bin/cp -p "$BINARY" "$BACKUP/new.binary"

rollback() {
    status=$?
    trap - EXIT
    if [ "$status" -ne 0 ]; then
        stop_service "$LABEL"
        clear_rules
        /bin/rm -f "$PLIST" "$BINARY" "$SOCKET"
        if [ -f "$BACKUP/new.plist" ]; then /bin/cp -p "$BACKUP/new.plist" "$PLIST"; fi
        if [ -f "$BACKUP/new.binary" ]; then /bin/cp -p "$BACKUP/new.binary" "$BINARY"; fi
        if [ "$NEW_RUNNING" -eq 1 ] && [ -f "$PLIST" ]; then start_service "$PLIST" "$LABEL" || true; fi
        if [ -f "$BACKUP/old.plist" ]; then /bin/cp -p "$BACKUP/old.plist" "$OLD_PLIST"; fi
        if [ -f "$BACKUP/old.binary" ]; then /bin/mkdir -p "$(dirname "$OLD_BINARY")"; /bin/cp -p "$BACKUP/old.binary" "$OLD_BINARY"; fi
        if [ "$OLD_RUNNING" -eq 1 ] && [ -f "$OLD_PLIST" ]; then start_service "$OLD_PLIST" "$OLD_LABEL" || true; fi
        echo 'Installation failed; previous service restored' >&2
    fi
    /bin/rm -rf "$BACKUP"
    exit "$status"
}
trap rollback EXIT

# Ask the previous companion daemon to restore before stopping it. Clearing its own pf
# anchor as a fallback is safe; it never affects Battle.net's independent connection.
if [ "$OLD_RUNNING" -eq 1 ]; then
    /bin/echo '{"command":"restore"}' | /usr/bin/nc -U -w 2 "$OLD_SOCKET" >/dev/null 2>&1 || true
fi
/sbin/pfctl -a com.apple/hsbgskip -F rules >/dev/null 2>&1 || true
stop_service "$OLD_LABEL"
stop_service "$LABEL"
if /bin/launchctl print system/"$OLD_LABEL" >/dev/null 2>&1 ||
   /bin/launchctl print system/"$LABEL" >/dev/null 2>&1; then
    echo 'Could not stop the previous skip service' >&2
    exit 1
fi
clear_rules

/bin/mkdir -p /Library/PrivilegedHelperTools
/usr/bin/install -o root -g wheel -m 755 "$SOURCE" "$BINARY"
/bin/cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$LABEL</string>
<key>ProgramArguments</key><array><string>$BINARY</string></array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
</dict></plist>
EOF
/usr/sbin/chown root:wheel "$PLIST"
/bin/chmod 644 "$PLIST"
/usr/bin/plutil -lint "$PLIST" >/dev/null
start_service "$PLIST" "$LABEL"

# launchd may need a moment to create the Unix socket. Verify the executable and socket,
# not merely launchctl's successful submission of a job.
attempt=0
while [ "$attempt" -lt 20 ] && [ ! -S "$SOCKET" ]; do
    /bin/sleep 0.1
    attempt=$((attempt + 1))
done
test -S "$SOCKET"
/bin/launchctl print system/"$LABEL" >/dev/null

/bin/rm -f "$OLD_PLIST" "$OLD_BINARY" "$OLD_SOCKET"
echo 'HSTracker_CHS skip service installed and verified'
