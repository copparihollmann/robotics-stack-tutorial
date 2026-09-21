/* SPDX-License-Identifier: Apache-2.0
 *
 * The smallest HTIF console that spike accepts, plus the freestanding string/memory
 * routines the generated code can ask the compiler for.
 *
 * HTIF: spike locates `tohost` and `fromhost` by symbol name in the ELF (link.ld places
 * them, 8-byte aligned, in their own section) and polls tohost.  Device 1 command 1 is
 * "write this byte to the console"; device 0 command 0 with bit 0 set is "exit with
 * (payload >> 1)".  Same protocol riscv-tests uses.
 *
 * NOTE ON memcpy/memset.  GCC turns a byte-copy loop into a libcall whenever it thinks
 * the library version will be faster, and there is no library here.  These are provided
 * so the link succeeds, and they are BYTE-AT-A-TIME on purpose: the kernels under
 * measurement must not be credited with a word-wide copy the build does not actually
 * guarantee they get.  If either shows up hot in a measurement, that is a real cost of
 * the kernel, reported rather than optimised away behind the measurement's back.
 * (Measured: neither appears in the pext build at all -- the gather and repack loops
 * are too short and too strided for GCC to call out to them.)
 */

#include <stdint.h>
#include <stddef.h>

volatile uint64_t tohost __attribute__((section(".htif")));
volatile uint64_t fromhost __attribute__((section(".htif")));

static void htif_send(uint64_t dev, uint64_t cmd, uint64_t payload)
{
    while (tohost != 0) {
        fromhost = 0;
    }
    tohost = (dev << 56) | (cmd << 48) | (payload & 0xffffffffffffULL);
    while (tohost != 0) {
        fromhost = 0;
    }
}

void htif_putchar(char c)
{
    htif_send(1, 1, (uint64_t)(uint8_t)c);
}

void htif_puts(const char *s)
{
    while (*s) {
        htif_putchar(*s++);
    }
}

void htif_putu(uint64_t v)
{
    char buf[21];
    int i = 0;

    if (v == 0) {
        htif_putchar('0');
        return;
    }
    while (v) {
        buf[i++] = (char)('0' + (int)(v % 10));
        v /= 10;
    }
    while (i) {
        htif_putchar(buf[--i]);
    }
}

void htif_exit(int code)
{
    while (1) {
        tohost = ((uint64_t)code << 1) | 1u;
    }
}

void htif_exit_ok(void)
{
    htif_exit(0);
}

void *memcpy(void *d, const void *s, size_t n)
{
    unsigned char *dd = d;
    const unsigned char *ss = s;

    while (n--) {
        *dd++ = *ss++;
    }
    return d;
}

void *memset(void *d, int c, size_t n)
{
    unsigned char *dd = d;

    while (n--) {
        *dd++ = (unsigned char)c;
    }
    return d;
}

int memcmp(const void *a, const void *b, size_t n)
{
    const unsigned char *x = a, *y = b;

    while (n--) {
        if (*x != *y) return (int)*x - (int)*y;
        x++; y++;
    }
    return 0;
}

size_t strlen(const char *s)
{
    const char *p = s;

    while (*p) p++;
    return (size_t)(p - s);
}
