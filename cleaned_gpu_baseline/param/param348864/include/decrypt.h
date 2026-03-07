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


__constant__ gf d_L[SYS_N];



unsigned char *d_ciphertexts;
gf *d_inverse_elements;
__device__       gf d_L_global[SYS_N];
// gf images[SYS_N];
// gf error[SYS_T];
// int tv;
unsigned char secretkeys[crypto_kem_SECRETKEYBYTES];
unsigned char ciphertexts[KATNUM][crypto_kem_CIPHERTEXTBYTES];
// int e[SYS_N / 8];
// int i, w = 0, j, k;
gf g[SYS_T + 1];
gf L[SYS_N];
// gf s[SYS_T * 2];
// gf e_inv_LOOP_1D[sb * 2 * SYS_T];
gf inverse_elements[sb][2 * SYS_T];
// gf temp;
gf e_inv[SYS_N];
unsigned char r[SYS_N / 8];
gf locator[SYS_T + 1];
// gf t, c[SYS_N];
clock_t start, end;
double avg_cpu_time_used;
double cpu_printing;
double synd_time = 0, bm_time = 0, root_time = 0;
unsigned char *sk = NULL;
int count;
// unsigned char h_error[KATNUM][SYS_N];

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
static __device__ inline gf p_gf_sq(gf in)
{
	const uint32_t B[] = {0x55555555, 0x33333333, 0x0F0F0F0F, 0x00FF00FF};

	uint32_t x = in; 
	uint32_t t;

	x = (x | (x << 8)) & B[3];
	x = (x | (x << 4)) & B[2];
	x = (x | (x << 2)) & B[1];
	x = (x | (x << 1)) & B[0];

	t = x & 0x7FC000;
	x ^= t >> 9;
	x ^= t >> 12;

	t = x & 0x3000;
	x ^= t >> 9;
	x ^= t >> 12;

	return x & ((1 << GFBITS)-1);
}
__device__ __forceinline__ gf p_gf_inv(gf in) {
    // return gf_inverse_table[in];
    gf tmp_11;
    gf tmp_1111;

    gf out = in;

    out = p_gf_sq(out);
    tmp_11 = mul(out, in); // 11

    out = p_gf_sq(tmp_11);
    out = p_gf_sq(out);
    tmp_1111 = mul(out, tmp_11); // 1111

    out = p_gf_sq(tmp_1111);
    out = p_gf_sq(out);
    out = p_gf_sq(out);
    out = p_gf_sq(out);
    out = mul(out, tmp_1111); // 11111111

    out = p_gf_sq(out);
    out = p_gf_sq(out);
    out = mul(out, tmp_11); // 1111111111

    out = p_gf_sq(out);
    out = mul(out, in); // 11111111111

    return p_gf_sq(out); // 111111111110
}

__device__ __forceinline__ gf p_gf_frac(gf den, gf num) {
    return mul(p_gf_inv(den), num);
}

void InitializeC() {
    // const int N = 1 << GFBITS;
    cudaMemcpyToSymbol(d_L, L, SYS_N * sizeof(gf), 0, cudaMemcpyHostToDevice);
    cudaMemcpy(
     d_L_global,
     L,
     SYS_N * sizeof(gf),
     cudaMemcpyHostToDevice
 ) ;
    cudaMalloc(&d_ciphertexts, crypto_kem_CIPHERTEXTBYTES * KATNUM);
    size_t size = sizeof(gf) * sb * 2 * SYS_T;
    cudaMalloc(&d_inverse_elements, size);
    cudaMemcpy(d_inverse_elements, inverse_elements, size, cudaMemcpyHostToDevice);
    
}

#endif // DECRYPT_H
