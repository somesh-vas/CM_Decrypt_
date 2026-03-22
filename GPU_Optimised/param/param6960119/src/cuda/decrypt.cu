#define _POSIX_C_SOURCE 200809L

#include <sys/stat.h>   // mkdir
#include "decrypt.h"               // KATNUM, SYS_T, SYS_N, sb, etc.
#include <cuda_runtime.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

using C4 = uchar4;                  // four packed ciphertext bytes

static const char profile_label[] = "GPU optimised";
#define MAX_RUNTIME_PATH 4096

typedef struct {
    float h2d_ms;
    float synd_ms;
    float bm_ms;
    float chien_ms;
    float d2h_ms;
} timing_totals_t;

static double elapsed_wall_ms(const struct timespec *start, const struct timespec *end)
{
    return (end->tv_sec - start->tv_sec) * 1000.0
         + (end->tv_nsec - start->tv_nsec) / 1e6;
}

static int build_project_relative_path(char *buffer, size_t size, const char *relative_suffix)
{
    char exe_path[MAX_RUNTIME_PATH];
    char *cursor = NULL;
    ssize_t length = readlink("/proc/self/exe", exe_path, sizeof(exe_path) - 1);

    if (length < 0) {
        perror("readlink(/proc/self/exe)");
        return -1;
    }

    exe_path[length] = '\0';

    cursor = strrchr(exe_path, '/');
    if (cursor == NULL) {
        fprintf(stderr, "failed to resolve executable directory\n");
        return -1;
    }
    *cursor = '\0'; /* .../GPU_Optimised/bin */

    cursor = strrchr(exe_path, '/');
    if (cursor == NULL) {
        fprintf(stderr, "failed to resolve project directory\n");
        return -1;
    }
    *cursor = '\0'; /* .../GPU_Optimised */

    if (snprintf(buffer, size, "%s/%s", exe_path, relative_suffix) >= (int)size) {
        fprintf(stderr, "resolved path is too long: %s\n", relative_suffix);
        return -1;
    }

    return 0;
}

static int write_profile_summary(const timing_totals_t *totals, int batch_size, int total, double wall_ms)
{
    char profile_path[MAX_RUNTIME_PATH];
    FILE *stream = NULL;
    double throughput = wall_ms > 0.0 ? (1000.0 * total) / wall_ms : 0.0;
    double kernel_ms = totals->synd_ms + totals->bm_ms + totals->chien_ms;
    double transfer_ms = totals->h2d_ms + totals->d2h_ms;
    double overhead_ms = wall_ms - (kernel_ms + transfer_ms);

    if (build_project_relative_path(
            profile_path,
            sizeof(profile_path),
            "results/profile/Profile_GPU_optimised_6960119.txt") != 0) {
        return 1;
    }

    stream = fopen(profile_path, "w");

    if (stream == NULL) {
        perror("failed to open GPU optimised profile output");
        return 1;
    }

    fprintf(
        stream,
        "===== %s =====\n"
        "ciphertexts processed : %d\n"
        "batch size            : %d\n"
        "H2D                   : %.3f ms\n"
        "syndrome              : %.3f ms\n"
        "Berlekamp-Massey      : %.3f ms\n"
        "Chien search          : %.3f ms\n"
        "D2H                   : %.3f ms\n"
        "wall                  : %.3f ms\n"
        "overhead              : %.3f ms\n"
        "throughput            : %.2f ct/s\n",
        profile_label,
        total,
        batch_size,
        totals->h2d_ms,
        totals->synd_ms,
        totals->bm_ms,
        totals->chien_ms,
        totals->d2h_ms,
        wall_ms,
        overhead_ms,
        throughput);

    fclose(stream);
    return 0;
}



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

    // 1) zero the unpack buffer, including the padded bits at the end.
    for (int bit = tid; bit < sb; bit += blockDim.x) {
        c[bit] = 0;
    }
    __syncthreads();

    // 2) unpack every ciphertext byte. This is slightly less vectorised than
    // uchar4 loading, but it correctly handles 6960119's 194-byte syndrome.
    for (int byte = tid; byte < SYND_BYTES; byte += blockDim.x) {
        unsigned value = d_ciphertexts[ct * SYND_BYTES + byte];
        int baseBit = byte << 3;

        #pragma unroll
        for (int b = 0; b < 8; ++b) {
            if (baseBit + b < sb) {
                c[baseBit + b] = (value >> b) & 1u;
            }
        }
    }
    __syncthreads();

    // 3) dot-product with inverse table
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

    // 4) write back
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
    const int packed_words = (SYS_N + 31) / 32;
    const int lane          = threadIdx.x & 31;          // 0..31
    const int warp_local    = threadIdx.x >> 5;          // 0..(warps_per_block-1)
    const int warps_per_blk = blockDim.x >> 5; 
    const int warp_global   = blockIdx.x * warps_per_blk + warp_local;

    if (warp_global >= BATCH) return;

    const int err_offset = warp_global * packed_words;

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


