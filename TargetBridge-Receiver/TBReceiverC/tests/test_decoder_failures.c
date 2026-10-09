/* Exercise allocation/reconfiguration failure paths without a GPU or window. */
#include <libavcodec/avcodec.h>
#include <libavutil/mem.h>
#include <assert.h>

static int allocations_before_failure = -1;
static void *test_av_malloc(size_t size) {
    if (allocations_before_failure == 0) return NULL;
    if (allocations_before_failure > 0) allocations_before_failure--;
    return av_malloc(size);
}

static const AVCodecHWConfig *test_hw_config(const AVCodec *codec, int index) {
    (void)codec; (void)index;
    return NULL; /* Keep these tests independent of hardware. */
}

static int fail_open = 0;
static int test_open(AVCodecContext *ctx, const AVCodec *codec, AVDictionary **options) {
    (void)ctx; (void)codec; (void)options;
    return fail_open ? AVERROR(ENOMEM) : 0;
}

#define av_malloc test_av_malloc
#define avcodec_get_hw_config test_hw_config
#define avcodec_open2 test_open
#include "../src/decoder.c"
#undef av_malloc
#undef avcodec_get_hw_config
#undef avcodec_open2

int main(void) {
    struct tb_decoder *decoder = tb_dec_create(NULL, NULL);
    assert(decoder);
    const uint8_t params[] = {1, 1, 0, 0, 0, 1, 0x67};
    assert(tb_dec_set_param_sets(decoder, params, sizeof(params)) == 0);
    assert(decoder->opened);

    /* A rejected codec payload must preserve the current codec and extradata. */
    const uint8_t malformed[] = {2, 1, 0};
    uint8_t *original = decoder->extradata;
    assert(tb_dec_set_param_sets(decoder, malformed, sizeof(malformed)) == -1);
    assert(decoder->codec_id == AV_CODEC_ID_H264 && decoder->extradata == original);

    const uint8_t changed[] = {1, 1, 0, 0, 0, 1, 0x68};
    allocations_before_failure = 1; /* Allow new param data, fail context copy. */
    assert(tb_dec_set_param_sets(decoder, changed, sizeof(changed)) == -1);
    assert(!decoder->opened && decoder->ctx == NULL);
    assert(tb_dec_feed_frame(decoder, params, sizeof(params)) == -1);

    allocations_before_failure = -1;
    fail_open = 1;
    assert(tb_dec_set_param_sets(decoder, params, sizeof(params)) == -1);
    assert(!decoder->opened && decoder->ctx == NULL);
    fail_open = 0;
    assert(tb_dec_set_param_sets(decoder, params, sizeof(params)) == 0);

    uint8_t *annexb = NULL;
    size_t annexb_length = 0;
    const uint8_t incomplete[] = {0, 0, 0};
    assert(avcc_to_annexb(decoder, incomplete, sizeof(incomplete), &annexb, &annexb_length) == -1);
    tb_dec_reset(decoder);
    assert(tb_dec_observed_hardware(decoder) == -1);
    assert(!decoder->opened && decoder->ctx == NULL && decoder->extradata == NULL);
    tb_dec_destroy(decoder);
    puts("decoder: allocation failure, failed reopen, recovery and truncated NAL checks passed");
    return 0;
}
