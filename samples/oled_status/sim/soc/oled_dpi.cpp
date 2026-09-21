// SPDX-License-Identifier: Apache-2.0
// DPI side of sim/soc/oled_i2c_target.sv. Dumps the framebuffer, the wire log and the
// timing to $OLED_SIM_OUT (default .) when the simulator exits.
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <csignal>
#include <fstream>
#include <string>

extern "C" {
#include "i2c_target.h"
#include "ssd1306_model.h"

void oled_tgt_init(int addr);
int oled_tgt_eval(int scl_in, int sda_in);
}

static struct ssd1306_model model;
static struct i2c_target tgt;
static bool inited;
static char outdir[512] = ".";   /* not a std::string: this is read from an atexit handler */
static unsigned long data_seen;
static uint64_t first_data_cyc, last_data_cyc, first_byte_cyc, last_stop_cyc;
static unsigned long frames;
static uint64_t frame_start_cyc, frame_cycles_last;

static void oled_tgt_dump(void)
{
	static uint8_t pgm[16 + SSD1306_MODEL_W * SSD1306_MODEL_H];
	size_t n = ssd1306_model_pgm(&model, pgm, sizeof(pgm));
	char stats[1024];

	std::ofstream(std::string(outdir) + "/oled_soc.pgm", std::ios::binary)
		.write(reinterpret_cast<const char *>(pgm), (std::streamsize)n);
	std::ofstream(std::string(outdir) + "/oled_soc_wire.txt") << model.log;
	char per[256], hi[256], lo[256];
	i2c_hist_str(&tgt.period_in_byte, per, sizeof(per));
	i2c_hist_str(&tgt.high_in_byte, hi, sizeof(hi));
	i2c_hist_str(&tgt.low_in_byte, lo, sizeof(lo));
	std::snprintf(stats, sizeof(stats),
		      "{\n \"addr_ack\": %lu, \"addr_nack\": %lu, \"starts\": %lu, \"restarts\": %lu,\n"
		      " \"stops\": %lu, \"cmd_bytes\": %lu, \"data_bytes\": %lu, \"bad_ctrl\": %lu,\n"
		      " \"unknown_cmds\": %lu, \"display_on\": %d, \"charge_pump\": %d, \"mode\": %u,\n"
		      " \"frames\": %lu, \"last_frame_cycles\": %llu,\n"
		      " \"first_data_cycle\": %llu, \"last_data_cycle\": %llu,\n"
		      " \"first_byte_cycle\": %llu, \"last_stop_cycle\": %llu,\n"
		      " \"period_in_byte\": \"%s\",\n \"high_in_byte\": \"%s\",\n \"low_in_byte\": \"%s\"\n}\n",
		      model.n_addr_ack, model.n_addr_nack, model.n_start, model.n_restart,
		      model.n_stop, model.n_cmd_bytes, model.n_data_bytes, model.n_bad_ctrl,
		      model.n_unknown_cmds, model.display_on, model.charge_pump, model.mode,
		      frames, (unsigned long long)frame_cycles_last,
		      (unsigned long long)first_data_cyc, (unsigned long long)last_data_cyc,
		      (unsigned long long)first_byte_cyc, (unsigned long long)last_stop_cyc,
		      per, hi, lo);
	std::ofstream(std::string(outdir) + "/oled_soc_stats.json") << stats;
	std::fprintf(stderr, "OLED_MODEL: addr_nack=%lu %lu data bytes, %lu commands, %lu starts, %lu repeated starts, "
			     "display_on=%d, last frame %llu cycles\n",
		     model.n_addr_nack, model.n_data_bytes, model.n_cmd_bytes, model.n_start, model.n_restart,
		     model.display_on, (unsigned long long)frame_cycles_last);
}

static void oled_tgt_signal(int sig)
{
	oled_tgt_dump();
	std::_Exit(128 + sig);
}

void oled_tgt_init(int addr)
{
	const char *d;

	if (inited) {
		return;
	}
	inited = true;
	d = std::getenv("OLED_SIM_OUT");
	if (d && *d) {
		std::snprintf(outdir, sizeof(outdir), "%s", d);
	}
	/* OLED_SIM_PRESENT=0 makes the model NACK everything: the "module not fitted" case,
	 * which the guest must survive without touching the bus again. */
	d = std::getenv("OLED_SIM_PRESENT");
	bool present = !(d && d[0] == '0');

	ssd1306_model_init(&model, (uint8_t)addr, present);
	i2c_target_init(&tgt, &model);
	std::atexit(oled_tgt_dump);
	/* A simulation that is cut short (timeout, Ctrl-C, a kill) still leaves its evidence. */
	std::signal(SIGTERM, oled_tgt_signal);
	std::signal(SIGINT, oled_tgt_signal);
}

int oled_tgt_eval(int scl_in, int sda_in)
{
	unsigned long before = model.n_data_bytes;
	uint64_t cyc = tgt.cyc;

	/* stderr is unbuffered: this is the only progress visible while the guest boots */
	if ((cyc % 5000000) == 0 && cyc) {
		std::fprintf(stderr, "OLED_MODEL: %llu Mcycle, %lu starts, %lu data bytes\n",
			     (unsigned long long)(cyc / 1000000), model.n_start, model.n_data_bytes);
	}

	i2c_target_eval(&tgt, scl_in, sda_in);
	if (model.n_start && !first_byte_cyc) {
		first_byte_cyc = cyc;
	}
	if (model.n_data_bytes != before) {
		if (!first_data_cyc) {
			first_data_cyc = cyc;
		}
		if (data_seen % 1024 == 0) {
			frame_start_cyc = cyc;
		}
		data_seen++;
		if (data_seen % 1024 == 0) {
			frames++;
			frame_cycles_last = cyc - frame_start_cyc;
			/* Dump after every completed frame, not only at exit: the artefacts are
			 * then there whatever ends the run. */
			oled_tgt_dump();
		}
		last_data_cyc = cyc;
	}
	if (model.n_stop) {
		last_stop_cyc = cyc;
	}
	return (tgt.sda_low ? 2 : 0) | (tgt.scl_low ? 1 : 0);
}
