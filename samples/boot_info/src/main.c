/* SPDX-License-Identifier: Apache-2.0
 *
 * THE BOARD SAYS WHO IT IS, AND KEEPS SAYING IT.
 *
 * Under the WiFi topology an attendee's board has no address they can predict: the dongle is
 * a USB device on the PS, DHCP gives it what it gives it, and nothing on the board tells
 * anyone what happened.  Worse, `TUTORIAL_NETWORKING.md` section 2.2 records the board-side
 * risk of that topology as "association must succeed at boot, headless, in a hostile RF
 * room" -- and that failure is SILENT.  A board that never joined looks exactly like one
 * that did.
 *
 * This turns both into something legible from across a table.  The PS writes what it knows
 * into DRAM before releasing reset (fpga/pynq-z2/sw/boot_status.h; run_rocket.py --status)
 * and this reads it and holds it on the glass.
 *
 * WHY IT LOOPS FOREVER RATHER THAN DRAWING ONCE.  A screen drawn once is a screen that is
 * blank after any glitch, and a blank screen is indistinguishable from a dead board -- which
 * is the confusion this sample exists to remove.  It redraws on a slow cadence, so the panel
 * is proof of life as well as a message.  The uptime counter is what makes that visible: a
 * frozen number means the guest stopped, where a frozen SCREEN could mean anything.
 *
 * AND THE FIRST THING AN ATTENDEE NEEDS IS NOT THIS BOARD'S ADDRESS.  It is their own EC2
 * seat's, because their first action is plugging the board in and at that moment they are not
 * on this network at all -- they reach their instance over their own internet, and the room
 * has no printed cards any more.  The board can answer that itself (10.42.0.NN is seat NN, so
 * the instance is aws-NN.iiswc) but only the PS can resolve it, so it rides the same block and
 * is drawn here, wrapped in the https:// ... / the block has no room to store.  That address
 * is the one field on this screen somebody has to TRANSCRIBE, so it gets the tallest font in
 * the image and the SSID line gives up its rows for it; see the layout note in main().
 *
 * WHAT IT DOES NOT DO.  It never touches the network, because it cannot -- the guest has no
 * route to the dongle.  Everything here is the PS's word, taken on trust but validated
 * (magic + CRC) and stamped with a nonce so a block left over from a PREVIOUS load is
 * rejected rather than displayed.  ABSENT is an honest screen; a stale address is not.
 */
#include <zephyr/kernel.h>
#include <zephyr/sys/printk.h>
#include <zephyr/device.h>
#include <zephyr/drivers/i2c.h>
#include <errno.h>
#include <zephyr/display/cfb.h>
#include <string.h>

#include "oled_status.h"
#include "boot_status.h"
#include "aws_url.h"

#define OLED_W    128         /* SSD1306 0.96": 128 x 64 */
#define OLED_H    64
#define OLED_COLS 25          /* 128 px / 5 px, the 5x8 font */
#define REDRAW_MS 2000

static const struct device *oled;
static uint16_t oled_addr;

