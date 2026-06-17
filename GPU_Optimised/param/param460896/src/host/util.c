/*
 * Host-side setup helpers for the optimised CUDA path.
 *
 * This file reconstructs the secret-key-derived decode state once on the CPU,
 * then uploads it into the lookup tables consumed by the optimised kernels.
 */
#include "common.h"
#include "root.h"
#include "gf.h"

#define TEST_VECTOR_DIR "../../../kem/test_vectors/Cipher_Sk"
#define SECRET_KEY_PREFIX_BYTES 40

extern gf L[SYS_N];
extern gf g[SYS_T + 1];
extern gf e_inv[SYS_N];
extern gf inverse_elements[sb][2 * SYS_T];

static int read_exact(FILE *stream, unsigned char *buffer, size_t element_size, size_t count, const char *label)
{
    if (fread(buffer, element_size, count, stream) != count) {
        fprintf(stderr, "Error reading %s\n", label);
        return -1;
    }

    return 0;
}

int initialisation(
    unsigned char *secretkeys,
    unsigned char (*ciphertexts)[crypto_kem_CIPHERTEXTBYTES],
    unsigned char *sk,
    gf *support,
    gf *goppa)
{
    FILE *ct_file = fopen(TEST_VECTOR_DIR "/ct_460896.bin", "rb");
    FILE *sk_file = fopen(TEST_VECTOR_DIR "/sk_460896.bin", "rb");
    int status = 0;

    if (ct_file == NULL || sk_file == NULL) {
        perror("Error opening optimised GPU test vectors");
        status = -1;
        goto cleanup;
    }

    if (read_exact(sk_file, secretkeys, crypto_kem_SECRETKEYBYTES, 1, "sk_460896.bin") != 0 ||
        read_exact(ct_file, (unsigned char *)ciphertexts, crypto_kem_CIPHERTEXTBYTES, KATNUM, "ct_460896.bin") != 0) {
        status = -1;
        goto cleanup;
    }

    /* Skip the metadata prefix, then decode the Goppa polynomial and support. */
    sk = secretkeys + SECRET_KEY_PREFIX_BYTES;
    for (int i = 0; i < SYS_T; ++i) {
        goppa[i] = load_gf(sk);
        sk += 2;
    }
    goppa[SYS_T] = 1;
    support_gen(support, sk);

cleanup:
    if (ct_file != NULL) {
        fclose(ct_file);
    }
    if (sk_file != NULL) {
        fclose(sk_file);
    }

    return status;
}

void compute_inverses(void)
{
    /* Precompute support-point powers once before any kernel launches. */
    for (int bit = 0; bit < sb; ++bit) {
        gf value = eval(g, L[bit]);
        gf inverse = gf_inv(gf_mul(value, value));

        e_inv[bit] = inverse;
        inverse_elements[bit][0] = inverse;
        for (int power = 1; power < 2 * SYS_T; ++power) {
            inverse_elements[bit][power] = gf_mul(inverse_elements[bit][power - 1], L[bit]);
        }
    }
}

void synd(gf *out, unsigned char *r)
{
    memset(out, 0, 2 * SYS_T * sizeof(gf));

    /* CPU-side reference syndrome builder used during setup/debugging. */
    for (int bit = 0; bit < sb; ++bit) {
        gf coefficient = (gf)((r[bit >> 3] >> (bit & 7)) & 1u);
        for (int power = 0; power < 2 * SYS_T; ++power) {
            out[power] = gf_add(out[power], gf_mul(inverse_elements[bit][power], coefficient));
        }
    }
}
