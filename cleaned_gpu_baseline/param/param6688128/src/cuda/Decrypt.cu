#include <sys/stat.h>   // mkdir
#include "decrypt.h"               // KATNUM, SYS_T, SYS_N, sb, etc.
#include <cuda_runtime.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

using C4 = uchar4;                  // four packed ciphertext bytes





// ------------------------------------------------------------------------
// Block‐reduction syndrome kernel:
//   • one block per (coeff, ciphertext) pair: grid = {2*SYS_T, KATNUM}
//   • 256 threads per block
//   • each thread processes a strided subset of bits, XORs partial sums
//   • warp‐wide __shfl_down_sync reduction, then block‐wide shared‐mem reduction
// ------------------------------------------------------------------------
__global__ void SyndromeKernel(
    const gf*           __restrict__ d_inverse_elements, // [bit][coeff]
    const unsigned char* __restrict__ d_ciphertexts,     // SYND_BYTES per CT
          gf*           __restrict__ d_syndromes         // KATNUM×(2*SYS_T)
) { 
    extern __shared__ gf warp_sums[];  // one entry per warp (256/32 = 8 warps)

    const int cf      = blockIdx.x;    // coefficient index [0..2*SYS_T)
    const int ct      = blockIdx.y;    // ciphertext index [0..KATNUM)
    const int lane    = threadIdx.x;   // 0..255
    const int warpId  = lane >> 5;     // 0..7
    const int laneInW = lane & 31;     // 0..31
    const int stride  = 2 * SYS_T;

    // 1) each thread XOR-accumulates its share of sb bits
    gf sum = 0;
    for (int bit = lane; bit < sb; bit += blockDim.x) {
        unsigned char r = d_ciphertexts[ ct * SYND_BYTES + (bit >> 3) ];
        if ((r >> (bit & 7)) & 1U) {
            sum ^= d_inverse_elements[ bit * stride + cf ];
        }
    }

    // 2) warp‐local reduction via shuffle
    #pragma unroll
    for (int offset = 16; offset > 0; offset >>= 1) {
        sum ^= __shfl_down_sync(0xFFFFFFFF, sum, offset);
    }
    // lane 0 of each warp writes its partial into shared memory
    if (laneInW == 0) {
        warp_sums[warpId] = sum;
    }
    __syncthreads();

    // 3) block‐wide reduction of the 8 warp sums (only warp 0 participates)
    if (warpId == 0) {
        if (laneInW < (blockDim.x / 32)) {
            sum = warp_sums[laneInW];
            // accumulate the other warp sums
            for (int w = laneInW + 1; w < (blockDim.x/32); ++w) {
                sum ^= warp_sums[w];
            }
            // lane 0 writes the final syndrome
            if (laneInW == 0) {
                d_syndromes[ ct * stride + cf ] = sum;
            }
        }
    }
}


