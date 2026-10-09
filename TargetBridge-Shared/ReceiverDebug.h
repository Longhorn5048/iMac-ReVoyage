#ifndef REVOYAGE_RECEIVER_DEBUG_H
#define REVOYAGE_RECEIVER_DEBUG_H

#define RV_RECEIVER_DEBUG_TOGGLE_NOTIFICATION "re.voyage.receiver.debug-toggle"
#define RV_RECEIVER_RESCUE_TOGGLE_NOTIFICATION "re.voyage.receiver.rescue-toggle"

enum rv_receiver_shortcut_action {
    RV_RECEIVER_SHORTCUT_DEBUG = 1u << 0,
    RV_RECEIVER_SHORTCUT_RESCUE = 1u << 1
};

/* Physical macOS key codes. Reserve bare D/R (Shift/Caps Lock are allowed),
 * consume the matching release, and never toggle on auto-repeat. */
static inline int rv_receiver_shortcut(unsigned int *held, unsigned int key,
    int down, int repeat, int command_option_control, unsigned int *action) {
    unsigned int bit = key == 2 ? RV_RECEIVER_SHORTCUT_DEBUG :
                       key == 15 ? RV_RECEIVER_SHORTCUT_RESCUE : 0;
    *action = 0;
    if (!bit) return 0;
    if (!down) {
        if (!(*held & bit)) return 0;
        *held &= ~bit;
        return 1;
    }
    if (command_option_control && !(*held & bit)) return 0;
    *held |= bit;
    if (!repeat) *action = bit;
    return 1;
}
#endif
