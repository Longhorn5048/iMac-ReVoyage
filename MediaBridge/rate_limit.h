#ifndef RV_RATE_LIMIT_H
#define RV_RATE_LIMIT_H
#include <math.h>
#include <stddef.h>
struct rv_rate_limit { double rate_bytes, burst_bytes, tokens, last_time; };
static inline struct rv_rate_limit rv_rate_limit_create(double mbps, double burst, double now) {
    return (struct rv_rate_limit){mbps * 125000, burst, burst, now};
}
static inline int rv_rate_limit_admit(struct rv_rate_limit *limit, size_t bytes, double now) {
    if (!limit || !bytes || !isfinite(now) || now < limit->last_time ||
        !isfinite(limit->rate_bytes) || limit->rate_bytes <= 0) return 0;
    limit->tokens = fmin(limit->burst_bytes, limit->tokens + (now - limit->last_time) * limit->rate_bytes);
    limit->last_time = now;
    if (bytes > limit->tokens) return 0;
    limit->tokens -= bytes; return 1;
}
#endif
