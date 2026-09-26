/* SPDX-License-Identifier: Apache-2.0 */
/*
 * Does the address on the glass READ BACK as the address the PS resolved?
 *
 *   cc -Wall -Wextra -Werror -o /tmp/aws_url_test samples/boot_info/tests/aws_url_test.c \
 *      -I samples/boot_info/src && /tmp/aws_url_test
 *
 * Needs no Zephyr, no board and no display: src/aws_url.h is deliberately pure so that this
 * exercises THE SAME CODE the guest draws with, not a paraphrase of it.  The claim under test
 * is the one the layout is built on and the one that cannot be checked by looking at a single
 * board: that splitting after the second dot fits EVERY IPv4 into two eight-column rows, and
 * that reassembling the two rows reproduces the input exactly.
 *
 * The sweep is over DIGIT COUNTS, not over addresses.  Whether a split fits depends only on
 * how many digits each octet has, so six representative octets covering one, two and three
 * digits (and the extremes 0 and 255) exhaust the space in 6^4 = 1296 cases; 256^4 would test
 * the same four shapes 4.3 billion times.
 */
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#include "aws_url.h"

#define COLS 8                    /* 128 px / 15 px, the tallest font in the boot_info image */

static int fails;

static void fail(const char *what, const char *in, const char *got)
{
	printf("AUT FAIL %-28s in=\"%s\" got=\"%s\"\n", what, in, got);
	fails++;
}

/* The property that matters: the rows, concatenated with the closing slash removed, ARE the
 * address.  A layout that fits and is unreadable back to the input is not a layout. */
static void check_roundtrip(const char *ip)
{
	char l0[32], l1[32], back[64];
	int n = aws_url_lines(ip, COLS, l0, sizeof(l0), l1, sizeof(l1));
	size_t bl;

	if (n != 1 && n != 2) {
		fail("did not lay out", ip, "");
		return;
	}
	if (strlen(l0) > COLS || strlen(l1) > COLS) {
		fail("row wider than the panel", ip, l0);
		return;
	}
	snprintf(back, sizeof(back), "%s%s", l0, n == 2 ? l1 : "");
	bl = strlen(back);
	if (bl == 0 || back[bl - 1] != '/') {
		fail("no closing slash", ip, back);
		return;
	}
	back[bl - 1] = '\0';
	if (strcmp(back, ip) != 0) {
		fail("rows do not rebuild the address", ip, back);
	}
}

