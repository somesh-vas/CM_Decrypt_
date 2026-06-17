#define _POSIX_C_SOURCE 200809L

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
#include <condition_variable>
#include <mutex>
#include <sys/types.h>
#include <thread>
#include <time.h>
#include <unistd.h>
#include <vector>

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
    float writer_wait_ms;
    float gpu_wait_for_free_buffer_ms;
    float writer_thread_total_ms;
    float profile_write_ms;
    unsigned long long output_bytes;
    unsigned long long output_items;
    int formatter_mode;
    int pipeline_mode;
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
    CM_HOST_OUTPUT_PIPELINE_SERIAL = 0,
    CM_HOST_OUTPUT_PIPELINE_OVERLAP_WRITER = 1,
} cm_host_output_pipeline_t;

typedef enum {
    CM_CHIEN_IMPL_BASELINE = 0,
    CM_CHIEN_IMPL_BITSLICE32 = 1,
} cm_chien_impl_mode_t;

typedef enum {
    CM_BITS32_MUL_IMPL_BASELINE = 0,
    CM_BITS32_MUL_IMPL_KARATSUBA13 = 1,
    CM_BITS32_MUL_IMPL_MULMAT_GROUP = 2,
} cm_bits32_mul_impl_mode_t;

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

static int build_errorstream_output_path(char *buffer, size_t size, int split_chunks, int chunk_id)
{
    char suffix[128];

    if (split_chunks) {
        if (snprintf(suffix, sizeof(suffix), "results/output/errorstream0_8192128_chunk%03d.bin", chunk_id) >= (int)sizeof(suffix)) {
            fprintf(stderr, "split errorstream suffix is too long for chunk %d\n", chunk_id);
            return 1;
        }
    } else {
        if (snprintf(suffix, sizeof(suffix), "results/output/errorstream0_8192128.bin") >= (int)sizeof(suffix)) {
            fprintf(stderr, "errorstream suffix is too long\n");
            return 1;
        }
    }

    return build_project_relative_path(buffer, size, suffix);
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
            "results/profile/Profile_GPU_optimised_8192128.txt") != 0) {
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
            "writer wait           : %.3f ms\n"
            "gpu wait free buffer  : %.3f ms\n"
            "writer thread total   : %.3f ms\n"
            "formatter mode        : %s\n"
            "pipeline mode         : %s\n"
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
            totals->writer_wait_ms,
            totals->gpu_wait_for_free_buffer_ms,
            totals->writer_thread_total_ms,
            totals->formatter_mode == CM_ERRORSTREAM_FORMATTER_FASTLUT_V2 ? "fastlut_v2" : "baseline",
            totals->pipeline_mode == CM_HOST_OUTPUT_PIPELINE_OVERLAP_WRITER ? "overlap_writer" : "serial",
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

static cm_host_output_pipeline_t get_host_output_pipeline_mode(void)
{
    const char *mode = getenv("CM_HOST_OUTPUT_PIPELINE");

    if (mode == NULL || mode[0] == '\0' || strcmp(mode, "overlap_writer") == 0) {
        return CM_HOST_OUTPUT_PIPELINE_OVERLAP_WRITER;
    }
    if (strcmp(mode, "serial") == 0) {
        return CM_HOST_OUTPUT_PIPELINE_SERIAL;
    }

    fprintf(stderr, "unknown CM_HOST_OUTPUT_PIPELINE=%s\n", mode);
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

static cm_bits32_mul_impl_mode_t get_bits32_mul_impl_mode(void)
{
    const char *mode = getenv("CM_BITS32_MUL_IMPL");

    if (mode == NULL || mode[0] == '\0' || strcmp(mode, "mulmat_group") == 0) {
        return CM_BITS32_MUL_IMPL_MULMAT_GROUP;
    }
    if (strcmp(mode, "baseline") == 0) {
        return CM_BITS32_MUL_IMPL_BASELINE;
    }
    if (strcmp(mode, "karatsuba13") == 0) {
        return CM_BITS32_MUL_IMPL_KARATSUBA13;
    }

    fprintf(stderr, "unknown CM_BITS32_MUL_IMPL=%s\n", mode);
    exit(1);
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

typedef struct {
    float host_scan_ms;
    float host_format_ms;
    float host_file_write_ms;
    float host_output_ms;
    unsigned long long output_bytes;
    unsigned long long output_items;
} host_output_result_t;

static int format_errorstream_buffer(
    std::string *fast_buffer,
    const uint32_t *h_err,
    int actual_batch,
    int word_per_batch,
    cm_errorstream_formatter_t formatter_mode,
    int validate_reference,
    host_output_result_t *result)
{
    size_t reserve_bytes = 0;
    struct timespec host_scan_start;
    struct timespec host_scan_end;
    struct timespec host_format_start;
    struct timespec host_format_end;
    unsigned long long batch_output_items = 0;

    result->host_scan_ms = 0.0f;
    result->host_format_ms = 0.0f;
    result->output_bytes = 0;
    result->output_items = 0;
    fast_buffer->clear();

    clock_gettime(CLOCK_MONOTONIC, &host_scan_start);
    if (formatter_mode == CM_ERRORSTREAM_FORMATTER_FASTLUT_V2) {
        reserve_bytes = (size_t)actual_batch * 512u;
    } else {
        reserve_bytes = (size_t)actual_batch * 64u;
        for (int ct_idx = 0; ct_idx < actual_batch; ++ct_idx) {
            const uint32_t *words = h_err + ct_idx * word_per_batch;
            for (int w = 0; w < word_per_batch; ++w) {
                reserve_bytes += (size_t)__builtin_popcount(words[w]) * 6u;
            }
            reserve_bytes += 1u;
        }
    }
    clock_gettime(CLOCK_MONOTONIC, &host_scan_end);
    result->host_scan_ms = (float)elapsed_wall_ms(&host_scan_start, &host_scan_end);

    fast_buffer->reserve(reserve_bytes);
    clock_gettime(CLOCK_MONOTONIC, &host_format_start);
    if ((formatter_mode == CM_ERRORSTREAM_FORMATTER_FASTLUT_V2
             ? append_errorstream_fastlut_v2(
                   fast_buffer,
                   h_err,
                   actual_batch,
                   word_per_batch,
                   &batch_output_items)
             : append_errorstream_fast(
                   fast_buffer,
                   h_err,
                   actual_batch,
                   word_per_batch,
                   &batch_output_items)) != 0) {
        return 1;
    }

    if (validate_reference) {
        unsigned long long reference_items = 0;
        std::string reference_buffer;
        reference_buffer.reserve(fast_buffer->size());
        if (append_errorstream_reference_memory(
                &reference_buffer,
                h_err,
                actual_batch,
                word_per_batch,
                &reference_items) != 0) {
            return 1;
        }

        if (reference_items != batch_output_items || reference_buffer != *fast_buffer) {
            size_t mismatch_offset = 0;
            size_t limit = reference_buffer.size() < fast_buffer->size()
                               ? reference_buffer.size()
                               : fast_buffer->size();
            while (mismatch_offset < limit &&
                   reference_buffer[mismatch_offset] == (*fast_buffer)[mismatch_offset]) {
                ++mismatch_offset;
            }
            fprintf(stderr,
                    "CM_VALIDATE_FAST_ERRORSTREAM=1 failed: ref_bytes=%zu fast_bytes=%zu ref_items=%llu fast_items=%llu first_mismatch_offset=%zu\n",
                    reference_buffer.size(),
                    fast_buffer->size(),
                    reference_items,
                    batch_output_items,
                    mismatch_offset);
            return 1;
        }

        fprintf(stderr,
                "CM_VALIDATE_FAST_ERRORSTREAM=1 passed: bytes=%zu items=%llu\n",
                fast_buffer->size(),
                batch_output_items);
    }
    clock_gettime(CLOCK_MONOTONIC, &host_format_end);
    result->host_format_ms = (float)elapsed_wall_ms(&host_format_start, &host_format_end);
    result->output_bytes = (unsigned long long)fast_buffer->size();
    result->output_items = batch_output_items;
    return 0;
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
                ct_idx,
                word_idx,
                baseline_h_err[mismatch_word],
                bitslice_h_err[mismatch_word]);
        return 1;
    }

    {
        host_output_result_t baseline_result = {};
        host_output_result_t bitslice_result = {};
        std::string baseline_buffer;
        std::string bitslice_buffer;

        if (format_errorstream_buffer(
                &baseline_buffer,
                baseline_h_err,
                actual_batch,
                word_per_batch,
                formatter_mode,
                0,
                &baseline_result) != 0) {
            return 1;
        }
        if (format_errorstream_buffer(
                &bitslice_buffer,
                bitslice_h_err,
                actual_batch,
                word_per_batch,
                formatter_mode,
                0,
                &bitslice_result) != 0) {
            return 1;
        }

        if (baseline_result.output_items != bitslice_result.output_items ||
            baseline_buffer != bitslice_buffer) {
            size_t mismatch_offset = 0;
            size_t limit = baseline_buffer.size() < bitslice_buffer.size()
                               ? baseline_buffer.size()
                               : bitslice_buffer.size();
            while (mismatch_offset < limit &&
                   baseline_buffer[mismatch_offset] == bitslice_buffer[mismatch_offset]) {
                ++mismatch_offset;
            }
            fprintf(stderr,
                    "CM_VALIDATE_FAST_ERRORSTREAM=1 bitslice32 byte compare failed: baseline_bytes=%zu bitslice_bytes=%zu baseline_items=%llu bitslice_items=%llu first_mismatch_offset=%zu\n",
                    baseline_buffer.size(),
                    bitslice_buffer.size(),
                    baseline_result.output_items,
                    bitslice_result.output_items,
                    mismatch_offset);
            return 1;
        }

        fprintf(stderr,
                "CM_VALIDATE_FAST_ERRORSTREAM=1 bitslice32 byte compare passed: bytes=%zu items=%llu\n",
                bitslice_buffer.size(),
                bitslice_result.output_items);
    }

    return 0;
}

static int write_errorstream_fast_buffer(
    const char *errorstream_path,
    const std::string &fast_buffer,
    host_output_result_t *result)
{
    FILE *f = NULL;
    struct timespec host_write_start;
    struct timespec host_write_end;

    result->host_file_write_ms = 0.0f;

    f = fopen(errorstream_path, strstr(errorstream_path, "_chunk") != NULL ? "wb" : "ab");
    if (f == NULL) {
        perror("failed to open GPU optimised errorstream output");
        return 1;
    }

    clock_gettime(CLOCK_MONOTONIC, &host_write_start);
    if (!fast_buffer.empty() &&
        fwrite(fast_buffer.data(), 1, fast_buffer.size(), f) != fast_buffer.size()) {
        perror("failed to write GPU optimised errorstream output");
        fclose(f);
        return 1;
    }
    clock_gettime(CLOCK_MONOTONIC, &host_write_end);
    result->host_file_write_ms = (float)elapsed_wall_ms(&host_write_start, &host_write_end);

    if (fclose(f) != 0) {
        perror("failed to close GPU optimised errorstream output");
        return 1;
    }
    return 0;
}

static int write_errorstream_chunk_serial(
    const char *errorstream_path,
    const uint32_t *h_err,
    int actual_batch,
    int word_per_batch,
    cm_errorstream_writer_t writer_mode,
    cm_errorstream_formatter_t formatter_mode,
    int validate_fast_writer,
    host_output_result_t *result)
{
    FILE *f = NULL;
    long file_offset_before = -1;
    struct timespec host_output_start;
    struct timespec host_output_end;
    struct timespec host_format_start;
    struct timespec host_format_end;
    std::string fast_buffer;

    memset(result, 0, sizeof(*result));
    clock_gettime(CLOCK_MONOTONIC, &host_output_start);

    f = fopen(errorstream_path, strstr(errorstream_path, "_chunk") != NULL ? "wb" : "ab");
    if (f == NULL) {
        perror("failed to open GPU optimised errorstream output");
        return 1;
    }

    file_offset_before = ftell(f);
    if (writer_mode == CM_ERRORSTREAM_WRITER_OLD) {
        clock_gettime(CLOCK_MONOTONIC, &host_format_start);
        if (write_errorstream_old_file(
                f,
                h_err,
                actual_batch,
                word_per_batch,
                &result->output_items) != 0) {
            fclose(f);
            return 1;
        }
        clock_gettime(CLOCK_MONOTONIC, &host_format_end);
        result->host_format_ms = (float)elapsed_wall_ms(&host_format_start, &host_format_end);
    } else {
        if (format_errorstream_buffer(
                &fast_buffer,
                h_err,
                actual_batch,
                word_per_batch,
                formatter_mode,
                validate_fast_writer,
                result) != 0) {
            fclose(f);
            return 1;
        }

        {
            struct timespec host_write_start;
            struct timespec host_write_end;
            clock_gettime(CLOCK_MONOTONIC, &host_write_start);
            if (!fast_buffer.empty() &&
                fwrite(fast_buffer.data(), 1, fast_buffer.size(), f) != fast_buffer.size()) {
                perror("failed to write GPU optimised errorstream output");
                fclose(f);
                return 1;
            }
            clock_gettime(CLOCK_MONOTONIC, &host_write_end);
            result->host_file_write_ms = (float)elapsed_wall_ms(&host_write_start, &host_write_end);
        }
        result->output_bytes = (unsigned long long)fast_buffer.size();
    }

    if (writer_mode == CM_ERRORSTREAM_WRITER_OLD) {
        long file_pos = ftell(f);
        if (file_pos >= 0 && file_offset_before >= 0) {
            result->output_bytes = (unsigned long long)(file_pos - file_offset_before);
        }
    }

    if (fclose(f) != 0) {
        perror("failed to close GPU optimised errorstream output");
        return 1;
    }

    clock_gettime(CLOCK_MONOTONIC, &host_output_end);
    result->host_output_ms = (float)elapsed_wall_ms(&host_output_start, &host_output_end);
    return 0;
}

typedef struct {
    uint32_t *h_err;
    int actual_batch;
    int chunk_id;
    int ready;
    int in_use;
    host_output_result_t result;
    std::string validation_expected;
    char output_path[MAX_RUNTIME_PATH];
} overlap_writer_slot_t;

typedef struct {
    std::mutex mutex;
    std::condition_variable cv;
    std::vector<overlap_writer_slot_t> slots;
    const char *errorstream_path;
    int split_errorstream_chunks;
    int word_per_batch;
    cm_errorstream_writer_t writer_mode;
    cm_errorstream_formatter_t formatter_mode;
    int validate_fast_writer;
    int stop_requested;
    int failure;
    int pending_chunks;
    int next_chunk_to_write;
    float writer_wait_ms;
    float writer_thread_total_ms;
    timing_totals_t *totals;
} overlap_writer_state_t;

static void overlap_writer_thread_main(overlap_writer_state_t *state)
{
    struct timespec thread_start;
    struct timespec thread_end;

    clock_gettime(CLOCK_MONOTONIC, &thread_start);
    for (;;) {
        int slot_index = -1;
        struct timespec wait_start;
        struct timespec wait_end;

        clock_gettime(CLOCK_MONOTONIC, &wait_start);
        {
            std::unique_lock<std::mutex> lock(state->mutex);
            state->cv.wait(lock, [&]() {
                if (state->failure) {
                    return true;
                }
                for (size_t idx = 0; idx < state->slots.size(); ++idx) {
                    if (state->slots[idx].ready &&
                        state->slots[idx].chunk_id == state->next_chunk_to_write) {
                        slot_index = (int)idx;
                        return true;
                    }
                }
                return state->stop_requested && state->pending_chunks == 0;
            });
        }
        clock_gettime(CLOCK_MONOTONIC, &wait_end);
        state->writer_wait_ms += (float)elapsed_wall_ms(&wait_start, &wait_end);

        if (slot_index < 0) {
            std::unique_lock<std::mutex> lock(state->mutex);
            if (state->failure || (state->stop_requested && state->pending_chunks == 0)) {
                break;
            }
            continue;
        }

        overlap_writer_slot_t *slot = &state->slots[(size_t)slot_index];
        host_output_result_t local_result = {};
        std::string fast_buffer;
        struct timespec host_output_start;
        struct timespec host_output_end;

        clock_gettime(CLOCK_MONOTONIC, &host_output_start);
        if (state->writer_mode == CM_ERRORSTREAM_WRITER_OLD) {
            if (write_errorstream_chunk_serial(
                    state->split_errorstream_chunks ? slot->output_path : state->errorstream_path,
                    slot->h_err,
                    slot->actual_batch,
                    state->word_per_batch,
                    state->writer_mode,
                    state->formatter_mode,
                    0,
                    &local_result) != 0) {
                std::unique_lock<std::mutex> lock(state->mutex);
                state->failure = 1;
                slot->ready = 0;
                slot->in_use = 0;
                --state->pending_chunks;
                state->cv.notify_all();
                break;
            }
        } else {
            if (format_errorstream_buffer(
                    &fast_buffer,
                    slot->h_err,
                    slot->actual_batch,
                    state->word_per_batch,
                    state->formatter_mode,
                    0,
                    &local_result) != 0) {
                std::unique_lock<std::mutex> lock(state->mutex);
                state->failure = 1;
                slot->ready = 0;
                slot->in_use = 0;
                --state->pending_chunks;
                state->cv.notify_all();
                break;
            }

            if (state->validate_fast_writer && fast_buffer != slot->validation_expected) {
                size_t mismatch_offset = 0;
                size_t limit = fast_buffer.size() < slot->validation_expected.size()
                                   ? fast_buffer.size()
                                   : slot->validation_expected.size();
                while (mismatch_offset < limit &&
                       fast_buffer[mismatch_offset] == slot->validation_expected[mismatch_offset]) {
                    ++mismatch_offset;
                }
                fprintf(stderr,
                        "CM_VALIDATE_FAST_ERRORSTREAM=1 overlap serial compare failed: chunk=%d serial_bytes=%zu overlap_bytes=%zu first_mismatch_offset=%zu\n",
                        slot->chunk_id,
                        slot->validation_expected.size(),
                        fast_buffer.size(),
                        mismatch_offset);
                std::unique_lock<std::mutex> lock(state->mutex);
                state->failure = 1;
                slot->ready = 0;
                slot->in_use = 0;
                --state->pending_chunks;
                state->cv.notify_all();
                break;
            }

            if (state->validate_fast_writer) {
                fprintf(stderr,
                        "CM_VALIDATE_FAST_ERRORSTREAM=1 overlap serial compare passed: chunk=%d bytes=%zu\n",
                        slot->chunk_id,
                        fast_buffer.size());
            }

            if (write_errorstream_fast_buffer(state->split_errorstream_chunks ? slot->output_path : state->errorstream_path, fast_buffer, &local_result) != 0) {
                std::unique_lock<std::mutex> lock(state->mutex);
                state->failure = 1;
                slot->ready = 0;
                slot->in_use = 0;
                --state->pending_chunks;
                state->cv.notify_all();
                break;
            }
        }
        clock_gettime(CLOCK_MONOTONIC, &host_output_end);
        local_result.host_output_ms = (float)elapsed_wall_ms(&host_output_start, &host_output_end);

        {
            std::unique_lock<std::mutex> lock(state->mutex);
            slot->result = local_result;
            state->totals->host_scan_ms += local_result.host_scan_ms;
            state->totals->host_format_ms += local_result.host_format_ms;
            state->totals->host_file_write_ms += local_result.host_file_write_ms;
            state->totals->host_output_ms += local_result.host_output_ms;
            state->totals->output_bytes += local_result.output_bytes;
            state->totals->output_items += local_result.output_items;
            slot->validation_expected.clear();
            slot->ready = 0;
            slot->in_use = 0;
            --state->pending_chunks;
            ++state->next_chunk_to_write;
            state->cv.notify_all();
        }
    }

    clock_gettime(CLOCK_MONOTONIC, &thread_end);
    state->writer_thread_total_ms = (float)elapsed_wall_ms(&thread_start, &thread_end);
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
    __shared__ uint32_t c_words[(sb + 31) / 32];
    __shared__ gf s_out[2 * SYS_T];   // 2·t accumulators

    const int tid    = threadIdx.x;
    const int ct     = blockIdx.x;               // one block per CT
    const int c_word_count = (sb + 31) / 32;

    // 1) load packed ciphertext words into shared memory.
    for (int word = tid; word < c_word_count; word += blockDim.x) {
        uint32_t packed = 0;
        const int byte_base = word << 2;

        #pragma unroll
        for (int k = 0; k < 4; ++k) {
            const int byte_idx = byte_base + k;
            if (byte_idx < SYND_BYTES) {
                packed |= ((uint32_t)d_ciphertexts[ct * SYND_BYTES + byte_idx]) << (8 * k);
            }
        }

        const int remaining_bits = sb - (word << 5);
        if (remaining_bits > 0 && remaining_bits < 32) {
            packed &= ((1u << remaining_bits) - 1u);
        }

        c_words[word] = packed;
    }
    __syncthreads();

    // 2) dot‑product with inverse table
    if (tid < 2 * SYS_T) {
        const int stride = 2 * SYS_T;
        const gf *col = d_inverse_elements + tid;

        gf acc = 0;
        #pragma unroll 8
        for (int bit = 0; bit < sb; ++bit) {
            const uint32_t packed = c_words[bit >> 5];
            const gf cbit = (gf)((packed >> (bit & 31)) & 1u);
            gf mask = -(gf)cbit;   // 0 or 0xFFFF
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

__device__ __forceinline__ uint32_t bitslice_coeff_mask(gf value, int bit)
{
    return ((value >> bit) & 1) ? 0xFFFFFFFFu : 0u;
}

template <int N>
__device__ __forceinline__ void bitslice_mul_poly(
    uint32_t out[2 * N - 1],
    const uint32_t left[N],
    const uint32_t right[N])
{
    #pragma unroll
    for (int i = 0; i < 2 * N - 1; ++i) {
        out[i] = 0u;
    }

    #pragma unroll
    for (int i = 0; i < N; ++i) {
        #pragma unroll
        for (int j = 0; j < N; ++j) {
            out[i + j] ^= left[i] & right[j];
        }
    }
}

__device__ __forceinline__ void bitslice_reduce_poly13(
    uint32_t out[GFBITS],
    uint32_t poly[2 * GFBITS - 1])
{
    #pragma unroll
    for (int deg = 2 * GFBITS - 2; deg >= GFBITS; --deg) {
        uint32_t fold = poly[deg];
        poly[deg - 9] ^= fold;
        poly[deg - 10] ^= fold;
        poly[deg - 12] ^= fold;
        poly[deg - 13] ^= fold;
    }

    #pragma unroll
    for (int i = 0; i < GFBITS; ++i) {
        out[i] = poly[i];
    }
}

__device__ __forceinline__ void bitslice_mul_masks(
    uint32_t out[GFBITS],
    const uint32_t left[GFBITS],
    const uint32_t right[GFBITS])
{
    uint32_t poly[2 * GFBITS - 1];

    bitslice_mul_poly<GFBITS>(poly, left, right);
    bitslice_reduce_poly13(out, poly);
}

__device__ __forceinline__ void bitslice_mul_masks_karatsuba13(
    uint32_t out[GFBITS],
    const uint32_t left[GFBITS],
    const uint32_t right[GFBITS])
{
    uint32_t z0[13];
    uint32_t z1[13];
    uint32_t z2[11];
    uint32_t mix_left[7];
    uint32_t mix_right[7];
    uint32_t poly[2 * GFBITS - 1];

    bitslice_mul_poly<7>(z0, left, right);
    bitslice_mul_poly<6>(z2, left + 7, right + 7);

    #pragma unroll
    for (int i = 0; i < 6; ++i) {
        mix_left[i] = left[i] ^ left[i + 7];
        mix_right[i] = right[i] ^ right[i + 7];
    }
    mix_left[6] = left[6];
    mix_right[6] = right[6];
    bitslice_mul_poly<7>(z1, mix_left, mix_right);

    #pragma unroll
    for (int i = 0; i < 2 * GFBITS - 1; ++i) {
        poly[i] = 0u;
    }

    #pragma unroll
    for (int i = 0; i < 13; ++i) {
        poly[i] ^= z0[i];
        poly[i + 7] ^= z1[i];
        poly[i + 7] ^= z0[i];
    }

    #pragma unroll
    for (int i = 0; i < 11; ++i) {
        poly[i + 7] ^= z2[i];
        poly[i + 14] ^= z2[i];
    }

    bitslice_reduce_poly13(out, poly);
}

template <cm_bits32_mul_impl_mode_t MUL_IMPL>
__device__ __forceinline__ void bitslice_horner_eval_group(
    uint32_t out[GFBITS],
    const gf *s_sigma,
    int group,
    const uint32_t *support_mul_table)
{
    uint32_t x_bits[GFBITS];
    uint32_t eval[GFBITS];
    uint32_t prod[GFBITS];
    (void)support_mul_table;

    #pragma unroll
    for (int bit = 0; bit < GFBITS; ++bit) {
        x_bits[bit] = d_support_bits[group][bit];
        eval[bit] = bitslice_coeff_mask(s_sigma[0], bit);
    }

    #pragma unroll 1
    for (int coeff_idx = 1; coeff_idx <= SYS_T; ++coeff_idx) {
        if (MUL_IMPL == CM_BITS32_MUL_IMPL_KARATSUBA13) {
            bitslice_mul_masks_karatsuba13(prod, eval, x_bits);
        } else {
            bitslice_mul_masks(prod, eval, x_bits);
        }
        #pragma unroll
        for (int bit = 0; bit < GFBITS; ++bit) {
            eval[bit] = prod[bit] ^ bitslice_coeff_mask(s_sigma[coeff_idx], bit);
        }
    }

    #pragma unroll
    for (int bit = 0; bit < GFBITS; ++bit) {
        out[bit] = eval[bit];
    }
}

template <>
__device__ __forceinline__ void bitslice_horner_eval_group<CM_BITS32_MUL_IMPL_MULMAT_GROUP>(
    uint32_t out[GFBITS],
    const gf *s_sigma,
    int group,
    const uint32_t *support_mul_table)
{
    const uint32_t *group_table = support_mul_table + group * GFBITS * GFBITS;
    uint32_t eval[GFBITS];
    uint32_t next[GFBITS];

    #pragma unroll
    for (int bit = 0; bit < GFBITS; ++bit) {
        eval[bit] = bitslice_coeff_mask(s_sigma[0], bit);
    }

    #pragma unroll 1
    for (int coeff_idx = 1; coeff_idx <= SYS_T; ++coeff_idx) {
        #pragma unroll
        for (int out_bit = 0; out_bit < GFBITS; ++out_bit) {
            uint32_t acc = bitslice_coeff_mask(s_sigma[coeff_idx], out_bit);
            #pragma unroll
            for (int in_bit = 0; in_bit < GFBITS; ++in_bit) {
                acc ^= eval[in_bit] & group_table[out_bit * GFBITS + in_bit];
            }
            next[out_bit] = acc;
        }

        #pragma unroll
        for (int bit = 0; bit < GFBITS; ++bit) {
            eval[bit] = next[bit];
        }
    }

    #pragma unroll
    for (int bit = 0; bit < GFBITS; ++bit) {
        out[bit] = eval[bit];
    }
}

template <cm_bits32_mul_impl_mode_t MUL_IMPL>
__global__ void warp_chien_search_kernel_bitslice32(
    const gf* __restrict__ d_sigma_soa,
    uint32_t* __restrict__ d_err_all,
    int BATCH,
    const uint32_t* __restrict__ support_mul_table)
{
    const int lane = threadIdx.x & 31;
    const int warp_local = threadIdx.x >> 5;
    const int warps_per_blk = blockDim.x >> 5;
    const int warp_global = blockIdx.x * warps_per_blk + warp_local;

    if (warp_global >= BATCH) return;

    const int err_offset = warp_global * (SYS_N / 32);

    extern __shared__ gf s_flat[];
    gf *s_sigma = s_flat + warp_local * (SYS_T + 1);

    for (int i = lane; i <= SYS_T; i += 32) {
        s_sigma[i] = d_sigma_soa[i * BATCH + warp_global];
    }
    __syncwarp();

    for (int group = lane; group < SYS_N / 32; group += 32) {
        uint32_t eval[GFBITS];
        bitslice_horner_eval_group<MUL_IMPL>(eval, s_sigma, group, support_mul_table);

        {
            uint32_t nonzero_mask = 0u;
            #pragma unroll
            for (int bit = 0; bit < GFBITS; ++bit) {
                nonzero_mask |= eval[bit];
            }
            d_err_all[err_offset + group] = ~nonzero_mask;
        }
    }
}


int decrypt(unsigned char (*ciphertexts)[crypto_kem_CIPHERTEXTBYTES]) {
    const int total        = KATNUM;
    const int batchSize    = cm_errorstream_effective_batch_size(BATCH_SIZE);
    const int tpb          = 128;                 // threads/block (multiple of 32)
    const int warps_per_bl = tpb / 32;
    /* 6960 is not divisible by 32, so the packed error buffer needs the ceiling. */
    const int wordPerBatch = (SYS_N + 31) / 32;
    const cm_errorstream_writer_t writer_mode = get_errorstream_writer_mode();
    const cm_errorstream_formatter_t formatter_mode = get_errorstream_formatter_mode();
    const cm_host_output_pipeline_t pipeline_mode = get_host_output_pipeline_mode();
    const cm_chien_impl_mode_t chien_impl_mode = get_chien_impl_mode();
    const cm_bits32_mul_impl_mode_t bits32_mul_impl_mode = get_bits32_mul_impl_mode();
    const int validate_fast_writer = should_validate_fast_errorstream();
    const int split_errorstream_chunks = should_split_errorstream_chunks();
    const int validate_bitslice32 = validate_fast_writer && chien_impl_mode == CM_CHIEN_IMPL_BITSLICE32;
    const int writer_slot_count = 2;

    unsigned char *d_ct;
    gf           *d_syn, *d_loc_soa;
    uint32_t     *d_err, *d_err_validate;
    uint32_t     *h_err;
    uint32_t     *h_err_validate;
    uint32_t     *h_err_overlap[2] = { NULL, NULL };
    gf           *h_loc;
    timing_totals_t totals = {};
    struct timespec wall_start;
    struct timespec wall_end;
    struct timespec stage_start;
    struct timespec stage_end;
    struct timespec alloc_start;
    struct timespec alloc_end;
    int status = 0;
    overlap_writer_state_t overlap_writer = {};
    std::thread writer_thread;
    char errorstream_path[MAX_RUNTIME_PATH];
    int errorstream_path_ready = 0;

    totals.setup_init_ms = (float)g_setup_init_ms;
    totals.formatter_mode = formatter_mode;
    totals.pipeline_mode = pipeline_mode;
    if (formatter_mode == CM_ERRORSTREAM_FORMATTER_FASTLUT_V2) {
        ensure_decimal_token_lut_ready();
    }
    if (build_errorstream_output_path(errorstream_path, sizeof(errorstream_path), 0, 0) != 0) {
        return 1;
    }
    errorstream_path_ready = 1;
    clock_gettime(CLOCK_MONOTONIC, &alloc_start);
    cudaMalloc(&d_ct,       batchSize * crypto_kem_CIPHERTEXTBYTES);
    cudaMalloc(&d_syn,      batchSize * 2 * SYS_T * sizeof(gf));
    cudaMalloc(&d_loc_soa, (SYS_T + 1) * batchSize * sizeof(gf));
    cudaMalloc(&d_err,      batchSize * wordPerBatch * sizeof(uint32_t));
    d_err_validate = NULL;
    h_err_validate = NULL;
    if (validate_bitslice32) {
        cudaMalloc(&d_err_validate, batchSize * wordPerBatch * sizeof(uint32_t));
    }
    if (pipeline_mode == CM_HOST_OUTPUT_PIPELINE_OVERLAP_WRITER) {
        for (int slot = 0; slot < writer_slot_count; ++slot) {
            cudaMallocHost(&h_err_overlap[slot], batchSize * wordPerBatch * sizeof(uint32_t));
        }
        h_err = h_err_overlap[0];
    } else {
        cudaMallocHost(&h_err,  batchSize * wordPerBatch * sizeof(uint32_t));
    }
    if (validate_bitslice32) {
        cudaMallocHost(&h_err_validate, batchSize * wordPerBatch * sizeof(uint32_t));
    }
    cudaMallocHost(&h_loc, (SYS_T + 1) * batchSize * sizeof(gf));
    clock_gettime(CLOCK_MONOTONIC, &alloc_end);
    totals.alloc_setup_ms = (float)elapsed_wall_ms(&alloc_start, &alloc_end);

    if (pipeline_mode == CM_HOST_OUTPUT_PIPELINE_OVERLAP_WRITER) {
        overlap_writer.errorstream_path = errorstream_path;
        overlap_writer.split_errorstream_chunks = split_errorstream_chunks;
        overlap_writer.word_per_batch = wordPerBatch;
        overlap_writer.writer_mode = writer_mode;
        overlap_writer.formatter_mode = formatter_mode;
        overlap_writer.validate_fast_writer = validate_fast_writer;
        overlap_writer.stop_requested = 0;
        overlap_writer.failure = 0;
        overlap_writer.pending_chunks = 0;
        overlap_writer.next_chunk_to_write = 0;
        overlap_writer.writer_wait_ms = 0.0f;
        overlap_writer.writer_thread_total_ms = 0.0f;
        overlap_writer.totals = &totals;
        overlap_writer.slots.resize((size_t)writer_slot_count);
        for (int slot = 0; slot < writer_slot_count; ++slot) {
            overlap_writer.slots[(size_t)slot].h_err = h_err_overlap[slot];
            overlap_writer.slots[(size_t)slot].actual_batch = 0;
            overlap_writer.slots[(size_t)slot].chunk_id = -1;
            overlap_writer.slots[(size_t)slot].ready = 0;
            overlap_writer.slots[(size_t)slot].in_use = 0;
        }
        writer_thread = std::thread(overlap_writer_thread_main, &overlap_writer);
    }

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
        berlekampMasseyKernel<<< dim3(1, actualBatch), 160 >>>(d_syn, d_loc_soa);
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
            switch (bits32_mul_impl_mode) {
                case CM_BITS32_MUL_IMPL_BASELINE:
                    warp_chien_search_kernel_bitslice32<CM_BITS32_MUL_IMPL_BASELINE><<<grid, block, shmem>>>(
                        d_loc_soa, d_err, actualBatch, d_support_mul_table);
                    break;
                case CM_BITS32_MUL_IMPL_KARATSUBA13:
                    warp_chien_search_kernel_bitslice32<CM_BITS32_MUL_IMPL_KARATSUBA13><<<grid, block, shmem>>>(
                        d_loc_soa, d_err, actualBatch, d_support_mul_table);
                    break;
                case CM_BITS32_MUL_IMPL_MULMAT_GROUP:
                    warp_chien_search_kernel_bitslice32<CM_BITS32_MUL_IMPL_MULMAT_GROUP><<<grid, block, shmem>>>(
                        d_loc_soa, d_err, actualBatch, d_support_mul_table);
                    break;
                default:
                    fprintf(stderr, "unsupported CM_BITS32_MUL_IMPL=%d\n", (int)bits32_mul_impl_mode);
                    exit(1);
            }
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

        if (pipeline_mode == CM_HOST_OUTPUT_PIPELINE_OVERLAP_WRITER) {
            const int slot_index = b % writer_slot_count;
            overlap_writer_slot_t *slot = &overlap_writer.slots[(size_t)slot_index];
            struct timespec gpu_wait_start;
            struct timespec gpu_wait_end;

            clock_gettime(CLOCK_MONOTONIC, &gpu_wait_start);
            {
                std::unique_lock<std::mutex> lock(overlap_writer.mutex);
                overlap_writer.cv.wait(lock, [&]() {
                    return overlap_writer.failure || !slot->in_use;
                });
                if (overlap_writer.failure) {
                    status = 1;
                } else {
                    slot->in_use = 1;
                    h_err = slot->h_err;
                }
            }
            clock_gettime(CLOCK_MONOTONIC, &gpu_wait_end);
            totals.gpu_wait_for_free_buffer_ms += (float)elapsed_wall_ms(&gpu_wait_start, &gpu_wait_end);
            if (status != 0) {
                break;
            }
        }

        clock_gettime(CLOCK_MONOTONIC, &stage_start);
        cudaMemcpy(h_err, d_err,
                   actualBatch * wordPerBatch * sizeof(uint32_t),
                   cudaMemcpyDeviceToHost);
        clock_gettime(CLOCK_MONOTONIC, &stage_end);
        d2h_ms = (float)elapsed_wall_ms(&stage_start, &stage_end);

        if (validate_bitslice32) {
            if (validate_bitslice32_against_baseline(
                    h_err_validate,
                    h_err,
                    actualBatch,
                    wordPerBatch,
                    formatter_mode) != 0) {
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
            char active_errorstream_path[MAX_RUNTIME_PATH];
            const char *chunk_errorstream_path = errorstream_path;

            if (!errorstream_path_ready) {
                status = 1;
                break;
            }
            if (split_errorstream_chunks) {
                if (build_errorstream_output_path(active_errorstream_path, sizeof(active_errorstream_path), 1, b) != 0) {
                    status = 1;
                    break;
                }
                chunk_errorstream_path = active_errorstream_path;
            }

            if (pipeline_mode == CM_HOST_OUTPUT_PIPELINE_OVERLAP_WRITER) {
                const int slot_index = b % writer_slot_count;
                overlap_writer_slot_t *slot = &overlap_writer.slots[(size_t)slot_index];
                if (validate_fast_writer && writer_mode == CM_ERRORSTREAM_WRITER_FAST) {
                    if (format_errorstream_buffer(
                            &slot->validation_expected,
                            h_err,
                            actualBatch,
                            wordPerBatch,
                            formatter_mode,
                            1,
                            &slot->result) != 0) {
                        status = 1;
                        break;
                    }
                } else {
                    slot->validation_expected.clear();
                }

                if (split_errorstream_chunks && build_errorstream_output_path(slot->output_path, sizeof(slot->output_path), 1, b) != 0) {
                    status = 1;
                    break;
                }

                {
                    std::unique_lock<std::mutex> lock(overlap_writer.mutex);
                    slot->actual_batch = actualBatch;
                    slot->chunk_id = b;
                    slot->ready = 1;
                    ++overlap_writer.pending_chunks;
                }
                overlap_writer.cv.notify_all();
            } else {
                host_output_result_t host_result = {};
                if (write_errorstream_chunk_serial(
                        chunk_errorstream_path,
                        h_err,
                        actualBatch,
                        wordPerBatch,
                        writer_mode,
                        formatter_mode,
                        validate_fast_writer,
                        &host_result) != 0) {
                    status = 1;
                    break;
                }
                host_scan_ms = host_result.host_scan_ms;
                host_format_ms = host_result.host_format_ms;
                host_file_write_ms = host_result.host_file_write_ms;
                host_output_ms = host_result.host_output_ms;
                totals.host_scan_ms += host_scan_ms;
                totals.host_format_ms += host_format_ms;
                totals.host_file_write_ms += host_file_write_ms;
                totals.output_bytes += host_result.output_bytes;
                totals.output_items += host_result.output_items;
            }
        }
#endif
        totals.host_output_ms += host_output_ms;
    }

    if (status == 0 && pipeline_mode == CM_HOST_OUTPUT_PIPELINE_OVERLAP_WRITER) {
        std::unique_lock<std::mutex> lock(overlap_writer.mutex);
        overlap_writer.stop_requested = 1;
        overlap_writer.cv.notify_all();
        overlap_writer.cv.wait(lock, [&]() {
            return overlap_writer.failure || overlap_writer.pending_chunks == 0;
        });
        if (overlap_writer.failure) {
            status = 1;
        }
    }

    if (pipeline_mode == CM_HOST_OUTPUT_PIPELINE_OVERLAP_WRITER) {
        {
            std::unique_lock<std::mutex> lock(overlap_writer.mutex);
            overlap_writer.stop_requested = 1;
        }
        overlap_writer.cv.notify_all();
        if (writer_thread.joinable()) {
            writer_thread.join();
        }
        totals.writer_wait_ms = overlap_writer.writer_wait_ms;
        totals.writer_thread_total_ms = overlap_writer.writer_thread_total_ms;
        if (overlap_writer.failure) {
            status = 1;
        }
    }

    if (status == 0) {
        clock_gettime(CLOCK_MONOTONIC, &wall_end);
        status = write_profile_summary(&totals, batchSize, total, elapsed_wall_ms(&wall_start, &wall_end));
    }

    cudaFree(d_ct);
    cudaFree(d_syn);
    cudaFree(d_loc_soa);
    cudaFree(d_err);
    if (d_err_validate != NULL) {
        cudaFree(d_err_validate);
    }
    if (pipeline_mode == CM_HOST_OUTPUT_PIPELINE_OVERLAP_WRITER) {
        for (int slot = 0; slot < writer_slot_count; ++slot) {
            if (h_err_overlap[slot] != NULL) {
                cudaFreeHost(h_err_overlap[slot]);
            }
        }
    } else if (h_err != NULL) {
        cudaFreeHost(h_err);
    }
    if (h_err_validate != NULL) {
        cudaFreeHost(h_err_validate);
    }
    cudaFreeHost(h_loc);
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
