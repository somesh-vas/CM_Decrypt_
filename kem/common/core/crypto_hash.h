/* This file uses a local SHAKE256 shim backed by the XKCP standalone code. */

#include "fips202_shim.h"

#define crypto_hash_32b(out,in,inlen) \
  SHAKE256(out,32,in,inlen)

#define shake(out,outlen,in,inlen) \
  SHAKE256(out,outlen,in,inlen)
