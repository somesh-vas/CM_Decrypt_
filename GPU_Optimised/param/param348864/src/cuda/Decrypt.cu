#define _POSIX_C_SOURCE 200809L

/*
 * Optimised CUDA decryption driver for the `348864` parameter family.
 *
 * The logical stages are still syndrome generation, Berlekamp-Massey, and
 * Chien search, but the kernels use packed/shared-memory layouts to reduce
 * traffic and improve throughput.
 */
#include <sys/stat.h>   // mkdir
#include "decrypt.h"               // KATNUM, SYS_T, SYS_N, sb, etc.
#include "errorstream_split.h"
#include <cuda_runtime.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#ifdef min
#undef min
#endif
#ifdef max
#undef max
#endif
#include <string>
#include <sys/types.h>
#include <time.h>
#include <unistd.h>

using C4 = uchar4;                  // four packed ciphertext bytes

static const char profile_label[] = "GPU optimised";
#define MAX_RUNTIME_PATH 4096
static struct timespec g_total_wall_start;

typedef struct {
    float setup_init_ms;
    float alloc_setup_ms;
    float h2d_ms;
    float synd_ms;
    float bm_ms;
    float chien_ms;
    float d2h_ms;
    float host_scan_ms;
    float host_format_ms;
    float host_file_write_ms;
    float host_output_ms;
    float profile_write_ms;
    unsigned long long output_bytes;
    unsigned long long output_items;
    int formatter_mode;
} timing_totals_t;

static double g_setup_init_ms = 0.0;

typedef enum {
    CM_ERRORSTREAM_WRITER_OLD = 0,
    CM_ERRORSTREAM_WRITER_FAST = 1,
} cm_errorstream_writer_t;

typedef enum {
    CM_ERRORSTREAM_FORMATTER_BASELINE = 0,
    CM_ERRORSTREAM_FORMATTER_FASTLUT_V2 = 1,
} cm_errorstream_formatter_t;

typedef enum {
    CM_CHIEN_IMPL_BASELINE = 0,
    CM_CHIEN_IMPL_BITSLICE32 = 1,
} cm_chien_impl_mode_t;

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
    *cursor = '\0';

    cursor = strrchr(exe_path, '/');
    if (cursor == NULL) {
        fprintf(stderr, "failed to resolve project directory\n");
        return -1;
    }
    *cursor = '\0';

    if (snprintf(buffer, size, "%s/%s", exe_path, relative_suffix) >= (int)size) {
        fprintf(stderr, "resolved path is too long: %s\n", relative_suffix);
        return -1;
    }

    return 0;
}

