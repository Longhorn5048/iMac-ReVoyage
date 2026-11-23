#include "../ShellPresentation.h"
#include <assert.h>
#include <stdio.h>

static unsigned checks;
#define CHECK(x) do { assert(x); checks++; } while (0)

int main(void) {
    const unsigned int net = RV_DISPLAY_SIGNAL_NETWORK, hdmi = RV_DISPLAY_SIGNAL_HDMI_FRAMES;

    /* Nothing on either input: the shell, never the desktop. */
    CHECK(rv_shell_view_for(RV_DISPLAY_SIGNAL_NONE, 0, 0, 0) == RV_SHELL_VIEW_NO_SIGNAL);
    CHECK(rv_shell_view_covers(RV_SHELL_VIEW_NO_SIGNAL));
    /* A stale HDMI timestamp without a running capture is still no signal. */
    CHECK(rv_shell_view_for(hdmi, 0, 0, 0) == RV_SHELL_VIEW_NO_SIGNAL);
    CHECK(rv_shell_view_for(hdmi, 1, 0, 0) == RV_SHELL_VIEW_HDMI);
    CHECK(rv_shell_view_covers(RV_SHELL_VIEW_HDMI));
    /* Network wins over HDMI unless the user holds manual Rescue. */
    CHECK(rv_shell_view_for(net | hdmi, 1, 0, 0) == RV_SHELL_VIEW_NETWORK);
    CHECK(!rv_shell_view_covers(RV_SHELL_VIEW_NETWORK));
    CHECK(rv_shell_view_for(net | hdmi, 1, 1, 0) == RV_SHELL_VIEW_HDMI);
    CHECK(rv_shell_view_for(net, 0, 1, 0) == RV_SHELL_VIEW_NO_SIGNAL);
    /* Only an explicit exit uncovers the desktop. */
    CHECK(rv_shell_view_for(RV_DISPLAY_SIGNAL_NONE, 0, 0, 1) == RV_SHELL_VIEW_DESKTOP);
    CHECK(rv_shell_view_for(net | hdmi, 1, 1, 1) == RV_SHELL_VIEW_DESKTOP);
    CHECK(!rv_shell_view_covers(RV_SHELL_VIEW_DESKTOP));

    uint64_t armed = 0;
    CHECK(!rv_shell_exit_press(&armed, 1000) && armed == 1000);
    CHECK(rv_shell_exit_press(&armed, 2500) && armed == 0);
    CHECK(!rv_shell_exit_press(&armed, 3000));
    CHECK(!rv_shell_exit_press(&armed, 4501) && armed == 4501); /* Too late: re-arms. */
    CHECK(rv_shell_exit_press(&armed, 4600));
    CHECK(!rv_shell_exit_press(&armed, 0) && armed == 1); /* Zero clock still arms. */
    armed = 5000;
    CHECK(!rv_shell_exit_press(&armed, 4000) && armed == 4000); /* Clock went backwards. */

    CHECK(!rv_shell_no_signal_should_sleep(1000, 3600000, 3600000, 0)); /* Default: stay lit. */
    CHECK(!rv_shell_no_signal_should_sleep(0, 100000, 100000, 60000));
    CHECK(!rv_shell_no_signal_should_sleep(1000, 60999, 100000, 60000));
    CHECK(rv_shell_no_signal_should_sleep(1000, 61000, 60000, 60000));
    CHECK(!rv_shell_no_signal_should_sleep(1000, 61000, 59999, 60000)); /* Someone is at the iMac. */
    CHECK(!rv_shell_no_signal_should_sleep(2000, 1000, 100000, 60000));

    printf("Shell presentation: %u checks passed\n", checks);
    return 0;
}
