#ifndef TINY_AES_C_AES_H
#define TINY_AES_C_AES_H

#include <openssl/aes.h>
#include <stdint.h>

struct AES_ctx {
    AES_KEY round_key;
};

void AES_init_ctx(struct AES_ctx *ctx, const uint8_t *key);
void AES_ECB_encrypt(const struct AES_ctx *ctx, uint8_t *buf);

#endif
