#!/bin/sh
# Install vkproxy privileged helper (runs once with admin rights)
HELPER_SRC="$1"
PLIST_SRC="$2"

HELPER_DST="/Library/PrivilegedHelperTools/vkproxy-helper"
PLIST_DST="/Library/LaunchDaemons/com.vkproxy.helper.plist"

set -e

mkdir -p /Library/PrivilegedHelperTools

cp "$HELPER_SRC" "$HELPER_DST"
chown root:wheel "$HELPER_DST"
chmod 755 "$HELPER_DST"
# Ad-hoc sign so macOS allows execution
/usr/bin/codesign --force --sign - "$HELPER_DST" 2>/dev/null || true

cp "$PLIST_SRC" "$PLIST_DST"
chown root:wheel "$PLIST_DST"
chmod 644 "$PLIST_DST"

# Unload if already loaded (ignore errors)
/bin/launchctl bootout system "$PLIST_DST" 2>/dev/null || true
# Bootstrap (modern macOS 12+)
/bin/launchctl bootstrap system "$PLIST_DST"
