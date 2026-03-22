/*
 * Optimised CUDA decryption driver for the `348864` parameter family.
 *
 * The logical stages are still syndrome generation, Berlekamp-Massey, and
 * Chien search, but the kernels use packed/shared-memory layouts to reduce
 * traffic and improve throughput.
 */
#include <sys/stat.h>   // mkdir
#include "decrypt.h"               // KATNUM, SYS_T, SYS_N, sb, etc.
#include <cuda_runtime.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

using C4 = uchar4;                  // four packed ciphertext bytes



////////////////////////////////////////////////////////////////////////////////
//  Kernel 1 – compute 2·t syndromes (new “SyndromeKernel”)
////////////////////////////////////////////////////////////////////////////////
__global__ void SyndromeKernel(
    const gf  * __restrict__ d_inverse_elements,
    const unsigned char * __restrict__ d_ciphertexts,
    gf        * __restrict__ d_syndromes)
{
    // ---- Shared memory (static) ----
    __shared__ gf c[sb];              // unpacked bits   (sb ≤ 24576)
    __shared__ gf s_out[2 * SYS_T];   // 2·t accumulators

    const int tid    = threadIdx.x;
    const int ct     = blockIdx.x;               // one block per CT
    const int vecCnt = SYND_BYTES >> 2;          // SYND_BYTES/4

    // 1) unpack ciphertext into bit array
    for (int v = tid; v < vecCnt; v += blockDim.x) {
        uchar4 chunk = reinterpret_cast<const uchar4*>(
                          d_ciphertexts + ct * SYND_BYTES)[v];
        unsigned r0 = chunk.x, r1 = chunk.y,
                 r2 = chunk.z, r3 = chunk.w;

        #pragma unroll
        for (int b = 0; b < 8; ++b) {
            int baseBit = (v << 5) + b;  // v*32 + b
            if (baseBit < sb)       c[baseBit]       = (r0 >> b) & 1u;
            if (baseBit+8  < sb)    c[baseBit + 8]   = (r1 >> b) & 1u;
            if (baseBit+16 < sb)    c[baseBit + 16]  = (r2 >> b) & 1u;
            if (baseBit+24 < sb)    c[baseBit + 24]  = (r3 >> b) & 1u;
        }
    }
    __syncthreads();

    // 2) dot‑product with inverse table
    if (tid < 2 * SYS_T) {
        const int stride = 2 * SYS_T;
        const gf *col = d_inverse_elements + tid;

        gf acc = 0;
        #pragma unroll 8
        for (int bit = 0; bit < sb; ++bit) {
            gf mask = -(gf)(c[bit] & 1u);   // 0 or 0xFFFF
            acc ^= (col[0] & mask);
            col += stride;
        }
        s_out[tid] = acc;
    }
    __syncthreads();

    // 3) write back
    if (tid < 2 * SYS_T) {
        d_syndromes[ct * (2 * SYS_T) + tid] = s_out[tid];
    }
}

// 12‑bit gf packed into 32 bits to avoid bank conflicts
__device__ __forceinline__ uint32_t pack(gf x){ return (uint32_t)(x & GFMASK); }
__device__ __forceinline__ gf       unpack(uint32_t x){ return (gf)(x & GFMASK); }

