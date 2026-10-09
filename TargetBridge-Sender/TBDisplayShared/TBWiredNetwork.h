#ifndef TB_WIRED_NETWORK_H
#define TB_WIRED_NETWORK_H
/* Negotiated media speed in Mbps, or zero when the driver cannot report it. */
int tb_network_link_mbps(const char *name);
#endif
