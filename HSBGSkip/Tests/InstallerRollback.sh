#!/bin/sh
# Exercises the production install script's rollback flow inside a disposable root.
set -eu
REPO=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
MOCK_ROOT=$(/usr/bin/mktemp -d /private/tmp/hsbg-installer-test.XXXXXX)
export MOCK_ROOT
trap '/bin/rm -rf "$MOCK_ROOT"' EXIT

/bin/mkdir -p "$MOCK_ROOT/Library/LaunchDaemons" "$MOCK_ROOT/usr/local/libexec" \
    "$MOCK_ROOT/var/run" "$MOCK_ROOT/App/Contents/Resources/Resources" \
    "$MOCK_ROOT/App/Contents/Resources/HSBGSkip"
/bin/echo 'old daemon' > "$MOCK_ROOT/usr/local/libexec/hsbgskipd"
/bin/echo '<plist/>' > "$MOCK_ROOT/Library/LaunchDaemons/com.local.hsbgskipd.plist"
/bin/echo 'new daemon' > "$MOCK_ROOT/App/Contents/Resources/HSBGSkip/hsbgskipd"
/usr/bin/touch "$MOCK_ROOT/old-running"

/bin/cat > "$MOCK_ROOT/launchctl" <<'EOF'
#!/bin/sh
case "$1" in
    print)
        case "$2" in
            system/com.local.hsbgskipd) test -f "$MOCK_ROOT/old-running" ;;
            system/com.local.hstracker-chs-skipd) test -f "$MOCK_ROOT/new-running" ;;
        esac ;;
    bootout)
        case "$2" in
            system/com.local.hsbgskipd) /bin/rm -f "$MOCK_ROOT/old-running" ;;
            system/com.local.hstracker-chs-skipd) /bin/rm -f "$MOCK_ROOT/new-running" "$MOCK_ROOT/var/run/hstracker-chs-skip.sock" ;;
        esac ;;
    bootstrap)
        case "$3" in
            *hstracker-chs-skipd.plist)
                if [ "${MOCK_FAIL_NEW:-0}" = 1 ]; then exit 42; fi
                /usr/bin/touch "$MOCK_ROOT/new-running"
                /usr/bin/python3 -c 'import socket,sys; s=socket.socket(socket.AF_UNIX); s.bind(sys.argv[1]); s.close()' "$MOCK_ROOT/var/run/hstracker-chs-skip.sock" ;;
            *hsbgskipd.plist) /usr/bin/touch "$MOCK_ROOT/old-running" ;;
        esac ;;
    kickstart) : ;;
esac
EOF
/bin/cat > "$MOCK_ROOT/pfctl" <<'EOF'
#!/bin/sh
exit 0
EOF
/bin/cat > "$MOCK_ROOT/nc" <<'EOF'
#!/bin/sh
exit 0
EOF
/bin/chmod 755 "$MOCK_ROOT/launchctl" "$MOCK_ROOT/pfctl" "$MOCK_ROOT/nc"

TARGET="$MOCK_ROOT/App/Contents/Resources/Resources/hsbgskip-install.sh"
/usr/bin/sed \
    -e "s|/Library/LaunchDaemons|$MOCK_ROOT/Library/LaunchDaemons|g" \
    -e "s|/Library/PrivilegedHelperTools|$MOCK_ROOT/Library/PrivilegedHelperTools|g" \
    -e "s|/usr/local/libexec|$MOCK_ROOT/usr/local/libexec|g" \
    -e "s|/var/run/|$MOCK_ROOT/var/run/|g" \
    -e "s|/bin/launchctl|$MOCK_ROOT/launchctl|g" \
    -e "s|/sbin/pfctl|$MOCK_ROOT/pfctl|g" \
    -e "s|/usr/bin/nc|$MOCK_ROOT/nc|g" \
    -e 's/$(id -u)/0/g' \
    -e 's|/usr/sbin/chown root:wheel|/usr/bin/true|g' \
    -e 's|/usr/bin/install -o root -g wheel -m 755|/usr/bin/install -m 755|g' \
    "$REPO/HSTracker/Resources/hsbgskip-install.sh" > "$TARGET"

if MOCK_FAIL_NEW=1 /bin/sh "$TARGET" install > "$MOCK_ROOT/output" 2>&1; then
    echo 'Expected the new daemon bootstrap to fail' >&2
    exit 1
fi
test -f "$MOCK_ROOT/old-running"
test -f "$MOCK_ROOT/Library/LaunchDaemons/com.local.hsbgskipd.plist"
test -f "$MOCK_ROOT/usr/local/libexec/hsbgskipd"
test ! -f "$MOCK_ROOT/Library/LaunchDaemons/com.local.hstracker-chs-skipd.plist"
test ! -f "$MOCK_ROOT/Library/PrivilegedHelperTools/com.local.hstracker-chs-skipd"
echo 'Installer rollback restored the old service'

if ! MOCK_FAIL_NEW=0 /bin/sh "$TARGET" install > "$MOCK_ROOT/install-output" 2>&1; then
    /bin/cat "$MOCK_ROOT/install-output" >&2
    exit 1
fi
test -f "$MOCK_ROOT/new-running"
test ! -f "$MOCK_ROOT/old-running"
test ! -f "$MOCK_ROOT/Library/LaunchDaemons/com.local.hsbgskipd.plist"
test -S "$MOCK_ROOT/var/run/hstracker-chs-skip.sock"
if ! MOCK_FAIL_NEW=0 /bin/sh "$TARGET" uninstall > "$MOCK_ROOT/uninstall-output" 2>&1; then
    /bin/cat "$MOCK_ROOT/uninstall-output" >&2
    exit 1
fi
test ! -f "$MOCK_ROOT/new-running"
test ! -S "$MOCK_ROOT/var/run/hstracker-chs-skip.sock"
test ! -f "$MOCK_ROOT/Library/LaunchDaemons/com.local.hstracker-chs-skipd.plist"
echo 'Installer migration and uninstall cleared the new service'