static int write_profile_summary(const timing_totals_t *totals, int batch_size, int total, double wall_before_profile_ms)
{
    char profile_path[MAX_RUNTIME_PATH];
    char profile_body[2048];
    FILE *stream = NULL;
    double kernel_ms = totals->synd_ms + totals->bm_ms + totals->chien_ms;
    double measured_without_profile_ms =
        totals->setup_init_ms +
        totals->alloc_setup_ms +
        totals->h2d_ms +
        totals->synd_ms +
        totals->bm_ms +
        totals->chien_ms +
        totals->d2h_ms +
        totals->host_output_ms;
    double profile_write_ms = totals->profile_write_ms;

    if (build_project_relative_path(
            profile_path,
            sizeof(profile_path),
            "results/profile/Profile_GPU_optimised_348864.txt") != 0) {
        return 1;
    }

    for (int pass = 0; pass < 3; ++pass) {
        struct timespec write_start;
        struct timespec write_end;
        double wall_ms = wall_before_profile_ms + profile_write_ms;
        double measured_total_ms = measured_without_profile_ms + profile_write_ms;
        double overhead_ms = wall_ms - measured_total_ms;
        double throughput = wall_ms > 0.0 ? (1000.0 * total) / wall_ms : 0.0;
        double kernel_throughput = kernel_ms > 0.0 ? (1000.0 * total) / kernel_ms : 0.0;
        int body_len = snprintf(
            profile_body,
            sizeof(profile_body),
            "===== %s =====\n"
            "ciphertexts processed : %d\n"
            "batch size            : %d\n"
            "setup/init            : %.3f ms\n"
            "alloc/setup           : %.3f ms\n"
            "H2D                   : %.3f ms\n"
            "syndrome              : %.3f ms\n"
            "Berlekamp-Massey      : %.3f ms\n"
            "Chien search          : %.3f ms\n"
            "D2H                   : %.3f ms\n"
            "host scan             : %.3f ms\n"
            "host format           : %.3f ms\n"
            "host file write       : %.3f ms\n"
            "host output           : %.3f ms\n"
            "formatter mode        : %s\n"
            "profile write         : %.3f ms\n"
            "output bytes          : %llu\n"
            "output items          : %llu\n"
            "wall                  : %.3f ms\n"
            "measured total        : %.3f ms\n"
            "unattributed overhead : %.3f ms\n"
            "throughput            : %.2f ct/s\n"
            "kernel throughput     : %.2f ct/s\n",
            profile_label,
            total,
            batch_size,
            totals->setup_init_ms,
            totals->alloc_setup_ms,
            totals->h2d_ms,
            totals->synd_ms,
            totals->bm_ms,
            totals->chien_ms,
            totals->d2h_ms,
            totals->host_scan_ms,
            totals->host_format_ms,
            totals->host_file_write_ms,
            totals->host_output_ms,
            totals->formatter_mode == CM_ERRORSTREAM_FORMATTER_FASTLUT_V2 ? "fastlut_v2" : "baseline",
            profile_write_ms,
            totals->output_bytes,
            totals->output_items,
            wall_ms,
            measured_total_ms,
            overhead_ms,
            throughput,
            kernel_throughput);

        if (body_len < 0 || body_len >= (int)sizeof(profile_body)) {
            fprintf(stderr, "profile summary buffer overflow\n");
            return 1;
        }

        clock_gettime(CLOCK_MONOTONIC, &write_start);
        stream = fopen(profile_path, "w");
        if (stream == NULL) {
            perror("failed to open GPU optimised profile output");
            return 1;
        }
        if (fwrite(profile_body, 1, (size_t)body_len, stream) != (size_t)body_len) {
            perror("failed to write GPU optimised profile output");
            fclose(stream);
            return 1;
        }
        if (fclose(stream) != 0) {
            perror("failed to close GPU optimised profile output");
            return 1;
        }
        stream = NULL;
        clock_gettime(CLOCK_MONOTONIC, &write_end);
        profile_write_ms = elapsed_wall_ms(&write_start, &write_end);
    }

    return 0;
}

static cm_errorstream_writer_t get_errorstream_writer_mode(void)
{
    const char *mode = getenv("CM_ERRORSTREAM_WRITER");

    if (mode == NULL || mode[0] == '\0' || strcmp(mode, "fast") == 0) {
        return CM_ERRORSTREAM_WRITER_FAST;
    }
    if (strcmp(mode, "old") == 0) {
        return CM_ERRORSTREAM_WRITER_OLD;
    }

    fprintf(stderr, "unknown CM_ERRORSTREAM_WRITER=%s\n", mode);
    exit(1);
}

static cm_errorstream_formatter_t get_errorstream_formatter_mode(void)
{
    const char *mode = getenv("CM_ERRORSTREAM_FORMATTER");

    if (mode == NULL || mode[0] == '\0' || strcmp(mode, "baseline") == 0) {
        return CM_ERRORSTREAM_FORMATTER_BASELINE;
    }
    if (strcmp(mode, "fastlut_v2") == 0) {
        return CM_ERRORSTREAM_FORMATTER_FASTLUT_V2;
    }

    fprintf(stderr, "unknown CM_ERRORSTREAM_FORMATTER=%s\n", mode);
    exit(1);
}

static cm_chien_impl_mode_t get_chien_impl_mode(void)
{
    const char *mode = getenv("CM_CHIEN_IMPL");

    if (mode == NULL || mode[0] == '\0' || strcmp(mode, "bitslice32") == 0) {
        return CM_CHIEN_IMPL_BITSLICE32;
    }
    if (strcmp(mode, "baseline") == 0) {
        return CM_CHIEN_IMPL_BASELINE;
    }

    fprintf(stderr, "unknown CM_CHIEN_IMPL=%s\n", mode);
    exit(1);
}

static int should_validate_fast_errorstream(void)
{
    const char *value = getenv("CM_VALIDATE_FAST_ERRORSTREAM");
    return value != NULL && strcmp(value, "1") == 0;
}

static int should_split_errorstream_chunks(void)
{
    const char *value = getenv("CM_ERRORSTREAM_SPLIT_CHUNKS");
    return value != NULL && strcmp(value, "1") == 0;
}

