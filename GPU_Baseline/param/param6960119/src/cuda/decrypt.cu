/*
 * Baseline CUDA decryption driver for the `6960119` parameter family.
 *
 * This parameter uses a dedicated implementation rather than the lighter
 * shared baseline template because its verified path mirrors the proven
 * `6960119` pipeline end-to-end and stays aligned with the CPU reference.
 */
#include "decrypt.h"

#include <stdio.h>
#include <string.h>
#include <time.h>

#if WRITE_ERRORSTREAM
static const char errorstream_path[] = "../../results/output/errorstream0_6960119.bin";
#endif
static const char profile_path[] = "../../results/profile/Profile_GPU_baseline_6960119.txt";
static const char profile_label[] = "GPU baseline";

typedef struct {
    float h2d_ms;
    float synd_ms;
    float bm_ms;
    float chien_ms;
    float d2h_ms;
} timing_totals_t;

gf *d_inverse_elements = NULL;

unsigned char secretkeys[crypto_kem_SECRETKEYBYTES] = {0};
unsigned char ciphertexts[KATNUM][crypto_kem_CIPHERTEXTBYTES] = {{0}};
gf g[SYS_T + 1];
gf L[SYS_N];
gf inverse_elements[sb][2 * SYS_T];
gf e_inv[SYS_N];

static double elapsed_wall_ms(const struct timespec *start, const struct timespec *end)
{
    return (end->tv_sec - start->tv_sec) * 1000.0
         + (end->tv_nsec - start->tv_nsec) / 1e6;
}

#if WRITE_ERRORSTREAM
static int append_errorstream_batch(const unsigned char *error_batch, int batch_count)
{
    FILE *stream = fopen(errorstream_path, "ab");

    if (stream == NULL) {
        perror("failed to open GPU errorstream output");
        return KAT_FILE_OPEN_ERROR;
    }

    for (int ciphertext_index = 0; ciphertext_index < batch_count; ++ciphertext_index) {
        const unsigned char *error_vector = error_batch + ciphertext_index * SYS_N;

        for (int index = 0; index < SYS_N; ++index) {
            if (error_vector[index] != 0 && fprintf(stream, " %d", index) < 0) {
                fclose(stream);
                return KAT_FILE_OPEN_ERROR;
            }
        }

        if (fputc('\n', stream) == EOF) {
            fclose(stream);
            return KAT_FILE_OPEN_ERROR;
        }
    }

    fclose(stream);
    return KAT_SUCCESS;
}
#endif

