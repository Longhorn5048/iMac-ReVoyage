#ifndef RV_LOCAL_CONNECTION_H
#define RV_LOCAL_CONNECTION_H

/* Current development builds connect without user pairing. This public token
 * only preserves the existing display/settings/media packet format; it is not
 * a secret and provides no peer authentication. Never require a key file or
 * Keychain entry in this mode. Both ends must use this build. */
static inline int rv_pairing_required(void) { return 0; }
static inline const char *rv_local_wire_key(void) {
    return "0000000000000000000000000000000000000000000000000000000000000000";
}

#endif
