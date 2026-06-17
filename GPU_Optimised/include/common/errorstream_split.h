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

static inline int cm_errorstream_chunk_size(void)
{
    const char *value = getenv("CM_ERRORSTREAM_SPLIT_CHUNK_SIZE");
    char *endptr = NULL;
    long parsed = CM_ERRORSTREAM_DEFAULT_CHUNK_SIZE;

    if (value != NULL && value[0] != '\0') {
        parsed = strtol(value, &endptr, 10);
        if (*endptr != '\0' || parsed <= 0) {
            fprintf(stderr, "invalid CM_ERRORSTREAM_SPLIT_CHUNK_SIZE=%s\n", value);
            return 0;
        }
    }

    return (int)parsed;
}

static inline int cm_errorstream_effective_batch_size(int batch_size)
{
    int chunk_size;

    if (!cm_errorstream_split_enabled()) {
        return batch_size;
    }

    chunk_size = cm_errorstream_chunk_size();
    if (chunk_size == 0) {
        return 0;
    }

    return chunk_size < batch_size ? chunk_size : batch_size;
}

#endif