__global__ void berlekampMasseyKernel(const gf *__restrict__ d_syn,
                                      gf       *__restrict__ d_loc)
{
    const int tid    = threadIdx.x;
    const int lane   = tid & 31;
    const int wid    = tid >> 5;
    const int nwarps = blockDim.x >> 5;          // e.g., 96 threads -> 3 warps
    const int ct     = blockIdx.y;

    // --- shared ---
    __shared__ uint32_t S32[2*SYS_T];            // packed syndromes
    __shared__ uint32_t C0[SYS_T+1], C1[SYS_T+1];
    __shared__ uint32_t B0[SYS_T+1], B1[SYS_T+1];
    __shared__ gf warpXor[8];                    // up to 8 warps per block

    __shared__ gf b;      // last non‑zero discrepancy
    __shared__ int L;     // current locator degree
    __shared__ gf d;      // discrepancy this iter
    __shared__ gf f;      // d / b
    __shared__ gf m_nz;   // 0xFFFF if d!=0 else 0
    __shared__ gf m_big;  // 0xFFFF if (d!=0 && 2L<=N) else 0

    // Load syndromes for this codeword
    for (int i = tid; i < 2*SYS_T; i += blockDim.x)
        S32[i] = pack(__ldg(&d_syn[ct*(2*SYS_T) + i]));
    __syncthreads();

    // Init: C=1, B=x (so that B represents x^{N-m} from start with m=-1)
    if (tid <= SYS_T){
        C0[tid] = pack(tid == 0 ? 1 : 0);
        C1[tid] = 0;
        B0[tid] = pack(tid == 1 ? 1 : 0);   // x
        B1[tid] = 0;
    }
    if (tid == 0){ b = 1; L = 0; }
    __syncthreads();

    uint32_t *Cprv = C0, *Ccur = C1;
    uint32_t *Bprv = B0, *Bcur = B1;

    for (int N = 0; N < 2*SYS_T; ++N)
    {
        // ---- discrepancy: d = sum_{j=0}^{min(L,N)} C[j] * S[N-j]
        gf part = 0;
        int upto = L; if (upto > N) upto = N;
        for (int j = tid; j <= upto; j += blockDim.x)
            part ^= mul(unpack(Cprv[j]), unpack(S32[N - j]));

        // warp reduction
        for (int off = 16; off; off >>= 1)
            part ^= __shfl_down_sync(0xffffffffu, part, off);
        if (lane == 0) warpXor[wid] = part;
        __syncthreads();

        if (tid == 0){
            d = 0;
            #pragma unroll
            for (int w = 0; w < nwarps; ++w) d ^= warpXor[w];

            const bool nz  = (d != 0);
            const bool big = nz && (2*L <= N);

            m_nz  = nz  ? (gf)0xFFFF : 0;
            m_big = big ? (gf)0xFFFF : 0;

            // NOTE: p_gf_frac(den, num) expected -> returns num/den
            // So pass (b, d) to compute d / b.
            f = nz ? p_gf_frac(b, d) : 0;

            if (big){ b = d; L = N + 1 - L; }
        }
        __syncthreads();

        // ---- update C and B (masked, single pass) ----
        if (tid <= SYS_T){
            const int j = tid;

            const gf Cold = unpack(Cprv[j]);
            const gf Bj   = unpack(Bprv[j]);

            const gf addv = (gf)(mul(f, Bj) & m_nz);  // only if d!=0
            Ccur[j] = pack(Cold ^ addv);

            // Bcur = x * ( big ? Cprv : Bprv )
            const gf fromC = (j ? unpack(Cprv[j-1]) : 0);
            const gf fromB = (j ? unpack(Bprv[j-1]) : 0);
            const gf chosen = (gf)((fromB & ~m_big) | (fromC & m_big));
            Bcur[j] = pack(chosen);
        }
        __syncthreads();

        // swap buffers for next iteration
        uint32_t *tmp;
        tmp=Cprv; Cprv=Ccur; Ccur=tmp;
        tmp=Bprv; Bprv=Bcur; Bcur=tmp;
        __syncthreads();
    }

    // write locator polynomial in ORIGINAL layout: d_loc[j * pitch + ct]
    if (tid <= SYS_T){
        const int pitch = gridDim.y;
        d_loc[tid * pitch + ct] = unpack(Cprv[tid]);
    }
}


__global__ void warp_chien_search_kernel(
    const gf* __restrict__ d_sigma_soa,   // [SYS_T+1][BATCH]  SoA
    uint32_t* __restrict__ d_err_all,     // [BATCH][SYS_N/32] bitpacked
    int BATCH)
{
    const int lane          = threadIdx.x & 31;          // 0..31
    const int warp_local    = threadIdx.x >> 5;          // 0..(warps_per_block-1)
    const int warps_per_blk = blockDim.x >> 5; 
    const int warp_global   = blockIdx.x * warps_per_blk + warp_local;

    if (warp_global >= BATCH) return;

    const int err_offset = warp_global * (SYS_N / 32);

    extern __shared__ gf s_flat[];
    gf *s_sigma = s_flat + warp_local * (SYS_T + 1);

    // load sigma of this ciphertext into shared
    for (int i = lane; i <= SYS_T; i += 32) {
        s_sigma[i] = d_sigma_soa[i * BATCH + warp_global];
    }
    __syncwarp();

    // stride-32 over positions
    for (int pos = lane; pos < SYS_N; pos += 32) {
        gf a   = d_L[pos];
        gf sum = s_sigma[0];

        #pragma unroll
        for (int i = 1; i <= SYS_T; ++i) {
            sum = mul(sum, a) ^ s_sigma[i];
        }

        if (sum == 0) {
            int w = pos >> 5;
            int b = pos & 31;
            atomicOr(&d_err_all[err_offset + w], 1u << b);
        }
    }
}


