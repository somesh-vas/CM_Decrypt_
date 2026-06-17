/*
   Shared KAT-style test-vector generator for McEliece variants.
   Generates one secret key and CT_PER_SK ciphertexts per run.
*/

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

#include "crypto_kem.h"
#include "nist/rng.h"

#define KAT_SUCCESS 0
#define KAT_FILE_OPEN_ERROR -1
#define KAT_CRYPTO_FAILURE -4

#ifndef CT_PER_SK
#ifdef KATNUM
#define CT_PER_SK KATNUM
#else
#define CT_PER_SK 10
#endif
#endif

static int write_binary(FILE *fp, const unsigned char *data, size_t len)
{
    return fwrite(data, 1, len, fp) == len ? 0 : -1;
}

static int ensure_output_dir(void)
{
    if (mkdir("../test_vectors", 0775) != 0 && errno != EEXIST)
        return -1;

    if (mkdir("../test_vectors/Cipher_Sk", 0775) != 0 && errno != EEXIST)
        return -1;

    return 0;
}

static int build_output_path(char *path, size_t path_len, const char *prefix)
{
    const char *suffix = crypto_kem_PRIMITIVE;
    const char *prefix_to_trim = "mceliece";
    size_t trim_len = strlen(prefix_to_trim);
    int written;

    if (strncmp(suffix, prefix_to_trim, trim_len) == 0)
        suffix += trim_len;

    written = snprintf(path, path_len, "../test_vectors/Cipher_Sk/%s_%s.bin", prefix, suffix);
    if (written < 0 || (size_t)written >= path_len)
        return -1;

    return 0;
}

int main(void)
{
    unsigned char entropy_input[48];
    unsigned char seed[48];
    FILE *ct_file = NULL;
    FILE *sk_file = NULL;
    char ct_path[128];
    char sk_path[128];
    int i;
    int kem_rc;
    int ret_val = KAT_SUCCESS;
    unsigned char *ct = NULL;
    unsigned char *ss = NULL;
    unsigned char *pk = NULL;
    unsigned char *sk = NULL;

    if (ensure_output_dir() != 0) {
        perror("Error creating ../test_vectors/Cipher_Sk");
        return KAT_FILE_OPEN_ERROR;
    }

    if (build_output_path(ct_path, sizeof(ct_path), "ct") != 0 ||
        build_output_path(sk_path, sizeof(sk_path), "sk") != 0) {
        fprintf(stderr, "Error building output file paths\n");
        return KAT_FILE_OPEN_ERROR;
    }

    for (i = 0; i < 48; i++)
        entropy_input[i] = (unsigned char)i;
    randombytes_init(entropy_input, NULL, 256);
    randombytes(seed, sizeof(seed));

    ct = malloc(crypto_kem_CIPHERTEXTBYTES);
    ss = malloc(crypto_kem_BYTES);
    pk = malloc(crypto_kem_PUBLICKEYBYTES);
    sk = malloc(crypto_kem_SECRETKEYBYTES);
    if (!ct || !ss || !pk || !sk) {
        fprintf(stderr, "buffer allocation failed\n");
        ret_val = KAT_CRYPTO_FAILURE;
        goto cleanup;
    }

    ct_file = fopen(ct_path, "wb");
    if (!ct_file) {
        perror("Error opening ct output file");
        ret_val = KAT_FILE_OPEN_ERROR;
        goto cleanup;
    }

    sk_file = fopen(sk_path, "wb");
    if (!sk_file) {
        perror("Error opening sk output file");
        ret_val = KAT_FILE_OPEN_ERROR;
        goto cleanup;
    }

    randombytes_init(seed, NULL, 256);

    kem_rc = crypto_kem_keypair(pk, sk);
    if (kem_rc != 0) {
        fprintf(stderr, "crypto_kem_keypair returned <%d>\n", kem_rc);
        ret_val = KAT_CRYPTO_FAILURE;
        goto cleanup;
    }

    if (write_binary(sk_file, sk, crypto_kem_SECRETKEYBYTES) != 0) {
        perror("Error writing sk output file");
        ret_val = KAT_FILE_OPEN_ERROR;
        goto cleanup;
    }

    for (i = 0; i < CT_PER_SK; i++) {
        kem_rc = crypto_kem_enc(ct, ss, pk);
        if (kem_rc != 0) {
            fprintf(stderr, "crypto_kem_enc returned <%d>\n", kem_rc);
            ret_val = KAT_CRYPTO_FAILURE;
            goto cleanup;
        }

        if (write_binary(ct_file, ct, crypto_kem_CIPHERTEXTBYTES) != 0) {
            perror("Error writing ct output file");
            ret_val = KAT_FILE_OPEN_ERROR;
            goto cleanup;
        }
    }

cleanup:
    if (ct_file && fclose(ct_file) != 0 && ret_val == KAT_SUCCESS)
        ret_val = KAT_FILE_OPEN_ERROR;
    if (sk_file && fclose(sk_file) != 0 && ret_val == KAT_SUCCESS)
        ret_val = KAT_FILE_OPEN_ERROR;

    free(ct);
    free(ss);
    free(pk);
    free(sk);

    return ret_val;
}
