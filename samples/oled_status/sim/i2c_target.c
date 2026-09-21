/* SPDX-License-Identifier: Apache-2.0 */
/* Bit-level I2C target. See i2c_target.h. */
#include "i2c_target.h"

#include <stdio.h>
#include <string.h>

void i2c_hist_add(struct i2c_hist *h, uint64_t v)
{
	if (h->n == 0 || v < h->min) {
		h->min = v;
	}
	if (v > h->max) {
		h->max = v;
	}
	h->n++;
	h->sum += v;
	h->bins[v < I2C_TARGET_HIST ? v : I2C_TARGET_HIST - 1]++;
}

void i2c_hist_str(const struct i2c_hist *h, char *buf, int cap)
{
	uint64_t mode = 0;

	if (h->n == 0) {
		snprintf(buf, cap, "n=0");
		return;
	}
	for (uint64_t i = 1; i < I2C_TARGET_HIST; i++) {
		if (h->bins[i] > h->bins[mode]) {
			mode = i;
		}
	}
	snprintf(buf, cap, "n=%llu min=%llu max=%llu mean=%.3f mode=%llu(%u)",
		 (unsigned long long)h->n, (unsigned long long)h->min,
		 (unsigned long long)h->max, (double)h->sum / (double)h->n,
		 (unsigned long long)mode, h->bins[mode]);
}

void i2c_target_init(struct i2c_target *t, struct ssd1306_model *m)
{
	memset(t, 0, sizeof(*t));
	t->model = m;
	t->scl = 1;
	t->sda = 1;
	t->stretch_byte = -1;
}

static void reset_byte(struct i2c_target *t)
{
	t->bits = 0;
	t->shreg = 0;
	t->in_ack_clock = false;
	t->ack_pending = false;
	t->rises_in_byte = 0;
	t->sda_low = false;
}

void i2c_target_eval(struct i2c_target *t, int scl, int sda)
{
	/* START / STOP: SDA moves while SCL stays high */
	if (scl && t->scl && sda != t->sda) {
		if (!sda) {
			ssd1306_model_start(t->model, t->bus_busy);
			t->bus_busy = true;
		} else {
			if (t->bus_busy) {
				ssd1306_model_stop(t->model);
			}
			t->bus_busy = false;
		}
		reset_byte(t);
		t->byte_no = 0;
	}

	if (scl && !t->scl) {                          /* rising edge */
		t->n_rises++;
		t->rises_in_byte++;
		if (t->rises_in_byte >= 2) {
			i2c_hist_add(&t->period_in_byte, t->cyc - t->last_rise);
			i2c_hist_add(&t->low_in_byte, t->cyc - t->last_fall);
		}
		t->last_rise = t->cyc;
		if (t->bus_busy && !t->in_ack_clock && !t->ack_pending) {
			t->shreg = (uint8_t)((t->shreg << 1) | (sda ? 1 : 0));
			if (++t->bits == 8) {
				t->ack = ssd1306_model_byte(t->model, t->shreg);
				t->ack_pending = true;
				t->n_bytes++;
			}
		}
	} else if (!scl && t->scl) {                   /* falling edge */
		i2c_hist_add(&t->high_all, t->cyc - t->last_rise);
		if (t->rises_in_byte >= 1) {
			i2c_hist_add(&t->high_in_byte, t->cyc - t->last_rise);
		}
		t->last_fall = t->cyc;
		if (t->ack_pending) {
			t->ack_pending = false;
			t->in_ack_clock = true;
			t->sda_low = t->ack;
		} else if (t->in_ack_clock) {
			reset_byte(t);
			t->byte_no++;
		} else if (t->byte_no == t->stretch_byte && t->bits == t->stretch_bit &&
			   !t->stretched) {
			t->scl_low = true;
			t->stretch_until = t->cyc + t->stretch_cycles;
			t->stretched = true;
		}
	}

	if (t->scl_low && t->cyc >= t->stretch_until) {
		t->scl_low = false;
	}

	t->scl = scl;
	t->sda = sda;
	t->cyc++;
}
