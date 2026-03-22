/*
 * CPU decryption driver for the `6688128` parameter family.
 *
 * This file owns the runtime loop: parse `KATNUM`, load shared test vectors,
 * precompute secret-key-dependent tables once, then run syndrome generation,
 * Berlekamp-Massey, and root evaluation for each ciphertext.
 */
#include <time.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <float.h>

#if defined(__x86_64__) || defined(_M_X64)
#include <x86intrin.h>
#define HAVE_RDTSC 1
#else
#define HAVE_RDTSC 0
#endif

#include "common.h"
#include "gf.h"
#include "bm.h"
#include "root.h"

/* ───────────────────────── helper ───────────────────────── */

static inline double tdiff_usec(const struct timespec *a,
const struct timespec *b)
/* difference b-a in µs */
{
    return 1.0e6 * (b->tv_sec  - a->tv_sec)
    + 1.0e-3 * (b->tv_nsec - a->tv_nsec);
}

static inline uint64_t rdtsc(void)
{
#if HAVE_RDTSC
    return __rdtsc();
#else
    return 0;
#endif
}

/* Shared decode state populated by `initialisation(...)` in `util.c`. */
unsigned char secretkeys[crypto_kem_SECRETKEYBYTES];
unsigned char *ciphertexts;

gf g[SYS_T + 1];
gf L[SYS_N];

gf e_inv_LOOP_1D[sb * 2 * SYS_T];
gf inverse_elements[SYS_N][2 * SYS_T];
gf e_inv[SYS_N];

/* Per-ciphertext scratch reused across the main loop. */
static unsigned char r[SYS_N / 8];
static gf  s[SYS_T * 2];
static gf  locator[SYS_T + 1];
static gf  images[SYS_N];
static int e[SYS_N / 8];

/* ───────────────────── timers & counters ─────────────────── */
static double tot_usec = 0.0, min_usec = DBL_MAX, max_usec = 0.0;
static double synd_usec = 0.0, bm_usec = 0.0, root_usec = 0.0;

#if HAVE_RDTSC
static uint64_t tot_cycles = 0, min_cycles = (uint64_t)-1, max_cycles = 0;
static uint64_t synd_cycles = 0, bm_cycles = 0, root_cycles = 0;
#endif

