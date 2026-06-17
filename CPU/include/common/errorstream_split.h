#ifndef CM_ERRORSTREAM_SPLIT_H
#define CM_ERRORSTREAM_SPLIT_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CM_ERRORSTREAM_DEFAULT_CHUNK_SIZE 50000u

static inline int cm_errorstream_split_enabled(void)
{
    const char *value = getenv("CM_ERRORSTREAM_SPLIT_CHUNKS");
    return value != NULL && strcmp(value, "1") == 0;
}

static inline size_t cm_errorstream_chunk_size(void)
{
    const char *value = getenv("CM_ERRORSTREAM_SPLIT_CHUNK_SIZE");
    char *endptr = NULL;
    unsigned long parsed = CM_ERRORSTREAM_DEFAULT_CHUNK_SIZE;

    if (value != NULL && value[0] != '\0') {
        parsed = strtoul(value, &endptr, 10);
        if (*endptr != '\0' || parsed == 0) {
            fprintf(stderr, "invalid CM_ERRORSTREAM_SPLIT_CHUNK_SIZE=%s\n", value);
            return 0;
        }
    }

    return (size_t)parsed;
}

static inline int cm_errorstream_path(char *buffer, size_t size, int param, size_t ciphertext_index)
{
    if (cm_errorstream_split_enabled()) {
        size_t chunk_size = cm_errorstream_chunk_size();
        if (chunk_size == 0) {
            return -1;
        }
        if (snprintf(
                buffer,
                size,
                "../../results/output/errorstream0_%d_chunk%03zu.bin",
                param,
                ciphertext_index / chunk_size) >= (int)size) {
            fprintf(stderr, "split errorstream output path is too long\n");
            return -1;
        }
    } else if (snprintf(buffer, size, "../../results/output/errorstream0_%d.bin", param) >= (int)size) {
        fprintf(stderr, "errorstream output path is too long\n");
        return -1;
    }

    return 0;
}

static inline const char *cm_errorstream_mode(size_t ciphertext_index)
{
    if (cm_errorstream_split_enabled()) {
        size_t chunk_size = cm_errorstream_chunk_size();
        if (chunk_size != 0 && ciphertext_index % chunk_size == 0) {
            return "wb";
        }
    }

    return "ab";
}

#endif
