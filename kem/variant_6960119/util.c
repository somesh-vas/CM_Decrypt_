#include "util.h"

#include "params.h"

void store_gf(unsigned char *dest, gf value)
{
    dest[0] = (unsigned char)(value & 0xFFu);
    dest[1] = (unsigned char)(value >> 8);
}

uint16_t load_gf(const unsigned char *src)
{
    uint16_t value = src[1];

    value <<= 8;
    value |= src[0];

    return (uint16_t)(value & GFMASK);
}

uint32_t load4(const unsigned char *src)
{
    uint32_t value = src[3];

    for (int index = 2; index >= 0; --index) {
        value <<= 8;
        value |= src[index];
    }

    return value;
}

void store8(unsigned char *dest, uint64_t value)
{
    dest[0] = (unsigned char)((value >> 0) & 0xFFu);
    dest[1] = (unsigned char)((value >> 8) & 0xFFu);
    dest[2] = (unsigned char)((value >> 16) & 0xFFu);
    dest[3] = (unsigned char)((value >> 24) & 0xFFu);
    dest[4] = (unsigned char)((value >> 32) & 0xFFu);
    dest[5] = (unsigned char)((value >> 40) & 0xFFu);
    dest[6] = (unsigned char)((value >> 48) & 0xFFu);
    dest[7] = (unsigned char)((value >> 56) & 0xFFu);
}

uint64_t load8(const unsigned char *src)
{
    uint64_t value = src[7];

    for (int index = 6; index >= 0; --index) {
        value <<= 8;
        value |= src[index];
    }

    return value;
}

gf bitrev(gf value)
{
    value = (gf)(((value & 0x00FFu) << 8) | ((value & 0xFF00u) >> 8));
    value = (gf)(((value & 0x0F0Fu) << 4) | ((value & 0xF0F0u) >> 4));
    value = (gf)(((value & 0x3333u) << 2) | ((value & 0xCCCCu) >> 2));
    value = (gf)(((value & 0x5555u) << 1) | ((value & 0xAAAAu) >> 1));

    return (gf)(value >> 3);
}
