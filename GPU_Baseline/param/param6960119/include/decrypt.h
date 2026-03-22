#ifndef DECRYPT_H
#define DECRYPT_H

/*
 * Shared CUDA-facing declarations for the baseline `6960119` implementation.
 *
 * This header collects the device lookup tables, long-lived host globals, and
 * small device-side GF helpers used across the CUDA translation unit.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#include <cuda_runtime.h>
#include <device_launch_parameters.h>

#include "common.h"
#include "gf.h"
#include "root.h"

#define CUDA_CHECK(call)                                                     \
    do {                                                                     \
        cudaError_t err__ = (call);                                          \
        if (err__ != cudaSuccess) {                                          \
            fprintf(                                                         \
                stderr,                                                      \
                "CUDA error at %s:%d: %s\n",                                 \
                __FILE__,                                                    \
                __LINE__,                                                    \
                cudaGetErrorString(err__));                                  \
            exit(EXIT_FAILURE);                                              \
        }                                                                    \
    } while (0)

/* Device-resident support points and inverse lookup tables. */
__constant__ gf d_L[SYS_N];
__constant__ gf gf_inverse_table[1 << GFBITS];

extern gf *d_inverse_elements;

/* Shared host-side decode state populated before any kernel launches. */
extern unsigned char secretkeys[crypto_kem_SECRETKEYBYTES];
extern unsigned char ciphertexts[KATNUM][crypto_kem_CIPHERTEXTBYTES];
extern gf g[SYS_T + 1];
extern gf L[SYS_N];
extern gf inverse_elements[sb][2 * SYS_T];
extern gf e_inv[SYS_N];

__device__ __forceinline__ gf mul(gf lhs, gf rhs)
{
    uint64_t product = (uint64_t)lhs * (rhs & 1u);

    for (int bit = 1; bit < GFBITS; ++bit) {
        product ^= (uint64_t)lhs * (rhs & (1u << bit));
    }

    uint64_t reduction = product & 0x1FF0000u;
    product ^= (reduction >> 9) ^ (reduction >> 10) ^ (reduction >> 12) ^ (reduction >> 13);

    reduction = product & 0x000E000u;
    product ^= (reduction >> 9) ^ (reduction >> 10) ^ (reduction >> 12) ^ (reduction >> 13);

    return (gf)(product & GFMASK);
}

__device__ __forceinline__ gf p_gf_inv(gf value)
{
    return gf_inverse_table[value];
}

__device__ __forceinline__ gf p_gf_sqmul(gf value, gf multiplier)
{
    uint64_t x;
    uint64_t t0 = value;
    uint64_t t1 = multiplier;
    uint64_t reduction;
    const uint64_t masks[] = {
        0x0000001FF0000000ULL,
        0x000000000FF80000ULL,
        0x000000000007E000ULL,
    };

    x = (t1 << 6) * (t0 & (1u << 6));
    t0 ^= (t0 << 7);

    x ^= t1 * (t0 & 0x04001u);
    x ^= (t1 * (t0 & 0x08002u)) << 1;
    x ^= (t1 * (t0 & 0x10004u)) << 2;
    x ^= (t1 * (t0 & 0x20008u)) << 3;
    x ^= (t1 * (t0 & 0x40010u)) << 4;
    x ^= (t1 * (t0 & 0x80020u)) << 5;

    for (int index = 0; index < 3; ++index) {
        reduction = x & masks[index];
        x ^= (reduction >> 9) ^ (reduction >> 10) ^ (reduction >> 12) ^ (reduction >> 13);
    }

    return (gf)(x & GFMASK);
}

__device__ __forceinline__ gf p_gf_frac(gf denominator, gf numerator)
{
    return p_gf_sqmul(p_gf_inv(denominator), numerator);
}

static inline void initialize_cuda_state(void)
{
    const int field_size = 1 << GFBITS;
    gf host_inv[field_size];
    size_t inverse_bytes = sizeof(gf) * sb * 2 * SYS_T;

    /* Build lookup tables on the host, then upload them once per process run. */
    host_inv[0] = 0;
    for (int index = 1; index < field_size; ++index) {
        host_inv[index] = gf_preinv_for_table((gf)index);
    }

    CUDA_CHECK(cudaMemcpyToSymbol(gf_inverse_table, host_inv, sizeof(host_inv)));
    CUDA_CHECK(cudaMemcpyToSymbol(d_L, L, SYS_N * sizeof(gf)));

    if (d_inverse_elements != NULL) {
        CUDA_CHECK(cudaFree(d_inverse_elements));
        d_inverse_elements = NULL;
    }

    CUDA_CHECK(cudaMalloc(&d_inverse_elements, inverse_bytes));
    CUDA_CHECK(cudaMemcpy(d_inverse_elements, inverse_elements, inverse_bytes, cudaMemcpyHostToDevice));
}

static inline void release_cuda_state(void)
{
    if (d_inverse_elements != NULL) {
        CUDA_CHECK(cudaFree(d_inverse_elements));
        d_inverse_elements = NULL;
    }
}

#endif /* DECRYPT_H */