/* ───────────────────────────  main  ─────────────────────── */
int main(int argc, char **argv)
{
    char *endptr = NULL;
    long parsed_katnum = KATNUM;
    if (argc > 1) {
        parsed_katnum = strtol(argv[1], &endptr, 10);
        if (*argv[1] == '\0' || *endptr != '\0' || parsed_katnum <= 0) {
            fprintf(stderr, "Usage: %s [KATNUM>0]\n", argv[0]);
            return KAT_CRYPTO_FAILURE;
        }
    }
    size_t katnum = (size_t) parsed_katnum;

    ciphertexts = malloc(katnum * crypto_kem_CIPHERTEXTBYTES);
    if (ciphertexts == NULL) {
        perror("malloc(ciphertexts)");
        return KAT_CRYPTO_FAILURE;
    }

    if (initialisation(secretkeys, ciphertexts, katnum, /*sk=*/NULL, L, g) != 0) {
        free(ciphertexts);
        return KAT_FILE_OPEN_ERROR;
    }

    /* The inverse-power table depends only on the secret key, not the ciphertext. */
    compute_inverses();

    struct timespec wall_beg;  clock_gettime(CLOCK_MONOTONIC, &wall_beg);

    for (size_t tv = 0; tv < katnum; ++tv)
    {
        /* Only the syndrome bytes are meaningful decoder input. */
        memcpy(r, ciphertexts + tv * crypto_kem_CIPHERTEXTBYTES, SYND_BYTES);
        memset(r + SYND_BYTES, 0, sizeof(r) - SYND_BYTES);

        struct timespec t0, t1, t2, t3;
        // uint64_t c0 = rdtsc();

        clock_gettime(CLOCK_MONOTONIC, &t0);
        synd(s, r);                        clock_gettime(CLOCK_MONOTONIC, &t1);
        bm(locator, s);                    clock_gettime(CLOCK_MONOTONIC, &t2);

        root(images, locator, L);          clock_gettime(CLOCK_MONOTONIC, &t3);
        // uint64_t c3 = rdtsc();

        /* Convert zero-valued root images into packed error bits. */
        memset(e, 0, sizeof(e));
        for (int i = 0; i < SYS_N; ++i)
        if (!images[i])
        e[i >> 3] |= 1 << (i & 7);

        /* µs statistics */
        double us_synd = tdiff_usec(&t0, &t1);
        double us_bm   = tdiff_usec(&t1, &t2);
        double us_root = tdiff_usec(&t2, &t3);
        double us_tot  = tdiff_usec(&t0, &t3);

        synd_usec += us_synd;   bm_usec += us_bm;   root_usec += us_root;
        tot_usec  += us_tot;
        if (us_tot < min_usec) min_usec = us_tot;
        if (us_tot > max_usec) max_usec = us_tot;

        // #if HAVE_RDTSC
        //         uint64_t cyc_synd = rdtsc() - c0;              /* misuse temporaries */
        //         uint64_t cyc_bm   = rdtsc() - rdtsc();         /* dummy, will fix   */

        //         uint64_t c1 = c0 + (uint64_t)(us_synd * 1e3);  /* rough split       */
        //         uint64_t c2 = c1 + (uint64_t)(us_bm   * 1e3);

        //         synd_cycles += c1 - c0;
        //         bm_cycles   += c2 - c1;
        //         root_cycles += c3 - c2;

        //         uint64_t cyc_tot = c3 - c0;
        //         tot_cycles += cyc_tot;
        //         if (cyc_tot < min_cycles) min_cycles = cyc_tot;
        //         if (cyc_tot > max_cycles) max_cycles = cyc_tot;
        // #endif

        /* optional: print error positions */
        // for (int i = 0; i < SYS_N; ++i)
        //     if (e[i >> 3] & (1 << (i & 7)))
        //         printf(" %d", i);
        // putchar('\n');

        /* Persist one text line per ciphertext for CPU/GPU compare scripts. */
        {
            FILE *f = fopen("../../results/output/errorstream0_6688128.bin", "ab");
            if (f) {
                for (int i = 0; i < SYS_N; ++i)
                if (e[i >> 3] & (1 << (i & 7)))
                fprintf(f, " %d", i);
                fputc('\n', f);
                fclose(f);
            } else {
                perror("fopen(\"errorstream0.bin\")");
            }
        } }

    struct timespec wall_end;  clock_gettime(CLOCK_MONOTONIC, &wall_end);
    double wall_sec = 1.0e-6 * tdiff_usec(&wall_beg, &wall_end);

    /* ───────────────────── report ───────────────────── */
    printf("\n===== CPU single-thread baseline =====\n");
    printf("ciphertexts processed : %zu\n", katnum);
    printf("total compute time    : %.3f  s (wall: %.3f s)\n",
    tot_usec / 1e6, wall_sec);
    printf("avg / min / max       : %.3f / %.3f / %.3f  ms\n",
    (tot_usec / katnum) / 1e3,
    min_usec / 1e3, max_usec / 1e3);
    printf("throughput            : %.2f  cw/s\n",
    katnum / wall_sec);
    printf("--- stage breakdown (average) --------\n");
    printf("  synd   : %.3f µs\n", synd_usec / katnum);
    printf("  BM     : %.3f µs\n", bm_usec   / katnum);
    printf("  root   : %.3f µs\n", root_usec / katnum);

#if HAVE_RDTSC
    const double GHz = 3.2;   /* fix or query /proc/cpuinfo */
    printf("\n===== CPU cycles (@%.1f GHz) =====\n", GHz);
    printf("avg / min / max       : %.1f / %.1f / %.1f  ×10^6 cycles\n",
    (double)tot_cycles / katnum / 1e6,
    (double)min_cycles        / 1e6,
    (double)max_cycles        / 1e6);
    printf("--- stage breakdown (average) --------\n");
    printf("  synd   : %.1f ×10^6 cycles\n", synd_cycles / (double)katnum / 1e6);
    printf("  BM     : %.1f ×10^6 cycles\n", bm_cycles   / (double)katnum / 1e6);
    printf("  root   : %.1f ×10^6 cycles\n", root_cycles / (double)katnum / 1e6);
#endif

    free(ciphertexts);
    return KAT_SUCCESS;
}