__global__ void berlekampMasseyKernel(const gf *d_syn,
                                      gf       *d_loc)
{
    /* block bookkeeping ---------------------------------------------------- */
    const int tid = threadIdx.x;        // local thread ID
    const int ct  = blockIdx.y;         // ciphertext / code-word index

    /* shared scratch ------------------------------------------------------- */
    __shared__ gf S[2 * SYS_T];         // syndromes
    __shared__ gf C[SYS_T + 1];         // current locator  C(x)
    __shared__ gf B[SYS_T + 1];         // previous locator B(x)
    __shared__ gf T[SYS_T + 1];         // temp copy
    __shared__ gf b;                    // last non-zero discrepancy
    __shared__ int L;                   // current degree
    __shared__ gf d;                    // current discrepancy

    /* 0. load syndromes for this ciphertext -------------------------------- */
    if (tid < 2 * SYS_T)
        S[tid] = d_syn[ct * (2 * SYS_T) + tid];
    __syncthreads();

    /* 1. initialise BM state (thread 0) ------------------------------------ */
    if (tid == 0)
    {
        for (int i = 0; i <= SYS_T; ++i) {
            C[i] = 0;
            B[i] = 0;
        }
        C[0] = 1;       /*  C(x) = 1       */
        B[1] = 1;       /*  B(x) = x       */
        b    = 1;
        L    = 0;
    }
    __syncthreads();

    /* 2. Berlekamp–Massey main loop ---------------------------------------- */
    for (int N = 0; N < 2 * SYS_T; ++N)
    {
        /* 2.1  discrepancy   d = Σ_{j=0}^{min(N,T)} C[j] · S[N-j] ---------- */
        if (tid == 0)
        {
            d = 0;
            const int max_j = min(N, SYS_T);
            for (int j = 0; j <= max_j; ++j)
                d ^= mul(C[j], S[N - j]);
        }
        __syncthreads();

        /* 2.2  locator update (still thread 0 only) ------------------------ */
        if (tid == 0 && d != 0)
        {
            const gf f = p_gf_frac(b, d);   /* f = d / b in GF(2^m) */

            /* copy C → T, then C ← C ⊕ f·B */
            for (int i = 0; i <= SYS_T; ++i) T[i] = C[i];
            for (int i = 0; i <= SYS_T; ++i) C[i] ^= mul(f, B[i]);

            if (2 * L <= N)                 /* “big” update branch  */
            {
                for (int i = 0; i <= SYS_T; ++i) B[i] = T[i];
                L = N + 1 - L;
                b = d;
            }
        }
        __syncthreads();

        /* 2.3  shift   B(x) ← x·B(x)  (done by thread 0, perfectly fine) ---- */
        if (tid == 0)
        {
            for (int i = SYS_T; i >= 1; --i) B[i] = B[i - 1];
            B[0] = 0;
        }
        __syncthreads();
    }

    /* 3. write locator coefficients in reverse order ----------------------- */
    if (tid <= SYS_T)
        d_loc[ct * (SYS_T + 1) + tid] = C[SYS_T - tid];
}

__global__ void chien_search_kernel(
    const gf * __restrict__ d_sigma_all,   // (batch × (T+1))  – locators
    unsigned char * __restrict__ d_error_all) // (batch × N)  – error vectors
{
    const int ct  = blockIdx.y;          // ciphertext (same as before)
    const int tid = threadIdx.x;         // only tid==0 will be active

    // One thread per CTA does the entire Chien search serially
    if (tid == 0)
    {
        const gf *sigma = d_sigma_all + ct * (SYS_T + 1);
        unsigned char *err = d_error_all + ct * SYS_N;

        // Loop over all codeword positions i = 0 … N-1
        for (int i = 0; i < SYS_N; ++i)
        {
            // αᵢ is stored in constant memory prepared by the host
            gf a   = d_L[i];
            gf val = sigma[SYS_T];

            // Horner evaluation of σ(a⁻¹)  (same as CPU reference)
            for (int j = SYS_T - 1; j >= 0; --j)
                val = mul(val, a) ^ sigma[j];

            // Write error flag: 1 if σ(αᵢ⁻¹) == 0, else 0
            err[i] = (val == 0);
        }
    }
}