static void oled_probe(void)
{
	static const struct { const struct device *disp, *bus; uint16_t addr; } cand[] = {
#if DT_NODE_HAS_STATUS_OKAY(DT_NODELABEL(oled_3c))
		{ DEVICE_DT_GET(DT_NODELABEL(oled_3c)),
		  DEVICE_DT_GET(DT_BUS(DT_NODELABEL(oled_3c))), 0x3c },
#endif
#if DT_NODE_HAS_STATUS_OKAY(DT_NODELABEL(oled_3d))
		{ DEVICE_DT_GET(DT_NODELABEL(oled_3d)),
		  DEVICE_DT_GET(DT_BUS(DT_NODELABEL(oled_3d))), 0x3d },
#endif
	};
	/*
	 * THIS IS samples/cam_snap's PROBE, VERBATIM, AND DELIBERATELY SO.  My first version
	 * differed in three ways and reported ABSENT on a panel that cam_snap had found READY
	 * at 0x3c on this same board minutes earlier:
	 *
	 *   * it gated on device_is_ready(disp).  The SSD1306's boot-time init runs before the
	 *     panel is reachable, so the device is NOT ready and never becomes ready on its
	 *     own -- device_init() has to be called explicitly, and -EALREADY is a pass.
	 *     That one alone was enough to report a working display as absent.
	 *   * it passed a dummy buffer with length 0 instead of NULL for the address probe.
	 *   * it used DT_NODE_EXISTS rather than DT_NODE_HAS_STATUS_OKAY, so a disabled node
	 *     would have been probed.
	 *
	 * And the property that cam_snap's own comment records as MEASURED on both boards on
	 * 2026-09-22: presence is an ADDRESS ACK, not a command ACK.  A two-byte NOP under a
	 * command control byte does NOT complete on this module while a zero-length write to
	 * the same 0x3c does.  Everything after the ack is REPORTED, not used to decide, so
	 * "fitted but init failed" stays distinguishable from "not fitted".
	 */
	for (size_t i = 0; i < ARRAY_SIZE(cand); i++) {
		static const uint8_t nop[2] = { 0x00, 0xE3 };
		int ack, nrc, drc, src;

		if (!device_is_ready(cand[i].bus)) {
			printk("BI_OLED probe addr=0x%02x bus_not_ready=1\n", cand[i].addr);
			continue;
		}
		oled_status_bus_lock();
		ack = i2c_write(cand[i].bus, NULL, 0, cand[i].addr);
		nrc = (ack == 0) ? i2c_write(cand[i].bus, nop, sizeof(nop), cand[i].addr) : -ENODEV;
		drc = (ack == 0) ? device_init(cand[i].disp) : -ENODEV;
		oled_status_bus_unlock();
		/* oled_cfb_setup() calls cfb_framebuffer_init() itself; calling it here too
		 * exhausts the 2 KiB heap on the second 1 KiB buffer and returns -ENOMEM on a
		 * display that just completed its whole init.  One init, in the helper. */
		src = (ack == 0 && (drc == 0 || drc == -EALREADY))
			? oled_cfb_setup(cand[i].disp) : -ENODEV;
		printk("BI_OLED probe addr=0x%02x addr_ack_rc=%d nop_rc=%d init_rc=%d setup_rc=%d\n",
		       cand[i].addr, ack, nrc, drc, src);
		if (ack != 0) { continue; }
		if (src != 0) {
			printk("BI_OLED state=FAILED addr=0x%02x reason=acked_but_init_failed\n",
			       cand[i].addr);
			continue;
		}
		oled = cand[i].disp; oled_addr = cand[i].addr;
		printk("BI_OLED state=READY addr=0x%02x\n", oled_addr);
		return;
	}
	printk("BI_OLED state=ABSENT reason=no_ack_at_0x3c_0x3d\n");
}

/*
 * DRAW EACH LINE IN THE LARGEST FONT IT FITS IN.
 *
 * This screen is read from across a table, so the size is not cosmetic -- an IP address in
 * 5x8 is unreadable at arm's length, which defeats the point of putting it on glass at all.
 * But the strings vary: "10.42.0.13" is ten characters and "iiswc-robotics-tutorial" is
 * twenty-three, and no single font holds both on a 128 px panel.  So the font is chosen per
 * line, by measurement, at run time -- fonts are found by asking CFB their size rather than
 * by hardcoding an index, because the index depends on link order and would silently become
 * the wrong font if another font were ever added.
 *
 * min_h is a floor and max_h a CEILING, and the ceiling is not symmetry for its own sake:
 * `https://` is eight characters, so on width alone the 15x24 font wins it and the scheme
 * label would be drawn as tall as the address it labels -- which is exactly backwards.  A line
 * that is boilerplate says so by being small.
 *
 * Returns the height consumed, so the caller can stack lines without knowing which font won.
 */
static bool screen_log;       /* see main(): one pass of BI_SCREEN lines, on the first draw */

