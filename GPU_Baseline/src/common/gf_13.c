/*
 * Host-side finite-field helpers shared by the 13-bit GPU baseline families.
 * These routines are used while decoding the secret key and preparing the
 * support/inverse tables uploaded to the device.
 */
#include "gf.h"

gf bitrev(gf a)
{
	a = ((a & 0x00FF) << 8) | ((a & 0xFF00) >> 8);
	a = ((a & 0x0F0F) << 4) | ((a & 0xF0F0) >> 4);
	a = ((a & 0x3333) << 2) | ((a & 0xCCCC) >> 2);
	a = ((a & 0x5555) << 1) | ((a & 0xAAAA) >> 1);
	
	return a >> 3;
}
uint16_t load_gf(const unsigned char *src)
{	
	uint16_t a;

	a = src[1]; 
	a <<= 8;
	a |= src[0]; 

	return a & GFMASK;
}

void store_gf(unsigned char *dest, gf a)
{
	dest[0] = a & 0xFF;
	dest[1] = a >> 8;
}

uint32_t load4(const unsigned char * in)
{
	int i;
	uint32_t ret = in[3];

	for (i = 2; i >= 0; i--)
	{
		ret <<= 8;
		ret |= in[i];
	}

	return ret;
}
void store8(unsigned char *out, uint64_t in)
{
	out[0] = (in >> 0x00) & 0xFF;
	out[1] = (in >> 0x08) & 0xFF;
	out[2] = (in >> 0x10) & 0xFF;
	out[3] = (in >> 0x18) & 0xFF;
	out[4] = (in >> 0x20) & 0xFF;
	out[5] = (in >> 0x28) & 0xFF;
	out[6] = (in >> 0x30) & 0xFF;
	out[7] = (in >> 0x38) & 0xFF;
}
uint64_t load8(const unsigned char * in)
{
	int i;
	uint64_t ret = in[7];
	
	for (i = 6; i >= 0; i--)
	{
		ret <<= 8;
		ret |= in[i];
	}
	/*	Initially, ret is set to the last byte (in[7]), which is 0x08.
		In the loop, the code shifts ret left by 8 bits in each iteration 
		and then performs a bitwise OR with the current byte (in[i]). 
		This process effectively combines the bytes to form the 64-bit integer.
	*/
	return ret;
}

//******************** endof util.c methods
//******************** gf.c methods
gf gf_iszero(gf a)
{
	uint32_t t = a;

	t -= 1;
	t >>= 19;

	return (gf) t;
}
gf gf_add(gf in0, gf in1)
{
	return in0 ^ in1;
}
gf gf_mul(gf in0, gf in1)
{
	int i;

	uint64_t tmp;
	uint64_t t0;
	uint64_t t1;
	uint64_t t;

	t0 = in0;
	t1 = in1;

	tmp = t0 * (t1 & 1);

	for (i = 1; i < GFBITS; i++)
		tmp ^= (t0 * (t1 & (1 << i)));

	//

	t = tmp & 0x1FF0000;
	tmp ^= (t >> 9) ^ (t >> 10) ^ (t >> 12) ^ (t >> 13);

	t = tmp & 0x000E000;
	tmp ^= (t >> 9) ^ (t >> 10) ^ (t >> 12) ^ (t >> 13);

	return tmp & GFMASK;
}
/* input: field element in */
/* return: in^2 */
static inline gf gf_sq(gf in)
{
	const uint32_t B[] = {0x55555555, 0x33333333, 0x0F0F0F0F, 0x00FF00FF};

	uint32_t x = in; 
	uint32_t t;

	x = (x | (x << 8)) & B[3];
	x = (x | (x << 4)) & B[2];
	x = (x | (x << 2)) & B[1];
	x = (x | (x << 1)) & B[0];

	t = x & 0x7FC000;
	x ^= t >> 9;
	x ^= t >> 12;

	t = x & 0x3000;
	x ^= t >> 9;
	x ^= t >> 12;

	return x & ((1 << GFBITS)-1);
}
gf gf_inv(gf den)
{
	return gf_frac(den, ((gf) 1));
}/* input: field element den, num */
/* return: (num/den) */
/* input: field element in */
/* return: (in^2)^2 */
static inline gf gf_sq2(gf in)
{
	int i;

	const uint64_t B[] = {0x1111111111111111, 
	                      0x0303030303030303, 
	                      0x000F000F000F000F, 
	                      0x000000FF000000FF};

	const uint64_t M[] = {0x0001FF0000000000, 
	                      0x000000FF80000000, 
	                      0x000000007FC00000, 
	                      0x00000000003FE000};

	uint64_t x = in; 
	uint64_t t;

	x = (x | (x << 24)) & B[3];
	x = (x | (x << 12)) & B[2];
	x = (x | (x << 6)) & B[1];
	x = (x | (x << 3)) & B[0];

	for (i = 0; i < 4; i++)
	{
		t = x & M[i];
		x ^= (t >> 9) ^ (t >> 10) ^ (t >> 12) ^ (t >> 13);
	}

	return x & GFMASK;
}

