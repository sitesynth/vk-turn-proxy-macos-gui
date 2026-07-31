#include "Privileged.h"
#include <Security/Authorization.h>
#include <Security/AuthorizationTags.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>
#include <string.h>
#include <stdio.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

int runWithAdminPrivileges(const char *scriptPath) {
    AuthorizationRef authRef = NULL;
    OSStatus status = AuthorizationCreate(NULL, kAuthorizationEmptyEnvironment,
                                          kAuthorizationFlagDefaults, &authRef);
    if (status != errAuthorizationSuccess) return (int)status;

    char *const args[] = {(char *)scriptPath, NULL};
    status = AuthorizationExecuteWithPrivileges(authRef, "/bin/sh",
                                               kAuthorizationFlagDefaults,
                                               args, NULL);
    AuthorizationFree(authRef, kAuthorizationFlagDefaults);
    return (int)status;
}

#pragma clang diagnostic pop

// Send a JSON command to the vkproxy helper daemon via Unix socket.
// Returns 1 on {"ok":true}, 0 otherwise.
int sendHelperCommand(const char *jsonCmd, char *replyBuf, int replyBufLen) {
    int sock = socket(AF_UNIX, SOCK_STREAM, 0);
    if (sock < 0) return -1;

    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, "/var/run/vkproxy.sock", sizeof(addr.sun_path) - 1);

    if (connect(sock, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        close(sock);
        return -1;
    }

    size_t len = strlen(jsonCmd);
    if (write(sock, jsonCmd, len) < 0) {
        close(sock);
        return -1;
    }

    int n = 0;
    if (replyBuf && replyBufLen > 1) {
        n = (int)read(sock, replyBuf, replyBufLen - 1);
        if (n > 0) replyBuf[n] = '\0';
    }

    close(sock);
    return n;
}
