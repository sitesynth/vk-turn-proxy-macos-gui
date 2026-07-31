#include "Privileged.h"
#include <Security/Authorization.h>
#include <Security/AuthorizationTags.h>

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
