#pragma once

// Runs /bin/sh <scriptPath> with macOS admin privileges dialog.
// Shows the calling app's name and icon in the dialog (not "osascript").
// Returns 0 on success, non-zero on error or user cancel.
int runWithAdminPrivileges(const char *scriptPath);
