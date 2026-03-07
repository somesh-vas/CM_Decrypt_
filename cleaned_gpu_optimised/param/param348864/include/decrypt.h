#ifndef DECRYPT_H
#define DECRYPT_H
#include <nvtx3/nvToolsExt.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>
#include "gf.h"
#include "common.h"
#include "root.h"

#define GFLUT_ORDER   ((1u << GFBITS) - 1u)
#define GFLUT_SIZE    (1u << GFBITS)

/* -------------------- device-side constant tables -------------------- */
__constant__ gf       d_L[SYS_N];                 /* support points (α_i^{-1}) */
__constant__ gf       gf_inverse_table[1 << GFBITS];   /* field inverses */
__constant__ uint32_t c_lane_bit[32];             /* 1u<<lane precomputed      */
__constant__ uint8_t  c_maxj[2 * SYS_T];          /* max_j for BM loop         */

/* -------------------- existing globals (host / device) -------------------- */
gf* d_L_aligned;
unsigned char *d_ciphertexts;
gf *d_inverse_elements;

/* keep if you still read it somewhere */
__device__ gf d_L_global[SYS_N];

gf images[SYS_N];
gf error[SYS_T];
int tv;
unsigned char secretkeys[crypto_kem_SECRETKEYBYTES];
unsigned char ciphertexts[KATNUM][crypto_kem_CIPHERTEXTBYTES];
int e[SYS_N / 8];
int i, w = 0, j, k;
gf g[SYS_T + 1];
gf L[SYS_N];
gf s[SYS_T * 2];
gf e_inv_LOOP_1D[sb * 2 * SYS_T];
gf inverse_elements[sb][2 * SYS_T];
gf temp;
gf e_inv[SYS_N];
unsigned char r[SYS_N / 8];
gf locator[SYS_T + 1];
gf t, c[SYS_N];
clock_t start, end;
double avg_cpu_time_used;
double cpu_printing;
double synd_time = 0, bm_time = 0, root_time = 0;
unsigned char *sk = NULL;
int count;

/* -------------------- device helpers -------------------- */
__device__ __forceinline__ gf add(gf in0, gf in1) {
    return in0 ^ in1;
}

__device__ __forceinline__ gf mul(gf in0, gf in1) {
    int i;
    uint32_t tmp = 0;
    uint32_t t0 = in0;
    uint32_t t1 = in1;
    uint32_t t;
    tmp = t0 * (t1 & 1);
    for (i = 1; i < GFBITS; i++) {
        tmp ^= (t0 * (t1 & (1 << i)));
    }
    t = tmp & 0x7FC000;
    tmp ^= t >> 9;
    tmp ^= t >> 12;
    t = tmp & 0x3000;
    tmp ^= t >> 9;
    tmp ^= t >> 12;
    return tmp & ((1 << GFBITS) - 1);
}

__device__ __forceinline__ gf p_gf_inv(gf in) {
    return gf_inverse_table[in];
}

/* num/den */
__device__ __forceinline__ gf p_gf_frac(gf den, gf num) {
    return mul(num, p_gf_inv(den));
}

/* -------------------- host initializer -------------------- */
static inline void InitializeC(void) {
    /* 1) field inverse LUT */
    const int N = 1 << GFBITS;
    gf host_inv[N];
    host_inv[0] = 0;
    for (int i = 1; i < N; i++) host_inv[i] = gf_inv((gf)i);
    cudaMemcpyToSymbol(gf_inverse_table, host_inv, sizeof(host_inv), 0, cudaMemcpyHostToDevice);

    /* 2) support points */
    cudaMemcpyToSymbol(d_L, L, SYS_N * sizeof(gf), 0, cudaMemcpyHostToDevice);

    /* mirror for any legacy reads */
    cudaMemcpyToSymbol(d_L_global, L, SYS_N * sizeof(gf), 0, cudaMemcpyHostToDevice);

    /* 3) lane bit masks */
    uint32_t h_lane_bit[32];
    for (int b = 0; b < 32; ++b) h_lane_bit[b] = (1u << b);
    cudaMemcpyToSymbol(c_lane_bit, h_lane_bit, sizeof(h_lane_bit), 0, cudaMemcpyHostToDevice);

    /* 4) BM max_j table */
    uint8_t h_maxj[2 * SYS_T];
    for (int Nn = 0; Nn < 2 * SYS_T; ++Nn) h_maxj[Nn] = (uint8_t)((Nn < SYS_T) ? Nn : SYS_T);
    cudaMemcpyToSymbol(c_maxj, h_maxj, sizeof(h_maxj), 0, cudaMemcpyHostToDevice);

    /* 5) device buffers used elsewhere */
    cudaMalloc(&d_ciphertexts, crypto_kem_CIPHERTEXTBYTES * KATNUM);

    size_t inv_size = sizeof(gf) * sb * 2 * SYS_T;
    cudaMalloc(&d_inverse_elements, inv_size);
    cudaMemcpy(d_inverse_elements, inverse_elements, inv_size, cudaMemcpyHostToDevice);

    cudaMalloc(&d_L_aligned, SYS_N * sizeof(gf));
    cudaMemcpy(d_L_aligned, L, SYS_N * sizeof(gf), cudaMemcpyHostToDevice);
}

#endif // DECRYPT_H


