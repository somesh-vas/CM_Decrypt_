#ifndef FIPS202_SHIM_H
#define FIPS202_SHIM_H

#include <stddef.h>

void SHAKE256(unsigned char *output,
              size_t outputByteLen,
              const unsigned char *input,
              unsigned long long inputByteLen);

#endif