int decrypt(unsigned char (*ciphertexts)[crypto_kem_CIPHERTEXTBYTES]) {
    const int total        = KATNUM;
    const int batchSize    = BATCH_SIZE;
    const int tpb          = 128;                 // threads/block (multiple of 32)
    const int warps_per_bl = tpb / 32;
    /* 6960 is not divisible by 32, so the packed error buffer needs the ceiling. */
    const int wordPerBatch = (SYS_N + 31) / 32;

    unsigned char *d_ct;
    gf           *d_syn, *d_loc_soa;
    uint32_t     *d_err;
    uint32_t     *h_err;
    gf           *h_loc;
    timing_totals_t totals = {};
    struct timespec wall_start;
    struct timespec wall_end;
    struct timespec stage_start;
    struct timespec stage_end;
    int status = 0;

    cudaMalloc(&d_ct,       batchSize * crypto_kem_CIPHERTEXTBYTES);
    cudaMalloc(&d_syn,      batchSize * 2 * SYS_T * sizeof(gf));
    cudaMalloc(&d_loc_soa, (SYS_T + 1) * batchSize * sizeof(gf));
    cudaMalloc(&d_err,      batchSize * wordPerBatch * sizeof(uint32_t));
    cudaMallocHost(&h_err,  batchSize * wordPerBatch * sizeof(uint32_t));
    cudaMallocHost(&h_loc, (SYS_T + 1) * batchSize * sizeof(gf));

    int batchCount = (total + batchSize - 1) / batchSize;
    clock_gettime(CLOCK_MONOTONIC, &wall_start);

    for (int b = 0; b < batchCount; ++b) {
        int offset      = b * batchSize;
        int actualBatch = (offset + batchSize > total) ? (total - offset) : batchSize;
        float h2d_ms = 0.0f;
        float synd_ms = 0.0f;
        float bm_ms = 0.0f;
        float chien_ms = 0.0f;
        float d2h_ms = 0.0f;

        clock_gettime(CLOCK_MONOTONIC, &stage_start);
        cudaMemcpy(d_ct, &ciphertexts[offset],
                   actualBatch * crypto_kem_CIPHERTEXTBYTES,
                   cudaMemcpyHostToDevice);
        clock_gettime(CLOCK_MONOTONIC, &stage_end);
        h2d_ms = (float)elapsed_wall_ms(&stage_start, &stage_end);
        cudaMemset(d_err, 0, actualBatch * wordPerBatch * sizeof(uint32_t));


        clock_gettime(CLOCK_MONOTONIC, &stage_start);
        {
            // each block handles one ciphertext
            dim3 gridSyn(actualBatch,1,1);
            // no dynamic shared-size here (uses static __shared__ arrays)
            SyndromeKernel<<<gridSyn,256,0>>>(
                d_inverse_elements,
                d_ct,
                d_syn
            );
        }
        cudaDeviceSynchronize();
        clock_gettime(CLOCK_MONOTONIC, &stage_end);
        synd_ms = (float)elapsed_wall_ms(&stage_start, &stage_end);
        // 2) BM

        clock_gettime(CLOCK_MONOTONIC, &stage_start);
        berlekampMasseyKernel<<< dim3(1, actualBatch), 256 >>>(d_syn, d_loc_soa);
        cudaDeviceSynchronize();
        clock_gettime(CLOCK_MONOTONIC, &stage_end);
        bm_ms = (float)elapsed_wall_ms(&stage_start, &stage_end);

        // 3) Warp Chien
        int blocks = (actualBatch + warps_per_bl - 1) / warps_per_bl;
        dim3 grid(blocks, 1, 1);
        dim3 block(tpb,   1, 1);
        size_t shmem = warps_per_bl * (SYS_T + 1) * sizeof(gf);

        clock_gettime(CLOCK_MONOTONIC, &stage_start);
        warp_chien_search_kernel<<<grid, block, shmem>>>(d_loc_soa, d_err, actualBatch);
        cudaDeviceSynchronize();
        clock_gettime(CLOCK_MONOTONIC, &stage_end);
        chien_ms = (float)elapsed_wall_ms(&stage_start, &stage_end);

        clock_gettime(CLOCK_MONOTONIC, &stage_start);
        cudaMemcpy(h_err, d_err,
                   actualBatch * wordPerBatch * sizeof(uint32_t),
                   cudaMemcpyDeviceToHost);
        clock_gettime(CLOCK_MONOTONIC, &stage_end);
        d2h_ms = (float)elapsed_wall_ms(&stage_start, &stage_end);

        totals.h2d_ms += h2d_ms;
        totals.synd_ms += synd_ms;
        totals.bm_ms += bm_ms;
        totals.chien_ms += chien_ms;
        totals.d2h_ms += d2h_ms;

#if WRITE_ERRORSTREAM
        {
            char errorstream_path[MAX_RUNTIME_PATH];
            FILE *f = NULL;

            if (build_project_relative_path(
                    errorstream_path,
                    sizeof(errorstream_path),
                    "results/output/errorstream0_6960119.bin") != 0) {
                status = 1;
                break;
            }

            f = fopen(errorstream_path, "ab");
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
                perror("failed to open GPU optimised errorstream output");
                status = 1;
                break;
            }
        }
#endif
    }

    if (status == 0) {
        clock_gettime(CLOCK_MONOTONIC, &wall_end);
        status = write_profile_summary(&totals, batchSize, total, elapsed_wall_ms(&wall_start, &wall_end));
    }

    cudaFree(d_ct);
    cudaFree(d_syn);
    cudaFree(d_loc_soa);
    cudaFree(d_err);
    cudaFreeHost(h_err);
    cudaFreeHost(h_loc);
    cudaDeviceReset();
    return status;
}








int main(void)
{ 
    if (initialisation(secretkeys, ciphertexts, sk, L, g) != 0) {
        return 1;
    }
    compute_inverses();
    InitializeC();

    return decrypt(ciphertexts);
}
// -----------------------------------------------------------------------------
