#include "TBWiredNetwork.h"
#include <net/if.h>
#include <net/if_media.h>
#include <sys/socket.h>
#include <sys/ioctl.h>
#include <sys/sockio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int tb_network_link_mbps(const char *name) {
    if (!name || strlen(name) >= IFNAMSIZ) return 0;
    int fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0) return 0;
    struct ifmediareq media = {0}; strlcpy(media.ifm_name, name, sizeof(media.ifm_name));
    int result = ioctl(fd, SIOCGIFXMEDIA, &media);
    if (result < 0) result = ioctl(fd, SIOCGIFMEDIA, &media);
    close(fd);
    if (result < 0 || IFM_TYPE(media.ifm_active) != IFM_ETHER || !(media.ifm_status & IFM_ACTIVE)) return 0;
    static const struct ifmedia_description descriptions[] = IFM_SUBTYPE_ETHERNET_DESCRIPTIONS;
    for (size_t i = 0; i < sizeof(descriptions) / sizeof(descriptions[0]); i++) {
        if (descriptions[i].ifmt_word != IFM_SUBTYPE(media.ifm_active)) continue;
        if (!descriptions[i].ifmt_string) return 0;
        char *end = NULL; double speed = strtod(descriptions[i].ifmt_string, &end);
        if (!end || !speed) return 0;
        if (*end == 'G' || *end == 'g') speed *= 1000;
        return (int)speed;
    }
    return 0;
}
