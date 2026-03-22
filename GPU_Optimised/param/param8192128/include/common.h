#ifndef COMMON_H
#define COMMON_H

/* --------------------  standard headers  --------------------------- */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <time.h>

/* --------------------  library / test parameters  ------------------ */
#define KAT_SUCCESS           0
#define KAT_FILE_OPEN_ERROR  -1
#define KAT_CRYPTO_FAILURE   -4
#ifndef KATNUM
#define KATNUM 5
#endif
#define ciphert 1
#define BATCH_SIZE                  50000  /* batch size for decryption */
#define crypto_kem_SECRETKEYBYTES 14120
#define crypto_kem_CIPHERTEXTBYTES 208
#define GFBITS 13                    /* Field size: GF(2^13) */
#define SYS_N 8192
#define SYS_T 128

#define COND_BYTES  ((1 << (GFBITS-4)) * (2*GFBITS - 1))
#define IRR_BYTES   (SYS_T * 2)

#define PK_NROWS    (SYS_T * GFBITS)
#define PK_NCOLS    (SYS_N - PK_NROWS)
#define PK_ROW_BYTES  ((PK_NCOLS + 7) / 8)

#define SYND_BYTES  ((PK_NROWS + 7) / 8)

#define GFMASK      ((1 << GFBITS) - 1)
#define sb          (SYND_BYTES * 8)

/* helper */
#define min(a,b)    (( (a) < (b) ) ? (a) : (b))

/* -------------------------------------------------------------------
 * Fundamental field type
 * ------------------------------------------------------------------- */
typedef uint16_t gf;                   /* Field element storage; lower GFBITS bits are used */

/* -------------------------------------------------------------------
 * Constant-memory lookup table parameters for GF(2^GFBITS)
 * ------------------------------------------------------------------- */
#ifndef GF_LUT_H
#define GF_LUT_H

/* Multiplicative group order and lookup table size derived from GFBITS. */
#define GFLUT_ORDER   ((1u << GFBITS) - 1u)
#define GFLUT_SIZE    (1u << GFBITS)

#endif /* GF_LUT_H */

#endif /* COMMON_H */
