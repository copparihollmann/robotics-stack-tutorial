/* SPDX-License-Identifier: Apache-2.0 */
/*
 * A behavioural SSD1306 I2C target: control-byte framing, the command set a 128x64 panel
 * uses, and the 8x128 GDDRAM with page/horizontal/vertical addressing. Plain C99, no Zephyr
 * and no simulator dependencies, so the SAME decoder sits behind
 *
 *   - the Zephyr I2C emulator in the host test      (tests/host/src/ssd1306_emul.c)
 *   - the bit-level I2C target in the TLI2C RTL test (sim/i2c_target.c, Verilator)
 *   - the bit-level I2C target in the SoC TestHarness (sim/i2c_target.c, via DPI)
 *
 * and a framebuffer from any of them can be compared byte for byte.
 *
 * Wire events in, ACK out:
 *   ssd1306_model_start(m, repeated)      START or repeated START (Sr)
 *   ack = ssd1306_model_byte(m, byte)     one byte clocked in by the master (address or not)
 *   ssd1306_model_stop(m)                 STOP
 * Reads (R/W = 1) are NACKed: the SSD1306 has no I2C read path.
 *
 * Datasheet: Solomon Systech SSD1306 rev 1.1, section 8.1.5 (I2C) and section 9 (commands).
 */
#ifndef SSD1306_MODEL_H_
#define SSD1306_MODEL_H_

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define SSD1306_MODEL_W 128
#define SSD1306_MODEL_PAGES 8
#define SSD1306_MODEL_H 64
#define SSD1306_MODEL_LOG_MAX 8192   /* bytes of text wire log kept */
#define SSD1306_MODEL_CMDS_MAX 256   /* command bytes kept, in order */

struct ssd1306_model {
	/* configuration */
	uint8_t addr7;          /* 0x3c */
	bool present;           /* false: NACK everything (module not fitted) */

	/* I2C framing */
	int byte_idx;           /* bytes since the last START; 0 = address byte next */
	bool selected;          /* our address, write direction */
	bool ctrl_next;         /* next byte is a control byte */
	bool stream;            /* Co = 0: the rest of the transfer is one kind */
	bool dc;                /* D/C#: 1 data, 0 command */

	/* command assembly */
	uint8_t cmd[8];
	int cmd_len;
	int cmd_need;

	/* panel state */
	uint8_t ram[SSD1306_MODEL_PAGES][SSD1306_MODEL_W];
	uint8_t mode;           /* 0 horizontal, 1 vertical, 2 page (reset) */
	uint8_t col, col_start, col_end;
	uint8_t page, page_start, page_end;
	bool display_on, charge_pump, inverse, entire_on, seg_remap, com_flip;
	uint8_t contrast, mux, com_pins, clock_div, precharge, vcomh, offset, start_line;

	/* statistics and checks */
	unsigned long n_start, n_restart, n_stop, n_addr_ack, n_addr_nack;
	unsigned long n_cmd_bytes, n_data_bytes, n_unknown_cmds;
	unsigned long n_ctrl_bytes, n_bad_ctrl;   /* control bytes with bits 5..0 != 0 */
	unsigned long n_data_while_off_before_pump; /* data before charge pump enabled */
	bool pump_before_on_violation;            /* AF seen while charge pump off */
	uint8_t cmds[SSD1306_MODEL_CMDS_MAX];     /* every command byte, parameters included */
	size_t n_cmds_kept;

	/* text log of the wire, e.g. "S 78+ 00+ AE+ P\n" ('+' ACK, '-' NACK) */
	char log[SSD1306_MODEL_LOG_MAX];
	size_t log_len;
	bool log_enabled;
};

void ssd1306_model_init(struct ssd1306_model *m, uint8_t addr7, bool present);
void ssd1306_model_start(struct ssd1306_model *m, bool repeated);
bool ssd1306_model_byte(struct ssd1306_model *m, uint8_t byte);
void ssd1306_model_stop(struct ssd1306_model *m);

/* GDDRAM as an image: row y, column x, 1 = pixel on (page 0 on top, column 0 on the left). */
static inline bool ssd1306_model_pixel(const struct ssd1306_model *m, int x, int y)
{
	return (m->ram[y / 8][x] >> (y % 8)) & 1U;
}

/* Binary PGM (P5, 128x64, 0/255) of the GDDRAM into buf; returns bytes written. */
size_t ssd1306_model_pgm(const struct ssd1306_model *m, uint8_t *buf, size_t cap);

#endif /* SSD1306_MODEL_H_ */