int main(void)
{
	/* 1. a full 14-character address, spelled out.  The literal is RFC 5737 documentation
	 *    space, not a real seat: the layout claim is about DIGIT COUNTS, so any 3-2-3-3 digit
	 *    address exercises the same split, and a real instance address does not belong in a
	 *    public tree.  Board NN's seat is answered by dnsmasq and has this exact shape. */
	{
		char l0[32], l1[32];
		int n = aws_url_lines("198.51.100.197", COLS, l0, sizeof(l0), l1, sizeof(l1));

		if (n != 2 || strcmp(l0, "198.51.") != 0 || strcmp(l1, "100.197/") != 0) {
			printf("AUT FAIL 14-char layout n=%d l0=\"%s\" l1=\"%s\"\n", n, l0, l1);
			fails++;
		} else {
			printf("AUT OK   198.51.100.197 -> \"%s\" / \"%s\"\n", l0, l1);
		}
	}

	/* 2. a short address needs no split, and keeps its slash on the one row */
	{
		char l0[32], l1[32];
		int n = aws_url_lines("1.2.3.4", COLS, l0, sizeof(l0), l1, sizeof(l1));

		if (n != 1 || strcmp(l0, "1.2.3.4/") != 0 || l1[0] != '\0') {
			printf("AUT FAIL short layout n=%d l0=\"%s\" l1=\"%s\"\n", n, l0, l1);
			fails++;
		} else {
			printf("AUT OK   1.2.3.4 -> \"%s\" on one row\n", l0);
		}
	}

	/* 3. the whole IPv4 space, by digit count */
	{
		static const int oct[] = { 0, 7, 10, 99, 100, 255 };
		size_t a, b, c, d, cases = 0;

		for (a = 0; a < sizeof(oct) / sizeof(oct[0]); a++) {
			for (b = 0; b < sizeof(oct) / sizeof(oct[0]); b++) {
				for (c = 0; c < sizeof(oct) / sizeof(oct[0]); c++) {
					for (d = 0; d < sizeof(oct) / sizeof(oct[0]); d++) {
						char ip[16];

						snprintf(ip, sizeof(ip), "%d.%d.%d.%d",
							 oct[a], oct[b], oct[c], oct[d]);
						check_roundtrip(ip);
						cases++;
					}
				}
			}
		}
		printf("AUT OK   %zu addresses laid out and rebuilt at %d columns\n", cases, COLS);
	}

	/* 4. what must NOT be drawn.  The field is either right or visibly absent, so anything
	 *    that is not a dotted quad has to come back 0 and let the caller say so. */
	{
		/* "1.2" is the one this test caught: three characters plus a slash FIT the
		 * eight columns, so a layout-only helper laid it out happily and the glass
		 * would have read "https://1.2/".  Short is not the same as valid, which is
		 * why aws_ip_is_quad() is the first thing aws_url_lines() calls. */
		static const char *bad[] = { "", "1.2", "1.2.3", "127.0.0.1.1.1.1.1",
					     "not-an-ip", "198.51.100.197.extra",
					     "999.1.1.1", "1.2.3.4.", ".1.2.3", "1..2.3",
					     "10.42.0.011" };
		size_t i;
		char l0[32], l1[32];

		for (i = 0; i < sizeof(bad) / sizeof(bad[0]); i++) {
			int n = aws_url_lines(bad[i], COLS, l0, sizeof(l0), l1, sizeof(l1));

			if (n != 0) {
				printf("AUT FAIL bad input laid out in=\"%s\" n=%d l0=\"%s\" "
				       "l1=\"%s\"\n", bad[i], n, l0, l1);
				fails++;
			}
		}
		printf("AUT OK   %zu non-addresses refused\n", sizeof(bad) / sizeof(bad[0]));
	}

	/* 5. a caller that gives no room must be refused, not clipped */
	{
		char l0[32], l1[32];

		if (aws_url_lines("198.51.100.197", 0, l0, sizeof(l0), l1, sizeof(l1)) != 0 ||
		    aws_url_lines("198.51.100.197", 7, l0, sizeof(l0), l1, sizeof(l1)) != 0) {
			printf("AUT FAIL laid out into too few columns\n");
			fails++;
		}
		/* 8 columns is the real budget and must succeed, so the 7 above is a real gate
		 * and not a function that always refuses. */
		if (aws_url_lines("198.51.100.197", 8, l0, sizeof(l0), l1, sizeof(l1)) != 2) {
			printf("AUT FAIL 8 columns refused\n");
			fails++;
		}
		printf("AUT OK   0 and 7 columns refused, 8 accepted\n");
	}

	/* 6. a buffer too small for the row is refused rather than overrun */
	{
		char tiny[4], l1[32];

		if (aws_url_lines("198.51.100.197", COLS, tiny, sizeof(tiny), l1, sizeof(l1)) != 0) {
			printf("AUT FAIL wrote a 7-character row into a 4-byte buffer\n");
			fails++;
		}
		printf("AUT OK   undersized output buffer refused\n");
	}

	/* 7. A ZERO-LENGTH BUFFER MUST NOT BE WRITTEN AT ALL, not even the terminator.  Caught in
	 *    review: the two clearing stores used to run before any size check, so `l0[0] = 0`
	 *    on a zero-length buffer was itself the overrun this function promises not to make.
	 *    Guard bytes either side, so a one-byte write is visible. */
	{
		char buf[4] = { 0x5a, 0x5a, 0x5a, 0x5a };
		char l1[32] = { 0x5a };

		if (aws_url_lines("198.51.100.197", COLS, buf, 0, l1, sizeof(l1)) != 0 ||
		    buf[0] != 0x5a) {
			printf("AUT FAIL wrote into a zero-length l0 (buf[0]=0x%02x)\n",
			       (unsigned char)buf[0]);
			fails++;
		}
		if (aws_url_lines("198.51.100.197", COLS, buf, sizeof(buf), l1, 0) != 0 ||
		    l1[0] != 0x5a) {
			printf("AUT FAIL wrote into a zero-length l1 (l1[0]=0x%02x)\n",
			       (unsigned char)l1[0]);
			fails++;
		}
		printf("AUT OK   zero-length buffers left untouched\n");
	}

	/* 8. A WIDE ENOUGH PANEL WITH A TIGHT l0 MUST STILL SPLIT, not give up.  Also caught in
	 *    review, and unreachable with today's fonts (128/15 = 8 columns): if a font ever gives
	 *    15 or more columns, the one-row branch fits the address but a 16-byte l0 cannot hold
	 *    it with its slash -- and the old code returned 0 there, so a 15-character address
	 *    would have vanished from a panel wide enough to show it split. */
	{
		char l0[16], l1[32], back[64];
		int n = aws_url_lines("255.255.255.255", 16, l0, sizeof(l0), l1, sizeof(l1));

		snprintf(back, sizeof(back), "%s%s", l0, l1);
		if (n != 2 || strcmp(back, "255.255.255.255/") != 0) {
			printf("AUT FAIL wide panel + tight l0: n=%d back=\"%s\"\n", n, back);
			fails++;
		} else {
			printf("AUT OK   cols=16 with a 16-byte l0 splits to \"%s\" / \"%s\"\n",
			       l0, l1);
		}
		/* and with one more byte it takes the single row, which is what proves the
		 * branch above was chosen for the buffer and not by accident */
		{
			char big[17];

			if (aws_url_lines("255.255.255.255", 16, big, sizeof(big),
					  l1, sizeof(l1)) != 1 ||
			    strcmp(big, "255.255.255.255/") != 0) {
				printf("AUT FAIL cols=16 with a 17-byte l0 did not take one row\n");
				fails++;
			}
		}
	}

	printf("AUT DONE fails=%d\n", fails);
	return fails == 0 ? 0 : 1;
}