static int draw_fit(int y, const char *text, int min_h, int max_h)
{
	int n = cfb_get_numof_fonts(oled);
	int best = -1, best_h = 0, best_w = 0;
	size_t len = strlen(text);
	int room = OLED_H - y;                             /* what is left BELOW y */

	for (int f = 0; f < n; f++) {
		uint8_t w, h;

		if (cfb_get_font_size(oled, f, &w, &h) != 0) { continue; }
		if (h < min_h || h > max_h) { continue; }
		if (len * w > (size_t)OLED_W) { continue; }   /* would run off the right edge */
		/*
		 * AND OFF THE BOTTOM, which the first version did not check and which is how
		 * the uptime line came out unreadable: "up 0:16" is seven characters, 7 x 15 =
		 * 105 <= 128, so the widest font won on width alone and was drawn 24 px tall at
		 * y = 56 on a 64 px panel.  Eight rows of each glyph survived.  Fitting is two
		 * dimensions; checking one of them looks like it works until a short string
		 * meets the bottom of the screen.
		 */
		if (h > room) { continue; }
		if (h > best_h) { best = f; best_h = h; best_w = w; }
	}
	if (best < 0) {                        /* nothing fits: smallest that is still on-screen */
		for (int f = 0; f < n; f++) {
			uint8_t w, h;

			if (cfb_get_font_size(oled, f, &w, &h) != 0) { continue; }
			if (h > room) { continue; }
			/* max_h is the CALLER's constraint and binds here too -- the loop above
			 * only relaxes min_h.  Width is deliberately not rechecked: this path
			 * accepts a line too wide and lets the truncation below cut it, which is
			 * the whole reason it exists. */
			if (h > max_h) { continue; }
			if (best < 0 || h < best_h) { best = f; best_h = h; best_w = w; }
		}
	}
	if (best < 0) { return 0; }            /* no font short enough: draw nothing, not garbage */
	(void)cfb_framebuffer_set_font(oled, best);
	{
		char b[64];
		size_t cols = best_w ? (size_t)(128 / best_w) : sizeof(b) - 1;

		if (cols > sizeof(b) - 1) { cols = sizeof(b) - 1; }
		strncpy(b, text, cols);
		b[cols] = '\0';
		(void)cfb_print(oled, b, 0, y);
		/* WHAT IS ACTUALLY ON THE GLASS, in the console, once.  There is no camera on
		 * this side of the board -- the OV5640 is on the same board and cannot see its
		 * own OLED -- so without this the only record of a rendered screen is somebody
		 * holding a phone over it.  b is the string AFTER truncation and best_w x best_h
		 * is the font that won, so these lines are the screen, not an intention. */
		if (screen_log) {
			printk("BI_SCREEN y=%2d font=%ux%u text=\"%s\"\n",
			       y, best_w, best_h, b);
		}
	}
	return best_h;
}


/* Columns the TALLEST font in this image gives on this panel.  Asked rather than hardcoded for
 * draw_fit's reason: an index or a width written down here would silently become wrong the day
 * another font is linked, and the address is the one field that must not quietly shrink. */
static size_t tallest_font_cols(void)
{
	int n = cfb_get_numof_fonts(oled);
	uint8_t bw = 0, bh = 0;

	for (int f = 0; f < n; f++) {
		uint8_t w, h;

		if (cfb_get_font_size(oled, f, &w, &h) != 0) { continue; }
		if (h > bh) { bh = h; bw = w; }
	}
	return bw ? (size_t)(OLED_W / bw) : 0;
}

