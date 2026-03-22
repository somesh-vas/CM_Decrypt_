#define _POSIX_C_SOURCE 200809L

/*
 * Host-side setup helpers for the optimised CUDA path.
 *
 * The functions here load the shared vectors, derive the support/Goppa state
 * from the secret key, and build the inverse-power table reused by every
 * ciphertext processed in a run.
 */
#include "common.h"
#include "gf.h"
#include "root.h"
#include <sys/types.h>
#include <unistd.h>

#define SECRET_KEY_PREFIX_BYTES 40
#define MAX_RUNTIME_PATH 4096

extern gf L[SYS_N];
extern gf g[SYS_T + 1];
extern gf e_inv[SYS_N];
extern gf inverse_elements[sb][2 * SYS_T];

static int build_repo_relative_path(char *buffer, size_t size, const char *relative_suffix)
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

    cursor = strrchr(exe_path, '/');
    if (cursor == NULL) {
        fprintf(stderr, "failed to resolve repository directory\n");
        return -1;
    }
    *cursor = '\0'; /* repo root */

    if (snprintf(buffer, size, "%s/%s", exe_path, relative_suffix) >= (int)size) {
        fprintf(stderr, "resolved path is too long: %s\n", relative_suffix);
        return -1;
    }

    return 0;
}

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
    char ct_path[MAX_RUNTIME_PATH];
    char sk_path[MAX_RUNTIME_PATH];
    FILE *ct_file = NULL;
    FILE *sk_file = NULL;
    int status = 0;

    if (build_repo_relative_path(ct_path, sizeof(ct_path), "kem/test_vectors/Cipher_Sk/ct_6960119.bin") != 0 ||
        build_repo_relative_path(sk_path, sizeof(sk_path), "kem/test_vectors/Cipher_Sk/sk_6960119.bin") != 0) {
        return -1;
    }

    ct_file = fopen(ct_path, "rb");
    sk_file = fopen(sk_path, "rb");

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