/* input: field element in, m */
/* return: (in^2)*m */
static inline gf gf_sqmul(gf in, gf m)
{
	int i;

	uint64_t x;
	uint64_t t0;
	uint64_t t1;
	uint64_t t;

	const uint64_t M[] = {0x0000001FF0000000,
	                      0x000000000FF80000, 
	                      0x000000000007E000}; 

	t0 = in;
	t1 = m;

	x = (t1 << 6) * (t0 & (1 << 6));
	
	t0 ^= (t0 << 7);

	x ^= (t1 * (t0 & (0x04001)));
	x ^= (t1 * (t0 & (0x08002))) << 1;
	x ^= (t1 * (t0 & (0x10004))) << 2;
	x ^= (t1 * (t0 & (0x20008))) << 3;
	x ^= (t1 * (t0 & (0x40010))) << 4;
	x ^= (t1 * (t0 & (0x80020))) << 5;

	for (i = 0; i < 3; i++)
	{
		t = x & M[i];
		x ^= (t >> 9) ^ (t >> 10) ^ (t >> 12) ^ (t >> 13);
	}

	return x & GFMASK;
}

/* input: field element in, m */
/* return: ((in^2)^2)*m */
static inline gf gf_sq2mul(gf in, gf m)
{
	int i;

	uint64_t x;
	uint64_t t0;
	uint64_t t1;
	uint64_t t;

	const uint64_t M[] = {0x1FF0000000000000,
		              0x000FF80000000000, 
		              0x000007FC00000000, 
	                      0x00000003FE000000, 
	                      0x0000000001FE0000,
	                      0x000000000001E000};

	t0 = in;
	t1 = m;

	x = (t1 << 18) * (t0 & (1 << 6));

	t0 ^= (t0 << 21);

	x ^= (t1 * (t0 & (0x010000001)));
	x ^= (t1 * (t0 & (0x020000002))) << 3;
	x ^= (t1 * (t0 & (0x040000004))) << 6;
	x ^= (t1 * (t0 & (0x080000008))) << 9;
	x ^= (t1 * (t0 & (0x100000010))) << 12;
	x ^= (t1 * (t0 & (0x200000020))) << 15;

	for (i = 0; i < 6; i++)
	{
		t = x & M[i];
		x ^= (t >> 9) ^ (t >> 10) ^ (t >> 12) ^ (t >> 13);
	}

	return x & GFMASK;
}

/* input: field element den, num */
/* return: (num/den) */
gf gf_frac(gf den, gf num)
{
	gf tmp_11;
	gf tmp_1111;
	gf out;

	tmp_11 = gf_sqmul(den, den); // ^11
	tmp_1111 = gf_sq2mul(tmp_11, tmp_11); // ^1111
	out = gf_sq2(tmp_1111); 
	out = gf_sq2mul(out, tmp_1111); // ^11111111
	out = gf_sq2(out);
	out = gf_sq2mul(out, tmp_1111); // ^111111111111

	return gf_sqmul(out, num); // ^1111111111110 = ^-1
}

// returns the "pre-inverse" value that gf_frac() uses before final gf_sqmul()
// so that: gf_sqmul(pre, num) = (pre^2)*num = num/den
 gf gf_preinv_for_table(gf den)
{
    gf tmp_11;
    gf tmp_1111;
    gf out;

    // same chain you pasted (den is the input)
    tmp_11   = gf_sqmul(den, den);          // ^11
    tmp_1111 = gf_sq2mul(tmp_11, tmp_11);   // ^1111
    out      = gf_sq2(tmp_1111);
    out      = gf_sq2mul(out, tmp_1111);    // ^11111111
    out      = gf_sq2(out);
    out      = gf_sq2mul(out, tmp_1111);    // ^111111111111

    return out;  // <-- store THIS in the lookup table
}
