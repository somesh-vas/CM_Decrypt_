/*
 * Host-side setup helpers for the baseline CUDA path.
 *
 * The functions here load the shared vectors, derive the support/Goppa state
 * from the secret key, and build the inverse-power table reused by every
 * ciphertext processed in a run.
 */
#include "common.h"
#include "gf.h"
#include "root.h"

#define TEST_VECTOR_DIR "../../../kem/test_vectors/Cipher_Sk"
#define SECRET_KEY_PREFIX_BYTES 40

extern gf L[SYS_N];
extern gf g[SYS_T + 1];
extern gf e_inv[SYS_N];
extern gf inverse_elements[sb][2 * SYS_T];

static int read_exact(FILE *stream, unsigned char *buffer, size_t element_size, size_t count, const char *label)
{
    if (fread(buffer, element_size, count, stream) != count) {
        fprintf(stderr, "failed to read %s\n", label);
        return -1;
    }

    return 0;
}

static int load_test_vectors(
    unsigned char *secretkeys,
    unsigned char (*ciphertexts)[crypto_kem_CIPHERTEXTBYTES])
{
    const char ct_path[] = TEST_VECTOR_DIR "/ct_6960119.bin";
    const char sk_path[] = TEST_VECTOR_DIR "/sk_6960119.bin";
    FILE *ct_file = fopen(ct_path, "rb");
    FILE *sk_file = fopen(sk_path, "rb");
    int status = 0;

    if (ct_file == NULL || sk_file == NULL) {
        perror("failed to open 6960119 test vectors");
        status = -1;
        goto cleanup;
    }

    if (read_exact(sk_file, secretkeys, crypto_kem_SECRETKEYBYTES, 1, sk_path) != 0 ||
        read_exact(ct_file, (unsigned char *)ciphertexts, crypto_kem_CIPHERTEXTBYTES, KATNUM, ct_path) != 0) {
        status = -1;
    }

cleanup:
    if (ct_file != NULL) {
        fclose(ct_file);
    }
    if (sk_file != NULL) {
        fclose(sk_file);
    }

    return status;
}

static void initialise_secret_key_state(const unsigned char *secretkey_bytes, gf *support, gf *goppa)
{
    /* Skip the KEM metadata prefix and decode the Goppa polynomial payload. */
    const unsigned char *sk_ptr = secretkey_bytes + SECRET_KEY_PREFIX_BYTES;

    for (int i = 0; i < SYS_T; ++i) {
        goppa[i] = load_gf(sk_ptr);
        sk_ptr += 2;
    }
    goppa[SYS_T] = 1;

    support_gen(support, sk_ptr);
}

int initialisation(
    unsigned char *secretkeys,
    unsigned char (*ciphertexts)[crypto_kem_CIPHERTEXTBYTES],
    unsigned char *sk,
    gf *support,
    gf *goppa)
{
    (void)sk;

    if (load_test_vectors(secretkeys, ciphertexts) != 0) {
        return -1;
    }

    initialise_secret_key_state(secretkeys, support, goppa);
    return 0;
}

void compute_inverses(void)
{
    for (int bit = 0; bit < sb; ++bit) {
        gf value = eval(g, L[bit]);
        gf inverse = gf_inv(gf_mul(value, value));

        /* Cache inverse powers so every ciphertext can reuse the same support table. */
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

    /* Each set ciphertext bit contributes one precomputed inverse-power row. */
    for (int bit = 0; bit < sb; ++bit) {
        gf coefficient = (gf)((r[bit >> 3] >> (bit & 7)) & 1u);

        for (int power = 0; power < 2 * SYS_T; ++power) {
            out[power] = gf_add(out[power], gf_mul(inverse_elements[bit][power], coefficient));
        }
    }
}