typedef struct {
    unsigned char length;
    char bytes[8];
} decimal_token_entry_t;

static decimal_token_entry_t g_decimal_token_lut[SYS_N];
static int g_decimal_token_lut_ready = 0;

static void ensure_decimal_token_lut_ready(void)
{
    if (g_decimal_token_lut_ready) {
        return;
    }

    for (int value = 0; value < SYS_N; ++value) {
        decimal_token_entry_t *entry = &g_decimal_token_lut[value];
        unsigned int number = (unsigned int)value;
        char reversed[8];
        int reversed_len = 0;
        int length = 0;

        entry->bytes[length++] = ' ';
        if (number == 0) {
            entry->bytes[length++] = '0';
        } else {
            while (number > 0) {
                reversed[reversed_len++] = (char)('0' + (number % 10u));
                number /= 10u;
            }
            while (reversed_len > 0) {
                entry->bytes[length++] = reversed[--reversed_len];
            }
        }
        entry->length = (unsigned char)length;
    }

    g_decimal_token_lut_ready = 1;
}

static inline void append_decimal_token(std::string *buffer, int value)
{
    char digits[16];
    int length = 0;
    unsigned int number = (unsigned int)value;

    digits[length++] = ' ';
    if (number == 0) {
        digits[length++] = '0';
    } else {
        char reversed[16];
        int reversed_len = 0;
        while (number > 0) {
            reversed[reversed_len++] = (char)('0' + (number % 10u));
            number /= 10u;
        }
        while (reversed_len > 0) {
            digits[length++] = reversed[--reversed_len];
        }
    }
    buffer->append(digits, (size_t)length);
}

static int append_errorstream_fast(
    std::string *buffer,
    const uint32_t *h_err,
    int actual_batch,
    int word_per_batch,
    unsigned long long *output_items)
{
    for (int ct_idx = 0; ct_idx < actual_batch; ++ct_idx) {
        const uint32_t *words = h_err + ct_idx * word_per_batch;
        for (int w = 0; w < word_per_batch; ++w) {
            uint32_t mask = words[w];
            while (mask) {
                int bit = __builtin_ctz(mask);
                append_decimal_token(buffer, (w << 5) + bit);
                ++(*output_items);
                mask &= (mask - 1);
            }
        }
        buffer->push_back('\n');
    }
    return 0;
}

static int append_errorstream_fastlut_v2(
    std::string *buffer,
    const uint32_t *h_err,
    int actual_batch,
    int word_per_batch,
    unsigned long long *output_items)
{
    for (int ct_idx = 0; ct_idx < actual_batch; ++ct_idx) {
        const uint32_t *words = h_err + ct_idx * word_per_batch;
        for (int w = 0; w < word_per_batch; ++w) {
            uint32_t mask = words[w];
            int base = w << 5;
            while (mask) {
                int bit = __builtin_ctz(mask);
                const decimal_token_entry_t *entry = &g_decimal_token_lut[base + bit];
                buffer->append(entry->bytes, (size_t)entry->length);
                ++(*output_items);
                mask &= (mask - 1);
            }
        }
        buffer->push_back('\n');
    }
    return 0;
}

static int append_errorstream_reference_memory(
    std::string *buffer,
    const uint32_t *h_err,
    int actual_batch,
    int word_per_batch,
    unsigned long long *output_items)
{
    char token[32];

    for (int ct_idx = 0; ct_idx < actual_batch; ++ct_idx) {
        const uint32_t *words = h_err + ct_idx * word_per_batch;
        for (int w = 0; w < word_per_batch; ++w) {
            uint32_t mask = words[w];
            while (mask) {
                int bit = __builtin_ctz(mask);
                int token_len = snprintf(token, sizeof(token), " %d", (w << 5) + bit);
                if (token_len < 0 || token_len >= (int)sizeof(token)) {
                    fprintf(stderr, "reference token formatting overflow\n");
                    return 1;
                }
                buffer->append(token, (size_t)token_len);
                ++(*output_items);
                mask &= (mask - 1);
            }
        }
        buffer->push_back('\n');
    }
    return 0;
}

