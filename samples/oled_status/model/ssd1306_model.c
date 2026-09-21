/* SPDX-License-Identifier: Apache-2.0 */
/* Behavioural SSD1306 I2C target. See ssd1306_model.h. */
#include "ssd1306_model.h"

#include <stdio.h>
#include <string.h>

static void logf_(struct ssd1306_model *m, const char *s)
{
	size_t n = strlen(s);

	if (!m->log_enabled || m->log_len + n + 1 >= sizeof(m->log)) {
		return;
	}
	memcpy(m->log + m->log_len, s, n);
	m->log_len += n;
	m->log[m->log_len] = '\0';
}

void ssd1306_model_init(struct ssd1306_model *m, uint8_t addr7, bool present)
{
	memset(m, 0, sizeof(*m));
	m->addr7 = addr7;
	m->present = present;
	m->log_enabled = true;
	/* reset values, datasheet section 9 */
	m->mode = 2;
	m->col_end = 127;
	m->page_end = 7;
	m->contrast = 0x7f;
	m->mux = 63;
	m->com_pins = 0x12;
	m->clock_div = 0x80;
	m->precharge = 0x22;
	m->vcomh = 0x20;
}

void ssd1306_model_start(struct ssd1306_model *m, bool repeated)
{
	if (repeated) {
		m->n_restart++;
		logf_(m, "Sr ");
	} else {
		m->n_start++;
		logf_(m, "S ");
	}
	m->byte_idx = 0;
	m->selected = false;
	m->cmd_len = 0;
	m->cmd_need = 0;
}

void ssd1306_model_stop(struct ssd1306_model *m)
{
	m->n_stop++;
	logf_(m, "P\n");
	m->byte_idx = 0;
	m->selected = false;
}

/* Number of bytes (command included) a command starting with c takes. */
static int cmd_length(uint8_t c)
{
	switch (c) {
	case 0x20: case 0x81: case 0x8d: case 0xa8: case 0xd3: case 0xd5:
	case 0xd9: case 0xda: case 0xdb: case 0xad: case 0xd8:
		return 2;
	case 0x21: case 0x22: case 0xa3:
		return 3;
	case 0x29: case 0x2a:
		return 6;
	case 0x26: case 0x27:
		return 7;
	default:
		return 1;
	}
}

static void exec_cmd(struct ssd1306_model *m)
{
	const uint8_t *c = m->cmd;
	uint8_t op = c[0];

	if (op <= 0x0f) {                       /* lower column nibble, page mode */
		m->col = (m->col & 0xf0) | op;
	} else if (op <= 0x1f) {                /* higher column nibble, page mode */
		m->col = (m->col & 0x0f) | ((op & 0x0f) << 4);
	} else if (op == 0x20) {
		m->mode = c[1] & 3;
	} else if (op == 0x21) {
		m->col_start = c[1] & 0x7f;
		m->col_end = c[2] & 0x7f;
		m->col = m->col_start;
	} else if (op == 0x22) {
		m->page_start = c[1] & 7;
		m->page_end = c[2] & 7;
		m->page = m->page_start;
	} else if (op >= 0x40 && op <= 0x7f) {
		m->start_line = op & 0x3f;
	} else if (op == 0x81) {
		m->contrast = c[1];
	} else if (op == 0x8d) {
		m->charge_pump = (c[1] & 0x04) != 0;
	} else if (op == 0xa0 || op == 0xa1) {
		m->seg_remap = op & 1;
	} else if (op == 0xa4 || op == 0xa5) {
		m->entire_on = op & 1;
	} else if (op == 0xa6 || op == 0xa7) {
		m->inverse = op & 1;
	} else if (op == 0xa8) {
		m->mux = c[1];
	} else if (op == 0xae || op == 0xaf) {
		m->display_on = op & 1;
		if (m->display_on && !m->charge_pump) {
			m->pump_before_on_violation = true;
		}
	} else if (op >= 0xb0 && op <= 0xb7) {
		m->page = op & 7;
	} else if (op == 0xc0 || op == 0xc8) {
		m->com_flip = (op == 0xc8);
	} else if (op == 0xd3) {
		m->offset = c[1];
	} else if (op == 0xd5) {
		m->clock_div = c[1];
	} else if (op == 0xd9) {
		m->precharge = c[1];
	} else if (op == 0xda) {
		m->com_pins = c[1];
	} else if (op == 0xdb) {
		m->vcomh = c[1];
	} else if (op == 0xe3 || op == 0x26 || op == 0x27 || op == 0x29 || op == 0x2a ||
		   op == 0x2e || op == 0x2f || op == 0xa3 || op == 0xad || op == 0xd8) {
		/* NOP, scrolling, IREF, colour mode: accepted, no framebuffer effect */
	} else {
		m->n_unknown_cmds++;
	}
}