int main(void)
{
	struct mb_boot_status st;
	const struct mb_boot_status *p;
	uint32_t secs = 0;
	char ip[24] = "NO STATUS", ssid[40] = "no --status", link[24] = "";
	/* The seat's own instance, laid out for the glass.  u0/u1 hold at most eight columns
	 * plus the closing slash and a NUL; 16 each is room to spare in either direction. */
	char aws[20] = "", u0[16] = "", u1[16] = "";
	int ulines = 0;

	printk("\nBI_BOOT addr=0x%08lx\n", (unsigned long)MB_BOOT_STATUS_ADDR);
	printk("BI_RAW magic=0x%08x\n", *(const volatile uint32_t *)MB_BOOT_STATUS_ADDR);
	oled_probe();

	p = mb_boot_status_get(&st);
	if (p == NULL) {
		int zeroed = *(const volatile uint32_t *)MB_BOOT_STATUS_ADDR == 0u;

		printk("BI_STATUS state=ABSENT reason=%s\n",
		       zeroed ? "magic_zeroed_by_loader" : "bad_magic_or_crc");
		snprintf(ssid, sizeof(ssid), "%s", zeroed ? "loader: no --status" : "bad magic/CRC");
		printk("BI_AWS state=NONE reason=no_block\n");
	} else {
		printk("BI_STATUS state=PRESENT nonce=0x%08x soc_magic=0x%08X\n",
		       p->nonce, p->soc_magic);
		printk("BI_NET host=%s iface=%s ipv4=%s ssid=%s link_up=%u signal_dbm=%d\n",
		       p->hostname, p->ifname, p->ipv4, p->ssid, p->link_up, p->signal_dbm);
		snprintf(ip, sizeof(ip), "%s", p->ipv4[0] ? p->ipv4 : "NO ADDRESS");
		snprintf(ssid, sizeof(ssid), "%s", p->ssid[0] ? p->ssid : "(wired)");
		/* The ONLY other thing worth the pixels: section 2.2's silent failure, made loud. */
		if (!p->link_up) { snprintf(link, sizeof(link), "%s DOWN", p->ifname); }
		snprintf(aws, sizeof(aws), "%s", p->aws_ipv4);
		if (aws[0]) {
			printk("BI_AWS state=PRESENT ipv4=%s url=%s%s/\n",
			       aws, AWS_URL_SCHEME, aws);
		} else {
			/* The loader ran, and either this board is not on the tutorial network or
			 * nothing answered aws-NN.iiswc.  An EMPTY field is the honest answer and
			 * the loader's own console line says which of the two it was. */
			printk("BI_AWS state=NONE reason=loader_left_it_empty\n");
		}
	}
	printk("BI_DONE\n");

	if (oled == NULL) {
		printk("BI_NOTE no display; the lines above are what the screen would read\n");
		return 0;
	}

	/* Split ONCE, not per redraw: the address cannot change while this guest runs (the PS
	 * writes this block before dropping reset, and a PS write afterwards lands outside the
	 * L2 the Rocket reads through -- see boot_status.h), so laying it out every two seconds
	 * would be two seconds of work to reach the same answer. */
	{
		size_t cols = tallest_font_cols();

		ulines = aws_url_lines(aws, cols, u0, sizeof(u0), u1, sizeof(u1));
		printk("BI_AWS rows=%d cols=%u\n", ulines, (unsigned)cols);
	}

	/*
	 * ================================ THE LAYOUT, AND WHAT GAVE ================================
	 *
	 * 128 x 64 with a 5x8, a 10x16 and a 15x24 font is sixty-four rows to spend, and there is
	 * no arrangement that keeps every field it used to hold AND puts the instance address on
	 * in a font somebody can transcribe.  So something gives, and it is named here rather
	 * than being quietly overlapped.
	 *
	 *   y = 0   5x8    https://              eight rows.  The wrapper is boilerplate, the
	 *                                        same on all thirty-one boards, and the one part
	 *                                        of the URL nobody reads character by character
	 *   y = 8   15x24  100.31.               the digits, in the tallest font in the image
	 *   y = 32  15x24  160.197/
	 *   y = 56  5x8    10.42.0.11 up 3:04    this board's own address, and proof of life
	 *
	 * That is 8 + 24 + 24 + 8 = 64 exactly, with no gaps -- and the gaps are not missed,
	 * because the fonts are a 5x8 pixel-doubled 3x, so a 15x24 cell carries six blank rows
	 * of its own below the ink.  A 15 px font gives eight columns on a 128 px panel and a
	 * dotted quad runs to fifteen characters, which is why the address is split; aws_url.h
	 * has the arithmetic showing that splitting after the second dot fits every IPv4 there is.
	 *
	 * WHAT GAVE: THE SSID LINE, and only while an instance address is on the screen.  It was
	 * there for B167's silent-association failure -- a blank SSID means the board never joined
	 * and TUTORIAL_NETWORKING.md 2.2 says that failure is otherwise invisible.  But an
	 * instance address is a STRICTLY STRONGER witness of the very same thing: aws-NN.iiswc is
	 * answered by dnsmasq on the tutorial router and by nothing else, so a board showing an
	 * address has associated, reached the router, and been found in the phonebook.  When there
	 * is NO address the SSID comes straight back, because then it is the field that tells you
	 * whether association or the phonebook is what failed -- and those send you to opposite
	 * ends of the room.
	 *
	 * The uptime line stays in both layouts.  It is what makes a frozen screen readable as a
	 * dead guest rather than a dead board, and it is also what DATES the address: this block
	 * is written once at load, so a seat relaunched since then leaves a correct-looking,
	 * semantically stale address on the glass that no guard here can catch.  How old the
	 * screen is, is the cheapest thing a human has to go on.  boot_status.h has the rest.
	 */
	screen_log = true;
	for (;;) {
		char up[24], bot[40];
		int y = 0;

		oled_status_bus_lock();
		if (cfb_framebuffer_clear(oled, false) == 0) {
			if (ulines > 0) {
				y += draw_fit(y, AWS_URL_SCHEME, 8, 8);
				y += draw_fit(y, u0, 16, OLED_H);
				if (ulines > 1) { y += draw_fit(y, u1, 16, OLED_H); }
				/* One bottom row for both of the small things.  `link` can only
				 * be set here if the reported interface was forced with
				 * --status-iface, since resolving the seat needs the network at
				 * all -- but if it ever is, DOWN must not be the thing that got
				 * dropped for want of a row. */
				snprintf(bot, sizeof(bot), "%s up %u:%02u",
					 link[0] ? link : ip, secs / 60u, secs % 60u);
				if (OLED_H - 8 >= y) { (void)draw_fit(OLED_H - 8, bot, 8, 8); }
			} else {
				y += draw_fit(y, ip, 16, OLED_H) + 2;   /* biggest that fits */
				if (link[0]) { y += draw_fit(y, link, 16, OLED_H) + 2; }
				/* The SSID gets the SMALL font and only the small font.  With
				 * no ceiling, a SHORT ssid string wins the 15x24 on width alone
				 * -- "(wired)" is seven characters, 7 x 15 = 105 <= 128 -- and a
				 * 24 px SSID row pushes the uptime off a 64 px panel.  A short
				 * string is not a more important string. */
				y += draw_fit(y, ssid, 8, 8) + 2;
				/* SAY SO.  A screen with no URL on it and no reason given reads
				 * as a board that forgot, and the attendee has no next step.
				 *
				 * BUT NOT WHEN THE LINK IS DOWN.  Then the DOWN line above has
				 * already given the reason, this row would be redundant -- and
				 * it would push the total past 64 and cost the UPTIME row, which
				 * is exactly the row you want on a board that is not on the
				 * network: 18 + 18 + 10 + 10 = 56, and `OLED_H - 8 > y` is then
				 * false.  Proof of life beats a second copy of one fact. */
				if (!link[0]) {
					y += draw_fit(y, "no instance addr", 8, 8) + 2;
				}
				/* Whatever vertical space the lines above left, on the last row
				 * that fits.  draw_fit refuses a font taller than the remaining
				 * room, so this can only shrink -- never clip. */
				snprintf(up, sizeof(up), "up %u:%02u", secs / 60u, secs % 60u);
				if (OLED_H - 8 > y) { (void)draw_fit(OLED_H - 8, up, 8, 8); }
			}
			(void)cfb_framebuffer_finalize(oled);
		}
		oled_status_bus_unlock();
		screen_log = false;
		k_msleep(REDRAW_MS);
		secs += REDRAW_MS / 1000u;
	}
	return 0;
}
