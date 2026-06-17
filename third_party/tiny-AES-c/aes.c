#include "aes.h"

void AES_init_ctx(struct AES_ctx *ctx, const uint8_t *key)
{
    AES_set_encrypt_key(key, 256, &ctx->round_key);
}

void AES_ECB_encrypt(const struct AES_ctx *ctx, uint8_t *buf)
{
    AES_encrypt(buf, buf, &ctx->round_key);
}
