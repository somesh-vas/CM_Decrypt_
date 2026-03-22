/*
 * CPU decryption driver for the `6960119` parameter family.
 *
 * This is the cleanest CPU reference entry point in the workspace and is the
 * best file to read first when tracing the host-side decode pipeline.
 */
#include <stdio.h>
#include <stdlib.h>
#include <float.h>
#include <string.h>
#include <time.h>

#include "bm.h"
#include "common.h"
#include "gf.h"
#include "root.h"

#define ERRORSTREAM_PATH "../../results/output/errorstream0_6960119.bin"

static double elapsed_usec(const struct timespec *start, const struct timespec *end)
{
    return 1.0e6 * (end->tv_sec - start->tv_sec)
         + 1.0e-3 * (end->tv_nsec - start->tv_nsec);
}

static int parse_katnum(int argc, char **argv, size_t *katnum_out)
{
    char *endptr = NULL;
    long parsed_katnum = KATNUM;

    if (argc > 1) {
        parsed_katnum = strtol(argv[1], &endptr, 10);
        if (*argv[1] == '\0' || *endptr != '\0' || parsed_katnum <= 0) {
            fprintf(stderr, "Usage: %s [KATNUM>0]\n", argv[0]);
            return -1;
        }
    }

    *katnum_out = (size_t)parsed_katnum;
    return 0;
}

static void build_error_vector(unsigned char *error_vector, const gf *error_images)
{
    /* root() reports roots as zero-valued images, so invert that convention here. */
    memset(error_vector, 0, SYS_N / 8);

    for (int index = 0; index < SYS_N; ++index) {
        if (error_images[index] == 0) {
            error_vector[index >> 3] |= (unsigned char)(1u << (index & 7));
        }
    }
}

static int write_error_positions(FILE *stream, const unsigned char *error_vector)
{
    for (int index = 0; index < SYS_N; ++index) {
        if (error_vector[index >> 3] & (1u << (index & 7))) {
            if (fprintf(stream, " %d", index) < 0) {
                return -1;
            }
        }
    }

    return fputc('\n', stream) == '\n' ? 0 : -1;
}

static void print_summary(
    size_t katnum,
    double total_usec,
    double min_usec,
    double max_usec,
    double wall_sec,
    double synd_usec,
    double bm_usec,
    double root_usec)
{
    printf("\n===== CPU single-thread baseline =====\n");
    printf("ciphertexts processed : %zu\n", katnum);
    printf("total compute time    : %.3f s (wall: %.3f s)\n", total_usec / 1e6, wall_sec);
    printf(
        "avg / min / max       : %.3f / %.3f / %.3f ms\n",
        (total_usec / katnum) / 1e3,
        min_usec / 1e3,
        max_usec / 1e3);
    printf("throughput            : %.2f cw/s\n", katnum / wall_sec);
    printf("--- stage breakdown (average) --------\n");
    printf("  synd   : %.3f us\n", synd_usec / katnum);
    printf("  BM     : %.3f us\n", bm_usec / katnum);
    printf("  root   : %.3f us\n", root_usec / katnum);
}

unsigned char secretkeys[crypto_kem_SECRETKEYBYTES];
unsigned char *ciphertexts = NULL;

/* Shared decode state derived once from the secret key. */
gf g[SYS_T + 1];
gf L[SYS_N];
gf inverse_elements[sb][2 * SYS_T];
gf e_inv[SYS_N];

/* Per-ciphertext scratch reused across the main loop. */
static unsigned char syndrome_input[SYS_N / 8];
static gf syndrome_values[2 * SYS_T];
static gf locator_poly[SYS_T + 1];
static gf error_images[SYS_N];
static unsigned char error_vector[SYS_N / 8];

int main(int argc, char **argv)
{
    size_t katnum = 0;
    double total_usec = 0.0;
    double min_usec = DBL_MAX;
    double max_usec = 0.0;
    double synd_usec = 0.0;
    double bm_usec = 0.0;
    double root_usec = 0.0;
    FILE *errorstream = NULL;
    int status = KAT_SUCCESS;

    if (parse_katnum(argc, argv, &katnum) != 0) {
        return KAT_CRYPTO_FAILURE;
    }

    ciphertexts = malloc(katnum * crypto_kem_CIPHERTEXTBYTES);
    if (ciphertexts == NULL) {
        perror("malloc(ciphertexts)");
        return KAT_CRYPTO_FAILURE;
    }

    if (initialisation(secretkeys, ciphertexts, katnum, NULL, L, g) != 0) {
        status = KAT_FILE_OPEN_ERROR;
        goto cleanup;
    }

    /* Precompute support-point powers once and reuse them for every syndrome. */
    compute_inverses();
    errorstream = fopen(ERRORSTREAM_PATH, "wb");
    if (errorstream == NULL) {
        perror("failed to open CPU errorstream output");
        status = KAT_FILE_OPEN_ERROR;
        goto cleanup;
    }

    struct timespec wall_beg;
    struct timespec wall_end;
    clock_gettime(CLOCK_MONOTONIC, &wall_beg);

    for (size_t test_vector = 0; test_vector < katnum; ++test_vector) {
        struct timespec stage_start;
        struct timespec after_synd;
        struct timespec after_bm;
        struct timespec after_root;
        double current_synd_usec;
        double current_bm_usec;
        double current_root_usec;
        double current_total_usec;

        /*
         * The decoder only consumes the syndrome portion of the ciphertext.
         * Zero the scratch tail so the bit-walk remains bounded and deterministic.
         */
        memcpy(syndrome_input, ciphertexts + test_vector * crypto_kem_CIPHERTEXTBYTES, SYND_BYTES);
        memset(syndrome_input + SYND_BYTES, 0, sizeof(syndrome_input) - SYND_BYTES);

        clock_gettime(CLOCK_MONOTONIC, &stage_start);
        synd(syndrome_values, syndrome_input);
        clock_gettime(CLOCK_MONOTONIC, &after_synd);

        /* Decode the locator polynomial before evaluating it over the support set. */
        bm(locator_poly, syndrome_values);
        clock_gettime(CLOCK_MONOTONIC, &after_bm);

        root(error_images, locator_poly, L);
        clock_gettime(CLOCK_MONOTONIC, &after_root);

        build_error_vector(error_vector, error_images);
        if (write_error_positions(errorstream, error_vector) != 0) {
            perror("failed to write CPU errorstream");
            status = KAT_FILE_OPEN_ERROR;
            goto cleanup;
        }

        current_synd_usec = elapsed_usec(&stage_start, &after_synd);
        current_bm_usec = elapsed_usec(&after_synd, &after_bm);
        current_root_usec = elapsed_usec(&after_bm, &after_root);
        current_total_usec = elapsed_usec(&stage_start, &after_root);

        synd_usec += current_synd_usec;
        bm_usec += current_bm_usec;
        root_usec += current_root_usec;
        total_usec += current_total_usec;
        if (current_total_usec < min_usec) {
            min_usec = current_total_usec;
        }
        if (current_total_usec > max_usec) {
            max_usec = current_total_usec;
        }
    }

    clock_gettime(CLOCK_MONOTONIC, &wall_end);
    print_summary(
        katnum,
        total_usec,
        min_usec,
        max_usec,
        elapsed_usec(&wall_beg, &wall_end) / 1e6,
        synd_usec,
        bm_usec,
        root_usec);

cleanup:
    if (errorstream != NULL) {
        fclose(errorstream);
    }
    free(ciphertexts);
    return status;
}
