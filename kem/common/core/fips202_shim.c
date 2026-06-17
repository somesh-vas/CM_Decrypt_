#include "fips202_shim.h"

#include <stdint.h>
#include <string.h>

#define SHAKE256_RATE 136
#define KECCAKF_ROUNDS 24

static uint64_t load64(const unsigned char x[8])
{
    uint64_t r = 0;

    for (int i = 0; i < 8; i++) {
        r |= (uint64_t)x[i] << (8 * i);
    }

    return r;
}

static void store64(unsigned char x[8], uint64_t u)
{
    for (int i = 0; i < 8; i++) {
        x[i] = (unsigned char)(u >> (8 * i));
    }
}

static uint64_t rol64(uint64_t x, int offset)
{
    return (x << offset) | (x >> (64 - offset));
}

static void keccakf1600(uint64_t state[25])
{
    static const uint64_t round_constants[KECCAKF_ROUNDS] = {
        UINT64_C(0x0000000000000001), UINT64_C(0x0000000000008082),
        UINT64_C(0x800000000000808a), UINT64_C(0x8000000080008000),
        UINT64_C(0x000000000000808b), UINT64_C(0x0000000080000001),
        UINT64_C(0x8000000080008081), UINT64_C(0x8000000000008009),
        UINT64_C(0x000000000000008a), UINT64_C(0x0000000000000088),
        UINT64_C(0x0000000080008009), UINT64_C(0x000000008000000a),
        UINT64_C(0x000000008000808b), UINT64_C(0x800000000000008b),
        UINT64_C(0x8000000000008089), UINT64_C(0x8000000000008003),
        UINT64_C(0x8000000000008002), UINT64_C(0x8000000000000080),
        UINT64_C(0x000000000000800a), UINT64_C(0x800000008000000a),
        UINT64_C(0x8000000080008081), UINT64_C(0x8000000000008080),
        UINT64_C(0x0000000080000001), UINT64_C(0x8000000080008008),
    };
    static const int rho_offsets[25] = {
        0,  1, 62, 28, 27,
       36, 44,  6, 55, 20,
        3, 10, 43, 25, 39,
       41, 45, 15, 21,  8,
       18,  2, 61, 56, 14,
    };
    uint64_t c[5];
    uint64_t d[5];
    uint64_t b[25];

    for (int round = 0; round < KECCAKF_ROUNDS; round++) {
        for (int x = 0; x < 5; x++) {
            c[x] = state[x] ^ state[x + 5] ^ state[x + 10] ^ state[x + 15] ^ state[x + 20];
        }

        for (int x = 0; x < 5; x++) {
            d[x] = c[(x + 4) % 5] ^ rol64(c[(x + 1) % 5], 1);
        }

        for (int x = 0; x < 5; x++) {
            for (int y = 0; y < 5; y++) {
                state[x + 5 * y] ^= d[x];
            }
        }

        for (int x = 0; x < 5; x++) {
            for (int y = 0; y < 5; y++) {
                b[y + 5 * ((2 * x + 3 * y) % 5)] = rol64(state[x + 5 * y], rho_offsets[x + 5 * y]);
            }
        }

        for (int x = 0; x < 5; x++) {
            for (int y = 0; y < 5; y++) {
                state[x + 5 * y] = b[x + 5 * y] ^ ((~b[((x + 1) % 5) + 5 * y]) & b[((x + 2) % 5) + 5 * y]);
            }
        }

        state[0] ^= round_constants[round];
    }
}

void SHAKE256(unsigned char *output,
              size_t outputByteLen,
              const unsigned char *input,
              unsigned long long inputByteLen)
{
    uint64_t state[25] = {0};
    unsigned char block[SHAKE256_RATE];

    while (inputByteLen >= SHAKE256_RATE) {
        for (int i = 0; i < SHAKE256_RATE / 8; i++) {
            state[i] ^= load64(input + 8 * i);
        }
        keccakf1600(state);
        input += SHAKE256_RATE;
        inputByteLen -= SHAKE256_RATE;
    }

    memset(block, 0, sizeof(block));
    memcpy(block, input, (size_t)inputByteLen);
    block[inputByteLen] = 0x1f;
    block[SHAKE256_RATE - 1] |= 0x80;

    for (int i = 0; i < SHAKE256_RATE / 8; i++) {
        state[i] ^= load64(block + 8 * i);
    }
    keccakf1600(state);

    while (outputByteLen > 0) {
        size_t block_len = outputByteLen < SHAKE256_RATE ? outputByteLen : SHAKE256_RATE;

        for (int i = 0; i < SHAKE256_RATE / 8; i++) {
            store64(block + 8 * i, state[i]);
        }

        memcpy(output, block, block_len);
        output += block_len;
        outputByteLen -= block_len;

        if (outputByteLen > 0) {
            keccakf1600(state);
        }
    }
}