static void write_ram(struct ssd1306_model *m, uint8_t v)
{
	m->ram[m->page & 7][m->col & 0x7f] = v;
	m->n_data_bytes++;
	if (!m->charge_pump) {
		m->n_data_while_off_before_pump++;
	}
	switch (m->mode) {
	case 0: /* horizontal */
		if (m->col >= m->col_end) {
			m->col = m->col_start;
			m->page = (m->page >= m->page_end) ? m->page_start : m->page + 1;
		} else {
			m->col++;
		}
		break;
	case 1: /* vertical */
		if (m->page >= m->page_end) {
			m->page = m->page_start;
			m->col = (m->col >= m->col_end) ? m->col_start : m->col + 1;
		} else {
			m->page++;
		}
		break;
	default: /* page: column wraps to its start, page unchanged */
		m->col = (m->col >= m->col_end) ? m->col_start : m->col + 1;
		break;
	}
}

bool ssd1306_model_byte(struct ssd1306_model *m, uint8_t b)
{
	char t[8];
	bool ack;

	if (m->byte_idx++ == 0) {
		/* address byte */
		ack = m->present && (b >> 1) == m->addr7 && (b & 1) == 0;
		m->selected = ack;
		m->ctrl_next = true;
		m->stream = false;
		if (ack) {
			m->n_addr_ack++;
		} else {
			m->n_addr_nack++;
		}
		snprintf(t, sizeof(t), "%02X%c ", b, ack ? '+' : '-');
		logf_(m, t);
		return ack;
	}
	if (!m->selected) {
		/* not addressed: stay off the bus */
		snprintf(t, sizeof(t), "%02X- ", b);
		logf_(m, t);
		return false;
	}
	snprintf(t, sizeof(t), "%02X+ ", b);
	logf_(m, t);

	if (m->ctrl_next) {
		m->n_ctrl_bytes++;
		if (b & 0x3f) {
			m->n_bad_ctrl++;
		}
		m->stream = (b & 0x80) == 0;
		m->dc = (b & 0x40) != 0;
		m->ctrl_next = false;
		return true;
	}

	if (m->dc) {
		write_ram(m, b);
	} else {
		m->n_cmd_bytes++;
		if (m->n_cmds_kept < SSD1306_MODEL_CMDS_MAX) {
			m->cmds[m->n_cmds_kept++] = b;
		}
		if (m->cmd_need == 0) {
			m->cmd_len = 0;
			m->cmd_need = cmd_length(b);
		}
		if (m->cmd_len < (int)sizeof(m->cmd)) {
			m->cmd[m->cmd_len] = b;
		}
		m->cmd_len++;
		if (m->cmd_len == m->cmd_need) {
			exec_cmd(m);
			m->cmd_need = 0;
			m->cmd_len = 0;
		}
	}
	if (!m->stream) {
		/* Co = 1: exactly one byte, then another control byte */
		m->ctrl_next = true;
	}
	return true;
}

size_t ssd1306_model_pgm(const struct ssd1306_model *m, uint8_t *buf, size_t cap)
{
	int hdr = snprintf((char *)buf, cap, "P5\n%d %d\n255\n", SSD1306_MODEL_W, SSD1306_MODEL_H);
	size_t n = (size_t)hdr;

	if (hdr < 0 || n + SSD1306_MODEL_W * SSD1306_MODEL_H > cap) {
		return 0;
	}
	for (int y = 0; y < SSD1306_MODEL_H; y++) {
		for (int x = 0; x < SSD1306_MODEL_W; x++) {
			buf[n++] = ssd1306_model_pixel(m, x, y) ? 255 : 0;
		}
	}
	return n;
}
