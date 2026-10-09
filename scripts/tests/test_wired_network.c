/* Synthetic ioctl only: no network access or real interfaces. */
#define socket test_socket
#define ioctl test_ioctl
#define close test_close
#include "../../TargetBridge-Sender/TBDisplayShared/TBWiredNetwork.m"
#include <assert.h>
#include <stdarg.h>
#include <stdio.h>
static int activeSubtype=IFM_AUTO;
int test_socket(int domain,int type,int protocol) { (void)domain;(void)type;(void)protocol;return 10; }
int test_close(int fd) { (void)fd;return 0; }
int test_ioctl(int fd,unsigned long request,...) {
    (void)fd;(void)request;
    va_list args;va_start(args,request);struct ifmediareq *media=va_arg(args,struct ifmediareq *);va_end(args);
    media->ifm_active=IFM_ETHER|activeSubtype;media->ifm_status=IFM_ACTIVE;return 0;
}
int main(void) {
    assert(tb_network_link_mbps(NULL)==0);
    assert(tb_network_link_mbps("interface-name-too-long")==0);
    // IFM_AUTO matches the description-table sentinel with a null string.
    assert(tb_network_link_mbps("synthetic")==0);
    activeSubtype=IFM_1000_T;assert(tb_network_link_mbps("synthetic")==1000);
    activeSubtype=IFM_100_TX;assert(tb_network_link_mbps("synthetic")==100);
    activeSubtype=IFM_10G_T;assert(tb_network_link_mbps("synthetic")==10000);
    puts("Wired speed descriptions, sentinel and unknown speed tests passed.");
}