static int write_errorstream_old_file(
    FILE *stream,
    const uint32_t *h_err,
    int actual_batch,
    int word_per_batch,
    unsigned long long *output_items)
{
    for (int ct_idx = 0; ct_idx < actual_batch; ++ct_idx) {
        const uint32_t *words = h_err + ct_idx * word_per_batch;
        for (int w = 0; w < word_per_batch; ++w) {
            uint32_t mask = words[w];
            while (mask) {
                int bit = __builtin_ctz(mask);
                if (fprintf(stream, " %d", (w << 5) + bit) < 0) {
                    perror("failed to format GPU optimised errorstream output");
                    return 1;
                }
                ++(*output_items);
                mask &= (mask - 1);
            }
        }
        if (fputc('\n', stream) == EOF) {
            perror("failed to write newline to GPU optimised errorstream output");
            return 1;
        }
    }
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

static int validate_bitslice32_against_baseline(
    const uint32_t *baseline_h_err,
    const uint32_t *bitslice_h_err,
    int actual_batch,
    int word_per_batch,
    cm_errorstream_formatter_t formatter_mode)
{
    size_t total_words = (size_t)actual_batch * (size_t)word_per_batch;
    size_t mismatch_word = 0;

    while (mismatch_word < total_words &&
           baseline_h_err[mismatch_word] == bitslice_h_err[mismatch_word]) {
        ++mismatch_word;
    }
    if (mismatch_word != total_words) {
        size_t ct_idx = mismatch_word / (size_t)word_per_batch;
        size_t word_idx = mismatch_word % (size_t)word_per_batch;
        fprintf(stderr,
                "CM_VALIDATE_FAST_ERRORSTREAM=1 bitslice32 raw compare failed: ct=%zu word=%zu baseline=0x%08x bitslice=0x%08x\n",
                ct_idx, word_idx, baseline_h_err[mismatch_word], bitslice_h_err[mismatch_word]);
        return 1;
    }

    unsigned long long baseline_items = 0;
    unsigned long long bitslice_items = 0;
    std::string baseline_buffer;
    std::string bitslice_buffer;
    if ((formatter_mode == CM_ERRORSTREAM_FORMATTER_FASTLUT_V2
             ? append_errorstream_fastlut_v2(&baseline_buffer, baseline_h_err, actual_batch, word_per_batch, &baseline_items)
             : append_errorstream_fast(&baseline_buffer, baseline_h_err, actual_batch, word_per_batch, &baseline_items)) != 0) {
        return 1;
    }
    if ((formatter_mode == CM_ERRORSTREAM_FORMATTER_FASTLUT_V2
             ? append_errorstream_fastlut_v2(&bitslice_buffer, bitslice_h_err, actual_batch, word_per_batch, &bitslice_items)
             : append_errorstream_fast(&bitslice_buffer, bitslice_h_err, actual_batch, word_per_batch, &bitslice_items)) != 0) {
        return 1;
    }
    if (baseline_items != bitslice_items || baseline_buffer != bitslice_buffer) {
        size_t mismatch_offset = 0;
        size_t limit = baseline_buffer.size() < bitslice_buffer.size() ? baseline_buffer.size() : bitslice_buffer.size();
        while (mismatch_offset < limit && baseline_buffer[mismatch_offset] == bitslice_buffer[mismatch_offset]) {
            ++mismatch_offset;
        }
        fprintf(stderr,
                "CM_VALIDATE_FAST_ERRORSTREAM=1 bitslice32 byte compare failed: baseline_bytes=%zu bitslice_bytes=%zu baseline_items=%llu bitslice_items=%llu first_mismatch_offset=%zu\n",
                baseline_buffer.size(), bitslice_buffer.size(), baseline_items, bitslice_items, mismatch_offset);
        return 1;
    }

    fprintf(stderr,
            "CM_VALIDATE_FAST_ERRORSTREAM=1 bitslice32 byte compare passed: bytes=%zu items=%llu\n",
            bitslice_buffer.size(), bitslice_items);
    return 0;
}

__device__ __forceinline__ uint32_t bitslice_coeff_mask(gf value, int bit)
{
    return ((value >> bit) & 1) ? 0xFFFFFFFFu : 0u;
}

__device__ __forceinline__ void bitslice_mul_masks(
    uint32_t out[GFBITS],
    const uint32_t left[GFBITS],
    const uint32_t right[GFBITS])
{
    uint32_t poly[2 * GFBITS - 1];
    #pragma unroll
    for (int i = 0; i < 2 * GFBITS - 1; ++i) poly[i] = 0u;
    #pragma unroll
    for (int i = 0; i < GFBITS; ++i) {
        #pragma unroll
        for (int j = 0; j < GFBITS; ++j) poly[i + j] ^= left[i] & right[j];
    }
    #pragma unroll
    for (int deg = 2 * GFBITS - 2; deg >= GFBITS; --deg) {
        uint32_t fold = poly[deg];
        poly[deg - 9] ^= fold;
        poly[deg - 12] ^= fold;
    }
    #pragma unroll
    for (int i = 0; i < GFBITS; ++i) out[i] = poly[i];
}

__global__ void warp_chien_search_kernel_bitslice32(
    const gf* __restrict__ d_sigma_soa,
    uint32_t* __restrict__ d_err_all,
    int BATCH)
{
    const int packed_words = (SYS_N + 31) / 32;
    const int lane = threadIdx.x & 31;
    const int warp_local = threadIdx.x >> 5;
    const int warps_per_blk = blockDim.x >> 5;
    const int warp_global = blockIdx.x * warps_per_blk + warp_local;
    if (warp_global >= BATCH) return;

    const int err_offset = warp_global * packed_words;
    extern __shared__ gf s_flat[];
    gf *s_sigma = s_flat + warp_local * (SYS_T + 1);
    for (int i = lane; i <= SYS_T; i += 32) s_sigma[i] = d_sigma_soa[i * BATCH + warp_global];
    __syncwarp();

    for (int group = lane; group < packed_words; group += 32) {
        uint32_t x_bits[GFBITS];
        uint32_t eval[GFBITS];
        uint32_t prod[GFBITS];
        #pragma unroll
        for (int bit = 0; bit < GFBITS; ++bit) {
            x_bits[bit] = d_support_bits[group][bit];
            eval[bit] = bitslice_coeff_mask(s_sigma[0], bit);
        }
        #pragma unroll 1
        for (int coeff_idx = 1; coeff_idx <= SYS_T; ++coeff_idx) {
            bitslice_mul_masks(prod, eval, x_bits);
            #pragma unroll
            for (int bit = 0; bit < GFBITS; ++bit) eval[bit] = prod[bit] ^ bitslice_coeff_mask(s_sigma[coeff_idx], bit);
        }
        uint32_t nonzero_mask = 0u;
        #pragma unroll
        for (int bit = 0; bit < GFBITS; ++bit) nonzero_mask |= eval[bit];
        uint32_t root_mask = ~nonzero_mask;
        int remaining = SYS_N - group * 32;
        if (remaining < 32) {
            uint32_t valid_mask = remaining <= 0 ? 0u : ((1u << remaining) - 1u);
            root_mask &= valid_mask;
        }
        d_err_all[err_offset + group] = root_mask;
    }
}


/*
 * Process the full ciphertext batch in host-sized chunks so the packed CUDA
 * data structures remain bounded and easy to map back to the CPU output.
 */
int decrypt(unsigned char (*ciphertexts)[crypto_kem_CIPHERTEXTBYTES]) {
    const int total        = KATNUM;
    const int batchSize    = cm_errorstream_effective_batch_size(BATCH_SIZE);
    const int tpb          = 128;                 // threads/block (multiple of 32)
    const int warps_per_bl = tpb / 32;
    const cm_errorstream_writer_t writer_mode = get_errorstream_writer_mode();
    const cm_errorstream_formatter_t formatter_mode = get_errorstream_formatter_mode();
    const cm_chien_impl_mode_t chien_impl_mode = get_chien_impl_mode();
    const int validate_fast_writer = should_validate_fast_errorstream();
    const int split_errorstream_chunks = should_split_errorstream_chunks();
    const int validate_bitslice32 = validate_fast_writer && chien_impl_mode == CM_CHIEN_IMPL_BITSLICE32;
    const int wordPerBatch = (SYS_N + 31) / 32;

    unsigned char *d_ct;
    gf           *d_syn, *d_loc_soa;
    uint32_t     *d_err, *d_err_validate;
    uint32_t     *h_err;
    uint32_t     *h_err_validate;
    gf           *h_loc;
    timing_totals_t totals = {};
    struct timespec wall_start;
    struct timespec wall_end;
    struct timespec stage_start;
    struct timespec stage_end;
    struct timespec alloc_start;
    struct timespec alloc_end;
    int status = 0;

    totals.setup_init_ms = (float)g_setup_init_ms;
    totals.formatter_mode = formatter_mode;
    if (formatter_mode == CM_ERRORSTREAM_FORMATTER_FASTLUT_V2) {
        ensure_decimal_token_lut_ready();
    }
    clock_gettime(CLOCK_MONOTONIC, &alloc_start);
    cudaMalloc(&d_ct,       batchSize * crypto_kem_CIPHERTEXTBYTES);
    cudaMalloc(&d_syn,      batchSize * 2 * SYS_T * sizeof(gf));
    cudaMalloc(&d_loc_soa, (SYS_T + 1) * batchSize * sizeof(gf));
    cudaMalloc(&d_err,      batchSize * wordPerBatch * sizeof(uint32_t));
    d_err_validate = NULL;
    h_err_validate = NULL;
    if (validate_bitslice32) cudaMalloc(&d_err_validate, batchSize * wordPerBatch * sizeof(uint32_t));
    cudaMallocHost(&h_err,  batchSize * wordPerBatch * sizeof(uint32_t));
    if (validate_bitslice32) cudaMallocHost(&h_err_validate,  batchSize * wordPerBatch * sizeof(uint32_t));
    cudaMallocHost(&h_loc, (SYS_T + 1) * batchSize * sizeof(gf));
    clock_gettime(CLOCK_MONOTONIC, &alloc_end);
    totals.alloc_setup_ms = (float)elapsed_wall_ms(&alloc_start, &alloc_end);

    int batchCount = (total + batchSize - 1) / batchSize;
    wall_start = g_total_wall_start;

    for (int b = 0; b < batchCount; ++b) {
        int offset      = b * batchSize;
        int actualBatch = (offset + batchSize > total) ? (total - offset) : batchSize;
        float h2d_ms = 0.0f;
        float synd_ms = 0.0f;
        float bm_ms = 0.0f;
        float chien_ms = 0.0f;
        float d2h_ms = 0.0f;
        float host_scan_ms = 0.0f;
        float host_format_ms = 0.0f;
        float host_file_write_ms = 0.0f;
        float host_output_ms = 0.0f;

        clock_gettime(CLOCK_MONOTONIC, &stage_start);
        cudaMemcpy(d_ct, &ciphertexts[offset],
                   actualBatch * crypto_kem_CIPHERTEXTBYTES,
                   cudaMemcpyHostToDevice);
        clock_gettime(CLOCK_MONOTONIC, &stage_end);
        h2d_ms = (float)elapsed_wall_ms(&stage_start, &stage_end);
        cudaMemset(d_err, 0, actualBatch * wordPerBatch * sizeof(uint32_t));


        clock_gettime(CLOCK_MONOTONIC, &stage_start);
        {
            dim3 gridSyn(actualBatch,1,1);
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
        berlekampMasseyKernel<<< dim3(1, actualBatch), 96 >>>(d_syn, d_loc_soa);
        cudaDeviceSynchronize();
        clock_gettime(CLOCK_MONOTONIC, &stage_end);
        bm_ms = (float)elapsed_wall_ms(&stage_start, &stage_end);

        // 3) Warp Chien
        int blocks = (actualBatch + warps_per_bl - 1) / warps_per_bl;
        dim3 grid(blocks, 1, 1);
        dim3 block(tpb,   1, 1);
        size_t shmem = warps_per_bl * (SYS_T + 1) * sizeof(gf);

        clock_gettime(CLOCK_MONOTONIC, &stage_start);
        if (chien_impl_mode == CM_CHIEN_IMPL_BITSLICE32) {
            warp_chien_search_kernel_bitslice32<<<grid, block, shmem>>>(d_loc_soa, d_err, actualBatch);
        } else {
            warp_chien_search_kernel<<<grid, block, shmem>>>(d_loc_soa, d_err, actualBatch);
        }
        cudaDeviceSynchronize();
        clock_gettime(CLOCK_MONOTONIC, &stage_end);
        chien_ms = (float)elapsed_wall_ms(&stage_start, &stage_end);

        if (validate_bitslice32) {
            cudaMemset(d_err_validate, 0, actualBatch * wordPerBatch * sizeof(uint32_t));
            warp_chien_search_kernel<<<grid, block, shmem>>>(d_loc_soa, d_err_validate, actualBatch);
            cudaDeviceSynchronize();
            cudaMemcpy(h_err_validate, d_err_validate,
                       actualBatch * wordPerBatch * sizeof(uint32_t),
                       cudaMemcpyDeviceToHost);
        }

        clock_gettime(CLOCK_MONOTONIC, &stage_start);
        cudaMemcpy(h_err, d_err,
                   actualBatch * wordPerBatch * sizeof(uint32_t),
                   cudaMemcpyDeviceToHost);
        cudaDeviceSynchronize();
        clock_gettime(CLOCK_MONOTONIC, &stage_end);
        d2h_ms = (float)elapsed_wall_ms(&stage_start, &stage_end);

        if (validate_bitslice32) {
            if (validate_bitslice32_against_baseline(h_err_validate, h_err, actualBatch, wordPerBatch, formatter_mode) != 0) {
                status = 1;
                break;
            }
        }

        totals.h2d_ms += h2d_ms;
        totals.synd_ms += synd_ms;
        totals.bm_ms += bm_ms;
        totals.chien_ms += chien_ms;
        totals.d2h_ms += d2h_ms;

#if WRITE_ERRORSTREAM
        {
            FILE *f = NULL;
            long file_offset_before = -1;
            struct timespec host_output_start, host_output_end;
            struct timespec host_scan_start, host_scan_end;
            struct timespec host_format_start, host_format_end;
            struct timespec host_write_start, host_write_end;
            unsigned long long batch_output_bytes = 0;
            unsigned long long batch_output_items = 0;
            std::string fast_buffer;

            clock_gettime(CLOCK_MONOTONIC, &host_output_start);
            char output_path[MAX_RUNTIME_PATH];
            if (split_errorstream_chunks) {
                if (snprintf(output_path, sizeof(output_path), "../../results/output/errorstream0_348864_chunk%03d.bin", b) >= (int)sizeof(output_path)) {
                    fprintf(stderr, "split errorstream output path is too long for chunk %d\n", b);
                    status = 1;
                    break;
                }
            } else {
                if (snprintf(output_path, sizeof(output_path), "../../results/output/errorstream0_348864.bin") >= (int)sizeof(output_path)) {
                    fprintf(stderr, "errorstream output path is too long\n");
                    status = 1;
                    break;
                }
            }
            f = fopen(output_path, split_errorstream_chunks ? "wb" : "ab");
            if (f == NULL) {
                perror(output_path);
                status = 1;
                break;
            }
            file_offset_before = ftell(f);

            if (writer_mode == CM_ERRORSTREAM_WRITER_OLD) {
                clock_gettime(CLOCK_MONOTONIC, &host_format_start);
                if (write_errorstream_old_file(f, h_err, actualBatch, wordPerBatch, &batch_output_items) != 0) {
                    fclose(f);
                    status = 1;
                    break;
                }
                clock_gettime(CLOCK_MONOTONIC, &host_format_end);
                host_format_ms = (float)elapsed_wall_ms(&host_format_start, &host_format_end);
            } else {
                size_t reserve_bytes = 0;
                clock_gettime(CLOCK_MONOTONIC, &host_scan_start);
                if (formatter_mode == CM_ERRORSTREAM_FORMATTER_FASTLUT_V2) {
                    reserve_bytes = (size_t)actualBatch * 512u;
                } else {
                    reserve_bytes = (size_t)actualBatch * 64u;
                    for (int ct_idx = 0; ct_idx < actualBatch; ++ct_idx) {
                        const uint32_t *words = h_err + ct_idx * wordPerBatch;
                        for (int w = 0; w < wordPerBatch; ++w) {
                            reserve_bytes += (size_t)__builtin_popcount(words[w]) * 6u;
                        }
                        reserve_bytes += 1u;
                    }
                }
                clock_gettime(CLOCK_MONOTONIC, &host_scan_end);
                host_scan_ms = (float)elapsed_wall_ms(&host_scan_start, &host_scan_end);
                fast_buffer.reserve(reserve_bytes);
                clock_gettime(CLOCK_MONOTONIC, &host_format_start);
                if ((formatter_mode == CM_ERRORSTREAM_FORMATTER_FASTLUT_V2
                        ? append_errorstream_fastlut_v2(&fast_buffer, h_err, actualBatch, wordPerBatch, &batch_output_items)
                        : append_errorstream_fast(&fast_buffer, h_err, actualBatch, wordPerBatch, &batch_output_items)) != 0) {
                    fclose(f);
                    status = 1;
                    break;
                }
                if (validate_fast_writer) {
                    unsigned long long reference_items = 0;
                    std::string reference_buffer;
                    reference_buffer.reserve(fast_buffer.size());
                    if (append_errorstream_reference_memory(&reference_buffer, h_err, actualBatch, wordPerBatch, &reference_items) != 0) {
                        fclose(f);
                        status = 1;
                        break;
                    }
                    if (reference_items != batch_output_items || reference_buffer != fast_buffer) {
                        size_t mismatch_offset = 0;
                        size_t limit = reference_buffer.size() < fast_buffer.size() ? reference_buffer.size() : fast_buffer.size();
                        while (mismatch_offset < limit && reference_buffer[mismatch_offset] == fast_buffer[mismatch_offset]) {
                            ++mismatch_offset;
                        }
                        fprintf(stderr, "CM_VALIDATE_FAST_ERRORSTREAM=1 failed: ref_bytes=%zu fast_bytes=%zu ref_items=%llu fast_items=%llu first_mismatch_offset=%zu\n",
                                reference_buffer.size(), fast_buffer.size(), reference_items, batch_output_items, mismatch_offset);
                        fclose(f);
                        status = 1;
                        break;
                    }
                    fprintf(stderr, "CM_VALIDATE_FAST_ERRORSTREAM=1 passed: bytes=%zu items=%llu\n", fast_buffer.size(), batch_output_items);
                }
                clock_gettime(CLOCK_MONOTONIC, &host_format_end);
                host_format_ms = (float)elapsed_wall_ms(&host_format_start, &host_format_end);
                clock_gettime(CLOCK_MONOTONIC, &host_write_start);
                if (!fast_buffer.empty() && fwrite(fast_buffer.data(), 1, fast_buffer.size(), f) != fast_buffer.size()) {
                    perror("failed to write GPU optimised errorstream output");
                    fclose(f);
                    status = 1;
                    break;
                }
                clock_gettime(CLOCK_MONOTONIC, &host_write_end);
                host_file_write_ms = (float)elapsed_wall_ms(&host_write_start, &host_write_end);
                batch_output_bytes = (unsigned long long)fast_buffer.size();
            }
            if (writer_mode == CM_ERRORSTREAM_WRITER_OLD) {
                long file_pos = ftell(f);
                if (file_pos >= 0 && file_offset_before >= 0) {
                    batch_output_bytes = (unsigned long long)(file_pos - file_offset_before);
                }
            }
            if (fclose(f) != 0) {
                perror("failed to close GPU optimised errorstream output");
                status = 1;
                break;
            }
            clock_gettime(CLOCK_MONOTONIC, &host_output_end);
            host_output_ms = (float)elapsed_wall_ms(&host_output_start, &host_output_end);
            totals.host_scan_ms += host_scan_ms;
            totals.host_format_ms += host_format_ms;
            totals.host_file_write_ms += host_file_write_ms;
            totals.output_bytes += batch_output_bytes;
            totals.output_items += batch_output_items;
        }
#endif
        totals.host_output_ms += host_output_ms;

    }

    cudaFree(d_ct);
    cudaFree(d_syn);
    cudaFree(d_loc_soa);
    cudaFree(d_err);
    if (d_err_validate != NULL) cudaFree(d_err_validate);
    cudaFreeHost(h_err);
    if (h_err_validate != NULL) cudaFreeHost(h_err_validate);
    cudaFreeHost(h_loc);
    cudaDeviceSynchronize();
    clock_gettime(CLOCK_MONOTONIC, &wall_end);
    status = write_profile_summary(&totals, batchSize, total, elapsed_wall_ms(&wall_start, &wall_end));
    cudaDeviceReset();
    return status;
}








int main(void)
{ 
    struct timespec setup_start;
    struct timespec setup_end;

    clock_gettime(CLOCK_MONOTONIC, &setup_start);
    g_total_wall_start = setup_start;
    initialisation(secretkeys, ciphertexts, sk, L, g);
    compute_inverses();
    InitializeC();
    clock_gettime(CLOCK_MONOTONIC, &setup_end);
    g_setup_init_ms = elapsed_wall_ms(&setup_start, &setup_end);

    if (decrypt(ciphertexts) != 0) {
        cudaDeviceReset();
        return 1;
    }
    cudaDeviceReset();
    return 0;
}
// -----------------------------------------------------------------------------
