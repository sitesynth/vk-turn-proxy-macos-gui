#!/bin/sh
# One-time install: copies helper binary and grants NOPASSWD sudo right
HELPER_SRC="$1"
HELPER_DST="/Library/PrivilegedHelperTools/vkproxy-helper"
SUDOERS="/etc/sudoers.d/vkproxy"

set -e

mkdir -p /Library/PrivilegedHelperTools

cp "$HELPER_SRC" "$HELPER_DST"
chown root:wheel "$HELPER_DST"
chmod 755 "$HELPER_DST"
/usr/bin/codesign --force --sign - "$HELPER_DST" 2>/dev/null || true
/usr/bin/xattr -d com.apple.quarantine "$HELPER_DST" 2>/dev/null || true

# Allow all users to run helper as root without password prompt
printf "ALL ALL=(root) NOPASSWD: %s\n" "$HELPER_DST" > "$SUDOERS"
chown root:wheel "$SUDOERS"
chmod 440 "$SUDOERS"

# Remove old LaunchDaemon if present
/bin/launchctl bootout system /Library/LaunchDaemons/com.vkproxy.helper.plist 2>/dev/null || true
rm -f /Library/LaunchDaemons/com.vkproxy.helper.plist 2>/dev/null || true
