#include "gf.h"

#include "params.h"

gf gf_iszero(gf value)
{
    uint32_t masked = value;

    masked -= 1;
    masked >>= 19;

    return (gf)masked;
}

gf gf_add(gf lhs, gf rhs)
{
    return lhs ^ rhs;
}

gf gf_mul(gf lhs, gf rhs)
{
    uint64_t product = (uint64_t)lhs * (rhs & 1u);

    for (int bit = 1; bit < GFBITS; ++bit) {
        product ^= (uint64_t)lhs * (rhs & (1u << bit));
    }

    /* Reduce modulo x^13 + x^4 + x^3 + x + 1. */
    uint64_t reduction = product & 0x1FF0000u;
    product ^= (reduction >> 9) ^ (reduction >> 10) ^ (reduction >> 12) ^ (reduction >> 13);

    reduction = product & 0x000E000u;
    product ^= (reduction >> 9) ^ (reduction >> 10) ^ (reduction >> 12) ^ (reduction >> 13);

    return (gf)(product & GFMASK);
}

static inline gf gf_sq2(gf value)
{
    const uint64_t bit_spread_masks[] = {
        0x1111111111111111ULL,
        0x0303030303030303ULL,
        0x000F000F000F000FULL,
        0x000000FF000000FFULL,
    };
    const uint64_t reduction_masks[] = {
        0x0001FF0000000000ULL,
        0x000000FF80000000ULL,
        0x000000007FC00000ULL,
        0x00000000003FE000ULL,
    };
    uint64_t expanded = value;

    expanded = (expanded | (expanded << 24)) & bit_spread_masks[3];
    expanded = (expanded | (expanded << 12)) & bit_spread_masks[2];
    expanded = (expanded | (expanded << 6)) & bit_spread_masks[1];
    expanded = (expanded | (expanded << 3)) & bit_spread_masks[0];

    for (int index = 0; index < 4; ++index) {
        uint64_t reduction = expanded & reduction_masks[index];
        expanded ^= (reduction >> 9) ^ (reduction >> 10) ^ (reduction >> 12) ^ (reduction >> 13);
    }

    return (gf)(expanded & GFMASK);
}

static inline gf gf_sqmul(gf value, gf multiplier)
{
    const uint64_t reduction_masks[] = {
        0x0000001FF0000000ULL,
        0x000000000FF80000ULL,
        0x000000000007E000ULL,
    };
    uint64_t lhs = value;
    uint64_t rhs = multiplier;
    uint64_t product;

    product = (rhs << 6) * (lhs & (1u << 6));
    lhs ^= (lhs << 7);

    product ^= rhs * (lhs & 0x04001u);
    product ^= (rhs * (lhs & 0x08002u)) << 1;
    product ^= (rhs * (lhs & 0x10004u)) << 2;
    product ^= (rhs * (lhs & 0x20008u)) << 3;
    product ^= (rhs * (lhs & 0x40010u)) << 4;
    product ^= (rhs * (lhs & 0x80020u)) << 5;

    for (int index = 0; index < 3; ++index) {
        uint64_t reduction = product & reduction_masks[index];
        product ^= (reduction >> 9) ^ (reduction >> 10) ^ (reduction >> 12) ^ (reduction >> 13);
    }

    return (gf)(product & GFMASK);
}

static inline gf gf_sq2mul(gf value, gf multiplier)
{
    const uint64_t reduction_masks[] = {
        0x1FF0000000000000ULL,
        0x000FF80000000000ULL,
        0x000007FC00000000ULL,
        0x00000003FE000000ULL,
        0x0000000001FE0000ULL,
        0x000000000001E000ULL,
    };
    uint64_t lhs = value;
    uint64_t rhs = multiplier;
    uint64_t product;

    product = (rhs << 18) * (lhs & (1u << 6));
    lhs ^= (lhs << 21);

    product ^= rhs * (lhs & 0x010000001ULL);
    product ^= (rhs * (lhs & 0x020000002ULL)) << 3;
    product ^= (rhs * (lhs & 0x040000004ULL)) << 6;
    product ^= (rhs * (lhs & 0x080000008ULL)) << 9;
    product ^= (rhs * (lhs & 0x100000010ULL)) << 12;
    product ^= (rhs * (lhs & 0x200000020ULL)) << 15;

    for (int index = 0; index < 6; ++index) {
        uint64_t reduction = product & reduction_masks[index];
        product ^= (reduction >> 9) ^ (reduction >> 10) ^ (reduction >> 12) ^ (reduction >> 13);
    }

    return (gf)(product & GFMASK);
}

gf gf_frac(gf denominator, gf numerator)
{
    gf den_pow_3 = gf_sqmul(denominator, denominator);
    gf den_pow_15 = gf_sq2mul(den_pow_3, den_pow_3);
    gf inverse = gf_sq2(den_pow_15);

    inverse = gf_sq2mul(inverse, den_pow_15);
    inverse = gf_sq2(inverse);
    inverse = gf_sq2mul(inverse, den_pow_15);

    return gf_sqmul(inverse, numerator);
}

gf gf_inv(gf denominator)
{
    return gf_frac(denominator, (gf)1);
}

void GF_mul(gf *out, gf *lhs, gf *rhs)
{
    gf product[SYS_T * 2 - 1] = {0};

    for (int i = 0; i < SYS_T; ++i) {
        for (int j = 0; j < SYS_T; ++j) {
            product[i + j] ^= gf_mul(lhs[i], rhs[j]);
        }
    }

    /* Reduce modulo x^119 + x^8 + 1. */
    for (int i = (SYS_T - 1) * 2; i >= SYS_T; --i) {
        product[i - SYS_T + 8] ^= product[i];
        product[i - SYS_T] ^= product[i];
    }

    for (int i = 0; i < SYS_T; ++i) {
        out[i] = product[i];
    }
}