static void decrypt(unsigned char (*ciphertexts)[crypto_kem_CIPHERTEXTBYTES])
{
    const int total     = KATNUM;
    const int batchSize = BATCH_SIZE;

    unsigned char *d_ct   = NULL;
    gf           *d_syn   = NULL;
    gf           *d_loc   = NULL;
    unsigned char *d_err  = NULL;
    unsigned char *h_err_batch = NULL;

    CUDA_CHECK(cudaMalloc(&d_ct,  batchSize * crypto_kem_CIPHERTEXTBYTES));
    CUDA_CHECK(cudaMalloc(&d_syn, batchSize * 2 * SYS_T * sizeof(gf)));
    CUDA_CHECK(cudaMalloc(&d_loc, batchSize * (SYS_T + 1) * sizeof(gf)));
    CUDA_CHECK(cudaMalloc(&d_err, batchSize * SYS_N * sizeof(unsigned char)));
    CUDA_CHECK(cudaMallocHost(&h_err_batch, batchSize * SYS_N * sizeof(unsigned char)));

    cudaEvent_t ev_h2d_s, ev_h2d_e, ev_syn_s, ev_syn_e, ev_bm_s, ev_bm_e, ev_ch_s, ev_ch_e, ev_d2h_s, ev_d2h_e;
    CUDA_CHECK(cudaEventCreate(&ev_h2d_s));
    CUDA_CHECK(cudaEventCreate(&ev_h2d_e));
    CUDA_CHECK(cudaEventCreate(&ev_syn_s));
    CUDA_CHECK(cudaEventCreate(&ev_syn_e));
    CUDA_CHECK(cudaEventCreate(&ev_bm_s));
    CUDA_CHECK(cudaEventCreate(&ev_bm_e));
    CUDA_CHECK(cudaEventCreate(&ev_ch_s));
    CUDA_CHECK(cudaEventCreate(&ev_ch_e));
    CUDA_CHECK(cudaEventCreate(&ev_d2h_s));
    CUDA_CHECK(cudaEventCreate(&ev_d2h_e));

    float total_h2d_ms = 0.f, total_syn_ms = 0.f, total_bm_ms = 0.f, total_ch_ms = 0.f, total_d2h_ms = 0.f;

    struct timespec wall_s, wall_e;
    clock_gettime(CLOCK_MONOTONIC, &wall_s);

    const int batchCount = (total + batchSize - 1) / batchSize;

    for (int b = 0; b < batchCount; ++b) {
        const int offset      = b * batchSize;
        const int actualBatch = (offset + batchSize > total) ? (total - offset) : batchSize;

        float h2d_ms = 0, syn_ms = 0, bm_ms = 0, ch_ms = 0, d2h_ms = 0;

        CUDA_CHECK(cudaEventRecord(ev_h2d_s));
        CUDA_CHECK(cudaMemcpy(d_ct, &ciphertexts[offset][0],
                              actualBatch * crypto_kem_CIPHERTEXTBYTES,
                              cudaMemcpyHostToDevice));
        CUDA_CHECK(cudaEventRecord(ev_h2d_e));

        CUDA_CHECK(cudaEventRecord(ev_syn_s));
        dim3 grids(2 * SYS_T, KATNUM);  // one block per (coeff, CT)
        // shared mem = one gf per warp
            const int threadsPerBlock = 256;
        size_t sharedMem = (threadsPerBlock / 32) * sizeof(gf);
        SyndromeKernel<<<grids, threadsPerBlock, sharedMem>>>(d_inverse_elements, d_ct, d_syn);
        CUDA_CHECK(cudaEventRecord(ev_syn_e));
           


        CUDA_CHECK(cudaEventRecord(ev_bm_s));
        berlekampMasseyKernel<<<dim3(1, actualBatch), 256>>>(d_syn, d_loc);
        CUDA_CHECK(cudaEventRecord(ev_bm_e));
        // print the d_loc for the first few ciphertexts for debugging
//         gf *h_loc = (gf *)malloc(actualBatch * (SYS_T + 1) * sizeof(gf));   
//         CUDA_CHECK(cudaMemcpy(h_loc, d_loc, actualBatch * (SYS_T + 1) * sizeof(gf), cudaMemcpyDeviceToHost));
//         for (int i = 0; i < min(5, actualBatch); ++
// i) {
//             printf("Ciphertext %d (locator):\n  ", offset + i);
//             for (int j = 0; j <= SYS_T; ++j) {
//                 printf("%04x ", h_loc[j * actualBatch + i]);
//             }
//             printf("\n");
//         }
        // free(h_loc);
        CUDA_CHECK(cudaEventRecord(ev_ch_s));
        chien_search_kernel<<<dim3(1, actualBatch), 32>>>(d_loc, d_err);
        CUDA_CHECK(cudaEventRecord(ev_ch_e));

        CUDA_CHECK(cudaEventRecord(ev_d2h_s));
        CUDA_CHECK(cudaMemcpy(h_err_batch, d_err,
                              actualBatch * SYS_N * sizeof(unsigned char),
                              cudaMemcpyDeviceToHost));
        CUDA_CHECK(cudaEventRecord(ev_d2h_e));

        CUDA_CHECK(cudaDeviceSynchronize());

        CUDA_CHECK(cudaEventElapsedTime(&h2d_ms, ev_h2d_s, ev_h2d_e));
        CUDA_CHECK(cudaEventElapsedTime(&syn_ms, ev_syn_s, ev_syn_e));
        CUDA_CHECK(cudaEventElapsedTime(&bm_ms,  ev_bm_s,  ev_bm_e));
        CUDA_CHECK(cudaEventElapsedTime(&ch_ms,  ev_ch_s,  ev_ch_e));
        CUDA_CHECK(cudaEventElapsedTime(&d2h_ms, ev_d2h_s, ev_d2h_e));

        total_h2d_ms += h2d_ms;
        total_syn_ms += syn_ms;
        total_bm_ms  += bm_ms;
        total_ch_ms  += ch_ms;
        total_d2h_ms += d2h_ms;

        // Write result to disk
#if WRITE_ERRORSTREAM
        {
            FILE *f = fopen("../../results/output/errorstream0_6688128.bin", "ab");
            if (f) {
                for (int ct_idx = 0; ct_idx < actualBatch; ++ct_idx) {
                    unsigned char *e = h_err_batch + ct_idx * SYS_N;
                    for (int i = 0; i < SYS_N; ++i) {
                        if (e[i]) fprintf(f, " %d", i);
                    }
                    fputc('\n', f);
                }
                fclose(f);
            } else {
                perror("fopen(\"../../results/output/errorstream0_6688128.bin\")");
            }
        }
        #endif


    clock_gettime(CLOCK_MONOTONIC, &wall_e);
    double wall_ms = (wall_e.tv_sec - wall_s.tv_sec) * 1000.0 + (wall_e.tv_nsec - wall_s.tv_nsec) / 1e6;

    double kern_sum_ms = total_syn_ms + total_bm_ms + total_ch_ms;
    double transfer_ms = total_h2d_ms + total_d2h_ms;
    double overhead_ms = wall_ms - (kern_sum_ms + transfer_ms);

    
    {
        FILE *f = fopen("../../results/profile/Profile_GPU_baseline_6688128.txt", "a");
        if (f) {
            fprintf(f,
                "\n=== TIMING SUMMARY (batchSize=%d, total=%d) ===\n"
                "H2D:   %.3f ms\n"
                "Synd:  %.3f ms\n"
                "BM:    %.3f ms\n"
                "Chien: %.3f ms\n"
                "D2H:   %.3f ms\n"
                "Wall:  %.3f ms\n"
                "Overhead (Wall - H2D-D2H-Kernels): %.3f ms\n"
                "Throughput: %.2f ct/s\n",
                batchSize, total,
                total_h2d_ms, total_syn_ms, total_bm_ms, total_ch_ms, total_d2h_ms,
                wall_ms, overhead_ms,
                (1000.0 * total) / wall_ms);
            fclose(f);
        } else {
            fprintf(stderr, "Warning: could not open timing.txt for writing\n");
        }
    }
fflush(stdout);
    }
    CUDA_CHECK(cudaEventDestroy(ev_h2d_s)); CUDA_CHECK(cudaEventDestroy(ev_h2d_e));
    CUDA_CHECK(cudaEventDestroy(ev_syn_s)); CUDA_CHECK(cudaEventDestroy(ev_syn_e));
    CUDA_CHECK(cudaEventDestroy(ev_bm_s));  CUDA_CHECK(cudaEventDestroy(ev_bm_e));
    CUDA_CHECK(cudaEventDestroy(ev_ch_s));  CUDA_CHECK(cudaEventDestroy(ev_ch_e));
    CUDA_CHECK(cudaEventDestroy(ev_d2h_s)); CUDA_CHECK(cudaEventDestroy(ev_d2h_e));

    CUDA_CHECK(cudaFree(d_ct));
    CUDA_CHECK(cudaFree(d_syn));
    CUDA_CHECK(cudaFree(d_loc));
    CUDA_CHECK(cudaFree(d_err));
    CUDA_CHECK(cudaFreeHost(h_err_batch));

}



int main(void)
{ 
    //   unsigned char (*ciphertexts)[crypto_kem_CIPHERTEXTBYTES] =  malloc(KATNUM * sizeof(*ciphertexts));
    cudaDeviceReset();
    initialisation(secretkeys, ciphertexts, sk, L, g);
    compute_inverses();
    InitializeC();
    decrypt(ciphertexts);
    return 0;
}
