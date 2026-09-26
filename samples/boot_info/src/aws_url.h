/* SPDX-License-Identifier: Apache-2.0 */
/*
 * THE URL, SPLIT SO THE DIGITS GET THE TALLEST FONT THERE IS.
 *
 * The boot status block carries the attendee's seat as a bare IPv4 -- twenty bytes of
 * `reserved` is what there was, and "https://198.51.100.197/" is twenty-four (see
 * fpga/pynq-z2/sw/boot_status.h).  So the wrapper is drawn here, and that turns out to be
 * the better place for it anyway, because the wrapper and the digits do not deserve the same
 * font.  `https://` is identical on every board in the room and nobody has to read it
 * character by character; the digits are the one thing on this screen an attendee must
 * TRANSCRIBE, and a misread digit sends them to a stranger's instance or to nowhere.
 *
 * On a 128 px panel the tallest font in this image is 15x24, which gives EIGHT columns.  A
 * dotted quad is up to fifteen characters, so the whole address never fits on one such row --
 * and that is not a reason to drop to the next font down.  SPLIT AFTER THE SECOND DOT AND IT
 * ALWAYS FITS, for every address there is: each half is then an octet pair, at most
 * "255.255." and "255.255" -- eight characters and seven, and the second half has room for
 * the closing slash.  That is not an empirical observation about the addresses we happen to
 * have; it is arithmetic over the whole IPv4 space.
 *
 * The dot LEFT HANGING at the end of the top row is the continuation cue, which is why the
 * split keeps it there rather than moving it down: a row ending in a dot is visibly unfinished
 * in a way a row ending in a digit is not.
 *
 * Pure, header-only and free of Zephyr, so the host test (tests/aws_url_test.c) can compile
 * the same code the glass runs rather than a paraphrase of it.
 */
#ifndef AWS_URL_H_
#define AWS_URL_H_

#include <stddef.h>
#include <string.h>

/*
 * IS THIS A DOTTED QUAD AT ALL?  The field arrives CRC-checked, from a loader that already
 * refuses anything but a dotted quad -- and it is still checked again here, for the reason
 * boot_status.h gives where it NUL-bounds every string it has just validated: a CRC-valid
 * block is still a block whose producer might be a future version with different habits.
 * This is the last gate before the glass, so it is the one that has to hold.  Four groups of
 * one to three digits, each 0..255, single dots, fifteen characters at the most -- and NO
 * LEADING ZERO on a multi-digit group, which inet_pton refuses for the same reason this does:
 * "0.011" is read as eleven by one resolver and as nine by another, and an address a reader
 * cannot type unambiguously is not worth putting on glass.
 */
static inline int aws_ip_is_quad(const char *ip)
{
	int groups = 0;

	if (ip == NULL || strlen(ip) > 15) {
		return 0;
	}
	for (;;) {
		int digits = 0, val = 0;
		char first = *ip;

		while (*ip >= '0' && *ip <= '9') {
			val = val * 10 + (*ip - '0');
			ip++;
			if (++digits > 3) {
				return 0;
			}
		}
		if (digits == 0 || val > 255 || (digits > 1 && first == '0')) {
			return 0;
		}
		groups++;
		if (*ip == '\0') {
			break;
		}
		if (*ip != '.') {
			return 0;
		}
		ip++;
	}
	return groups == 4;
}

/* Drawn small, on its own row, above the digits.  The closing '/' goes on the LAST digit row
 * instead: a scheme with nothing after it reads as a label, where a stray slash on its own
 * row reads as part of the address. */
#define AWS_URL_SCHEME "https://"

/*
 * Lay `ip` out for a font that gives `cols` columns, wrapping it in AWS_URL_SCHEME's trailing
 * slash.  Writes l0 (and l1) NUL-terminated.
 *
 * Returns 1 if the whole thing fits on one row, 2 if it was split after the second dot, and
 * 0 if it cannot be laid out at `cols` at all -- in which case the caller must fall back to a
 * smaller font rather than draw a clipped address.  Zero is the answer for an empty field and
 * for anything that is not a dotted quad: this is the last gate before the glass, and the
 * whole point of the field is that it is either right or visibly absent.
 */
static inline int aws_url_lines(const char *ip, size_t cols,
				char *l0, size_t l0sz, char *l1, size_t l1sz)
{
	const char *dot;
	size_t n, top;

	/* The size checks come BEFORE the two clearing stores, not after: l0sz == 0 would make
	 * `l0[0] = '\0'` itself the out-of-bounds write this function promises not to make.
	 * Two bytes is the smallest row anything below writes, one byte is all l1 needs to be
	 * emptied. */
	if (ip == NULL || l0 == NULL || l1 == NULL || l0sz < 2 || l1sz < 1) {
		return 0;
	}
	l0[0] = '\0';
	l1[0] = '\0';
	if (!aws_ip_is_quad(ip) || cols < 2) {
		return 0;
	}
	n = strlen(ip);
	/* One row, slash included -- attempted only if l0 can hold it.  A caller whose l0 is too
	 * SHORT for the whole address is not out of options, because the split below needs less
	 * room in l0 than this branch does, so this FALLS THROUGH rather than refusing.  Refusing
	 * here would make a long address vanish from a panel that could have held it in two rows,
	 * and an address that quietly disappears is exactly what this file exists to prevent. */
	if (n + 1 <= cols && n + 2 <= l0sz) {
		memcpy(l0, ip, n);
		l0[n] = '/';
		l0[n + 1] = '\0';
		return 1;
	}
	/* Two rows, split AFTER the second dot -- the dot stays on the top row. */
	dot = strchr(ip, '.');
	if (dot != NULL) {
		dot = strchr(dot + 1, '.');
	}
	if (dot == NULL) {
		return 0;
	}
	top = (size_t)(dot - ip) + 1;                     /* the dot belongs to the top row */
	if (top > cols || (n - top) + 1 > cols) {
		return 0;
	}
	if (top + 1 > l0sz || (n - top) + 2 > l1sz) {
		return 0;
	}
	memcpy(l0, ip, top);
	l0[top] = '\0';
	memcpy(l1, ip + top, n - top);
	l1[n - top] = '/';
	l1[n - top + 1] = '\0';
	return 2;
}

#endif /* AWS_URL_H_ */