static int write_profile_summary(const timing_totals_t *totals, int batch_size, int total, double wall_ms)
{
    FILE *stream = fopen(profile_path, "w");
    double throughput = wall_ms > 0.0 ? (1000.0 * total) / wall_ms : 0.0;
    double kernel_ms = totals->synd_ms + totals->bm_ms + totals->chien_ms;
    double transfer_ms = totals->h2d_ms + totals->d2h_ms;
    double overhead_ms = wall_ms - (kernel_ms + transfer_ms);

    if (stream == NULL) {
        perror("failed to open GPU baseline profile output");
        return KAT_FILE_OPEN_ERROR;
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
    return KAT_SUCCESS;
}

__global__ void syndrome_kernel(
    const gf *__restrict__ d_inverse_elements_arg,
    const unsigned char *__restrict__ d_ciphertexts_arg,
    gf *__restrict__ d_syndromes)
{
    extern __shared__ gf warp_sums[];

    const int coefficient = blockIdx.x;
    const int ciphertext_index = blockIdx.y;
    const int lane = threadIdx.x;
    const int warp_id = lane >> 5;
    const int lane_in_warp = lane & 31;
    const int stride = 2 * SYS_T;

    gf sum = 0;
    for (int bit = lane; bit < sb; bit += blockDim.x) {
        unsigned char value = d_ciphertexts_arg[ciphertext_index * SYND_BYTES + (bit >> 3)];
        if ((value >> (bit & 7)) & 1u) {
            sum ^= d_inverse_elements_arg[bit * stride + coefficient];
        }
    }

    #pragma unroll
    for (int offset = 16; offset > 0; offset >>= 1) {
        sum ^= __shfl_down_sync(0xFFFFFFFFu, sum, offset);
    }

    if (lane_in_warp == 0) {
        warp_sums[warp_id] = sum;
    }
    __syncthreads();

    if (warp_id == 0 && lane_in_warp < (blockDim.x / 32)) {
        sum = warp_sums[lane_in_warp];
        for (int warp = lane_in_warp + 1; warp < (blockDim.x / 32); ++warp) {
            sum ^= warp_sums[warp];
        }
        if (lane_in_warp == 0) {
            d_syndromes[ciphertext_index * stride + coefficient] = sum;
        }
    }
}

__global__ void berlekamp_massey_kernel(const gf *d_syn, gf *d_loc)
{
    const int tid = threadIdx.x;
    const int ciphertext_index = blockIdx.y;

    __shared__ gf syndromes[2 * SYS_T];
    __shared__ gf current[SYS_T + 1];
    __shared__ gf previous[SYS_T + 1];
    __shared__ gf scratch[SYS_T + 1];
    __shared__ gf last_non_zero;
    __shared__ int degree;
    __shared__ gf discrepancy;

    if (tid < 2 * SYS_T) {
        syndromes[tid] = d_syn[ciphertext_index * (2 * SYS_T) + tid];
    }
    __syncthreads();

    if (tid == 0) {
        for (int index = 0; index <= SYS_T; ++index) {
            current[index] = 0;
            previous[index] = 0;
        }
        current[0] = 1;
        previous[1] = 1;
        last_non_zero = 1;
        degree = 0;
    }
    __syncthreads();

    for (int step = 0; step < 2 * SYS_T; ++step) {
        if (tid == 0) {
            discrepancy = 0;
            const int max_index = min(step, SYS_T);

            for (int index = 0; index <= max_index; ++index) {
                discrepancy ^= mul(current[index], syndromes[step - index]);
            }
        }
        __syncthreads();

        if (tid == 0 && discrepancy != 0) {
            const gf factor = p_gf_frac(last_non_zero, discrepancy);

            for (int index = 0; index <= SYS_T; ++index) {
                scratch[index] = current[index];
            }
            for (int index = 0; index <= SYS_T; ++index) {
                current[index] ^= mul(factor, previous[index]);
            }

            if (2 * degree <= step) {
                for (int index = 0; index <= SYS_T; ++index) {
                    previous[index] = scratch[index];
                }
                degree = step + 1 - degree;
                last_non_zero = discrepancy;
            }
        }
        __syncthreads();

        if (tid == 0) {
            for (int index = SYS_T; index >= 1; --index) {
                previous[index] = previous[index - 1];
            }
            previous[0] = 0;
        }
        __syncthreads();
    }

    if (tid <= SYS_T) {
        d_loc[ciphertext_index * (SYS_T + 1) + tid] = current[SYS_T - tid];
    }
}

__global__ void chien_search_kernel(
    const gf *__restrict__ d_sigma_all,
    unsigned char *__restrict__ d_error_all)
{
    const int ciphertext_index = blockIdx.y;

    if (threadIdx.x != 0) {
        return;
    }

    const gf *sigma = d_sigma_all + ciphertext_index * (SYS_T + 1);
    unsigned char *error_vector = d_error_all + ciphertext_index * SYS_N;

    for (int index = 0; index < SYS_N; ++index) {
        gf value = sigma[SYS_T];
        gf support = d_L[index];

        for (int coeff = SYS_T - 1; coeff >= 0; --coeff) {
            value = mul(value, support) ^ sigma[coeff];
        }

        error_vector[index] = (unsigned char)(value == 0);
    }
}

static int decrypt_all(const unsigned char (*host_ciphertexts)[crypto_kem_CIPHERTEXTBYTES])
{
    const int total = KATNUM;
    const int batch_size = BATCH_SIZE;
    const int threads_per_block = 256;
    const int syndrome_shared_mem = (threads_per_block / 32) * (int)sizeof(gf);
    int status = KAT_SUCCESS;

    unsigned char *d_ct = NULL;
    gf *d_syn = NULL;
    gf *d_loc = NULL;
    unsigned char *d_err = NULL;
    unsigned char *h_err_batch = NULL;

    cudaEvent_t ev_h2d_s = NULL;
    cudaEvent_t ev_h2d_e = NULL;
    cudaEvent_t ev_syn_s = NULL;
    cudaEvent_t ev_syn_e = NULL;
    cudaEvent_t ev_bm_s = NULL;
    cudaEvent_t ev_bm_e = NULL;
    cudaEvent_t ev_ch_s = NULL;
    cudaEvent_t ev_ch_e = NULL;
    cudaEvent_t ev_d2h_s = NULL;
    cudaEvent_t ev_d2h_e = NULL;

    timing_totals_t totals = {};
    struct timespec wall_start;
    struct timespec wall_end;
    int batch_count = (total + batch_size - 1) / batch_size;

#if WRITE_ERRORSTREAM
    FILE *clear_stream = fopen(errorstream_path, "wb");
    if (clear_stream == NULL) {
        perror("failed to reset GPU errorstream output");
        return KAT_FILE_OPEN_ERROR;
    }
    fclose(clear_stream);
#endif

    CUDA_CHECK(cudaMalloc(&d_ct, batch_size * crypto_kem_CIPHERTEXTBYTES));
    CUDA_CHECK(cudaMalloc(&d_syn, batch_size * 2 * SYS_T * sizeof(gf)));
    CUDA_CHECK(cudaMalloc(&d_loc, batch_size * (SYS_T + 1) * sizeof(gf)));
    CUDA_CHECK(cudaMalloc(&d_err, batch_size * SYS_N * sizeof(unsigned char)));
    CUDA_CHECK(cudaMallocHost(&h_err_batch, batch_size * SYS_N * sizeof(unsigned char)));

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

    clock_gettime(CLOCK_MONOTONIC, &wall_start);

    for (int batch = 0; batch < batch_count; ++batch) {
        const int offset = batch * batch_size;
        const int actual_batch = (offset + batch_size > total) ? (total - offset) : batch_size;
        float h2d_ms = 0.0f;
        float synd_ms = 0.0f;
        float bm_ms = 0.0f;
        float chien_ms = 0.0f;
        float d2h_ms = 0.0f;

        CUDA_CHECK(cudaEventRecord(ev_h2d_s));
        CUDA_CHECK(cudaMemcpy(
            d_ct,
            &host_ciphertexts[offset][0],
            actual_batch * crypto_kem_CIPHERTEXTBYTES,
            cudaMemcpyHostToDevice));
        CUDA_CHECK(cudaEventRecord(ev_h2d_e));

        CUDA_CHECK(cudaEventRecord(ev_syn_s));
        syndrome_kernel<<<dim3(2 * SYS_T, actual_batch), threads_per_block, syndrome_shared_mem>>>(
            d_inverse_elements,
            d_ct,
            d_syn);
        CUDA_CHECK(cudaGetLastError());
        CUDA_CHECK(cudaEventRecord(ev_syn_e));

        CUDA_CHECK(cudaEventRecord(ev_bm_s));
        berlekamp_massey_kernel<<<dim3(1, actual_batch), 256>>>(d_syn, d_loc);
        CUDA_CHECK(cudaGetLastError());
        CUDA_CHECK(cudaEventRecord(ev_bm_e));

        CUDA_CHECK(cudaEventRecord(ev_ch_s));
        chien_search_kernel<<<dim3(1, actual_batch), 32>>>(d_loc, d_err);
        CUDA_CHECK(cudaGetLastError());
        CUDA_CHECK(cudaEventRecord(ev_ch_e));

        CUDA_CHECK(cudaEventRecord(ev_d2h_s));
        CUDA_CHECK(cudaMemcpy(
            h_err_batch,
            d_err,
            actual_batch * SYS_N * sizeof(unsigned char),
            cudaMemcpyDeviceToHost));
        CUDA_CHECK(cudaEventRecord(ev_d2h_e));
        CUDA_CHECK(cudaDeviceSynchronize());

        CUDA_CHECK(cudaEventElapsedTime(&h2d_ms, ev_h2d_s, ev_h2d_e));
        CUDA_CHECK(cudaEventElapsedTime(&synd_ms, ev_syn_s, ev_syn_e));
        CUDA_CHECK(cudaEventElapsedTime(&bm_ms, ev_bm_s, ev_bm_e));
        CUDA_CHECK(cudaEventElapsedTime(&chien_ms, ev_ch_s, ev_ch_e));
        CUDA_CHECK(cudaEventElapsedTime(&d2h_ms, ev_d2h_s, ev_d2h_e));

        totals.h2d_ms += h2d_ms;
        totals.synd_ms += synd_ms;
        totals.bm_ms += bm_ms;
        totals.chien_ms += chien_ms;
        totals.d2h_ms += d2h_ms;

#if WRITE_ERRORSTREAM
        status = append_errorstream_batch(h_err_batch, actual_batch);
        if (status != KAT_SUCCESS) {
            break;
        }
#endif
    }

    if (status == KAT_SUCCESS) {
        clock_gettime(CLOCK_MONOTONIC, &wall_end);
        status = write_profile_summary(&totals, batch_size, total, elapsed_wall_ms(&wall_start, &wall_end));
    }

    if (ev_h2d_s != NULL) {
        CUDA_CHECK(cudaEventDestroy(ev_h2d_s));
    }
    if (ev_h2d_e != NULL) {
        CUDA_CHECK(cudaEventDestroy(ev_h2d_e));
    }
    if (ev_syn_s != NULL) {
        CUDA_CHECK(cudaEventDestroy(ev_syn_s));
    }
    if (ev_syn_e != NULL) {
        CUDA_CHECK(cudaEventDestroy(ev_syn_e));
    }
    if (ev_bm_s != NULL) {
        CUDA_CHECK(cudaEventDestroy(ev_bm_s));
    }
    if (ev_bm_e != NULL) {
        CUDA_CHECK(cudaEventDestroy(ev_bm_e));
    }
    if (ev_ch_s != NULL) {
        CUDA_CHECK(cudaEventDestroy(ev_ch_s));
    }
    if (ev_ch_e != NULL) {
        CUDA_CHECK(cudaEventDestroy(ev_ch_e));
    }
    if (ev_d2h_s != NULL) {
        CUDA_CHECK(cudaEventDestroy(ev_d2h_s));
    }
    if (ev_d2h_e != NULL) {
        CUDA_CHECK(cudaEventDestroy(ev_d2h_e));
    }

    if (d_ct != NULL) {
        CUDA_CHECK(cudaFree(d_ct));
    }
    if (d_syn != NULL) {
        CUDA_CHECK(cudaFree(d_syn));
    }
    if (d_loc != NULL) {
        CUDA_CHECK(cudaFree(d_loc));
    }
    if (d_err != NULL) {
        CUDA_CHECK(cudaFree(d_err));
    }
    if (h_err_batch != NULL) {
        CUDA_CHECK(cudaFreeHost(h_err_batch));
    }

    return status;
}

int main(void)
{
    int status = initialisation(secretkeys, ciphertexts, NULL, L, g);

    if (status != 0) {
        return KAT_FILE_OPEN_ERROR;
    }

    compute_inverses();
    initialize_cuda_state();

    status = decrypt_all(ciphertexts);
    release_cuda_state();
    CUDA_CHECK(cudaDeviceReset());

    return status;
}