/*
 * Process the full ciphertext batch in host-sized chunks so the packed CUDA
 * data structures remain bounded and easy to map back to the CPU output.
 */
void decrypt(unsigned char (*ciphertexts)[crypto_kem_CIPHERTEXTBYTES]) {
    const int total        = KATNUM;
    const int batchSize    = BATCH_SIZE;
    const int tpb          = 128;                 // threads/block (multiple of 32)
    const int warps_per_bl = tpb / 32;
    const int wordPerBatch = SYS_N / 32;

    unsigned char *d_ct;
    gf           *d_syn, *d_loc_soa;
    uint32_t     *d_err;
    uint32_t     *h_err;
    gf           *h_loc;

    cudaMalloc(&d_ct,       batchSize * crypto_kem_CIPHERTEXTBYTES);
    cudaMalloc(&d_syn,      batchSize * 2 * SYS_T * sizeof(gf));
    cudaMalloc(&d_loc_soa, (SYS_T + 1) * batchSize * sizeof(gf));
    cudaMalloc(&d_err,      batchSize * wordPerBatch * sizeof(uint32_t));
    cudaMallocHost(&h_err,  batchSize * wordPerBatch * sizeof(uint32_t));
    cudaMallocHost(&h_loc, (SYS_T + 1) * batchSize * sizeof(gf));

    int batchCount = (total + batchSize - 1) / batchSize;

    for (int b = 0; b < batchCount; ++b) {
        int offset      = b * batchSize;
        int actualBatch = (offset + batchSize > total) ? (total - offset) : batchSize;

        cudaMemcpy(d_ct, &ciphertexts[offset],
                   actualBatch * crypto_kem_CIPHERTEXTBYTES,
                   cudaMemcpyHostToDevice);
        cudaMemset(d_err, 0, actualBatch * wordPerBatch * sizeof(uint32_t));


           {
       // each block handles one ciphertext
       dim3 gridSyn(actualBatch,1,1);
       // no dynamic shared‑size here (uses static __shared__ arrays)
       SyndromeKernel<<<gridSyn,256,0>>>(
           d_inverse_elements,
           d_ct,
           d_syn
       );
   }
        // 2) BM

        berlekampMasseyKernel<<< dim3(1, actualBatch), 128 >>>(d_syn, d_loc_soa);
        cudaDeviceSynchronize();

        // 3) Warp Chien
        int blocks = (actualBatch + warps_per_bl - 1) / warps_per_bl;
        dim3 grid(blocks, 1, 1);
        dim3 block(tpb,   1, 1);
        size_t shmem = warps_per_bl * (SYS_T + 1) * sizeof(gf);

        warp_chien_search_kernel<<<grid, block, shmem>>>(d_loc_soa, d_err, actualBatch);
        cudaDeviceSynchronize();

        cudaMemcpy(h_err, d_err,
                   actualBatch * wordPerBatch * sizeof(uint32_t),
                   cudaMemcpyDeviceToHost);
        cudaDeviceSynchronize();

#if WRITE_ERRORSTREAM
        {
            FILE *f = fopen("../../results/output/errorstream0_348864.bin", "ab");
            if (f) {
                for (int ct_idx = 0; ct_idx < actualBatch; ++ct_idx) {
                    uint32_t *words = h_err + ct_idx * wordPerBatch;
                    for (int w = 0; w < wordPerBatch; ++w) {
                        uint32_t mask = words[w];
                        while (mask) {
                            int bit = __builtin_ctz(mask);
                            fprintf(f, " %d", (w << 5) + bit);
                            mask &= (mask - 1);
                        }
                    }
                    fputc('\n', f);
                }
                fclose(f);
            } else {
                perror("fopen(\"../../results/output/errorstream0_348864.bin\")");
            }
        }
#endif

    }

    cudaFree(d_ct);
    cudaFree(d_syn);
    cudaFree(d_loc_soa);
    cudaFree(d_err);
    cudaFreeHost(h_err);
    cudaFreeHost(h_loc);
    cudaDeviceReset();

}








int main(void)
{ 
    initialisation(secretkeys, ciphertexts, sk, L, g);
    compute_inverses();
    InitializeC();

    decrypt(ciphertexts);
    cudaDeviceReset();
    return 0;
}
// -----------------------------------------------------------------------------
