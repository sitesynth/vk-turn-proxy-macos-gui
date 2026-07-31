#pragma once

// Runs /bin/sh <scriptPath> with macOS admin privileges dialog.
// Shows the calling app's name and icon in the dialog (not "osascript").
// Returns 0 on success, non-zero on error or user cancel.
int runWithAdminPrivileges(const char *scriptPath);

// Sends a JSON command string to the vkproxy-helper daemon via Unix socket.
// Writes the response into replyBuf (null-terminated). Returns bytes read, or -1.
int sendHelperCommand(const char *jsonCmd, char *replyBuf, int replyBufLen);
