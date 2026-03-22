#include "fips202_shim.h"

/* Use the standalone XKCP implementation so vector generation does not
 * depend on a separately installed libkeccak package.
 */
#define LITTLE_ENDIAN
#define FIPS202_SHAKE256 xkcp_compact_FIPS202_SHAKE256
#include "../../../third_party/XKCP/Standalone/CompactFIPS202/C/Keccak-readable-and-compact.c"
#undef FIPS202_SHAKE256

void SHAKE256(unsigned char *output,
              size_t outputByteLen,
              const unsigned char *input,
              unsigned long long inputByteLen)
{
    xkcp_compact_FIPS202_SHAKE256(input, (unsigned int)inputByteLen, output, (int)outputByteLen);
}
