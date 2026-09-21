// SPDX-License-Identifier: Apache-2.0
//
// Standalone RTL test of the generated TLI2C, driven by Zephyr's UNMODIFIED i2c_sifive.c.
//
//   verilated TLI2C.sv (copied from a Chipyard elaboration, never edited)
//     <- TileLink-UL register reads/writes, one per sys_read8()/sys_write8() of the driver
//     -> scl_oe / sda_oe, resolved with the target's drives as a wired-AND with pull-ups
//     -> sim/i2c_target.c (bit level) -> model/ssd1306_model.c (SSD1306 protocol, GDDRAM)
//
// It settles, on the real RTL and the real driver, the two hypotheses of
// fpga/pynq-z2/docs/OLED_SSD1306.md section 6 that do not need a CPU:
//   P1  SCL timing against prescale (within-byte period, t_HIGH, t_LOW)
//   P2  what i2c_burst_write() puts on the wire
// plus the no-ACK path, clock stretching and a wedged SCL. Results go to --out as
// results.json, one PGM per framebuffer and one wire log per phase.
//
// The pad model is zero-delay: scl_in = !scl_oe && !target_holds_scl. On the board, any
// cycle of delay between the pad and scl_in (a synchroniser) adds to t_LOW (P1).
#include <csetjmp>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#include "VTLI2C.h"
#include "verilated.h"

extern "C" {
#include "i2c_target.h"
#include "ssd1306_model.h"
int glue_init(uint32_t base, uint32_t f_bus);
int glue_i2c_write(const uint8_t *buf, uint32_t len, uint16_t addr);
int glue_i2c_burst_write(uint16_t addr, uint8_t start_addr, const uint8_t *buf, uint32_t num);
void glue_set_log(int on);
}

static const uint32_t BASE = 0x10040000;
static VTLI2C *top;
static uint64_t cyc;
static struct ssd1306_model model;
static struct i2c_target tgt;
static uint64_t mmio_extra_cycles = 8; // CPU cost per MMIO access, beyond the TL handshake
static uint64_t mmio_ops;
static uint64_t budget_end = UINT64_MAX;
static std::jmp_buf budget_jmp;
static bool hold_scl_forever;

static void tick()
{
	int scl = !top->auto_io_out_scl_oe && !tgt.scl_low && !hold_scl_forever;
	int sda = !top->auto_io_out_sda_oe && !tgt.sda_low;

	top->auto_io_out_scl_in = scl;
	top->auto_io_out_sda_in = sda;
	top->clock = 0;
	top->eval();
	i2c_target_eval(&tgt, scl, sda);
	top->clock = 1;
	top->eval();
	cyc++;
	if (cyc >= budget_end) {
		std::longjmp(budget_jmp, 1);
	}
}

static uint64_t tl_op(bool read, uint32_t off, uint8_t wbyte)
{
	uint8_t lane = off & 7;
	bool a_done = false, d_done = false;
	uint64_t rdata = 0;

	for (uint64_t i = 0; i < mmio_extra_cycles; i++) {
		tick();
	}
	for (int guard = 0; !d_done; guard++) {
		if (guard > 100000) {
			fprintf(stderr, "TL op at 0x%x never completed\n", off);
			exit(2);
		}
		top->auto_control_xing_in_a_valid = !a_done;
		top->auto_control_xing_in_a_bits_opcode = read ? 4 : 0;
		top->auto_control_xing_in_a_bits_param = 0;
		top->auto_control_xing_in_a_bits_size = 0;
		top->auto_control_xing_in_a_bits_source = 0;
		top->auto_control_xing_in_a_bits_address = BASE + off; /* absolute: the monitor checks the device range */
		top->auto_control_xing_in_a_bits_mask = (uint8_t)(1U << lane);
		top->auto_control_xing_in_a_bits_data = read ? 0 : ((uint64_t)wbyte << (8 * lane));
		top->auto_control_xing_in_a_bits_corrupt = 0;
		top->auto_control_xing_in_d_ready = 1;
		top->clock = 0;
		top->eval();
		bool a_fire = !a_done && top->auto_control_xing_in_a_ready;
		bool d_fire = top->auto_control_xing_in_d_valid;
		if (d_fire) {
			rdata = top->auto_control_xing_in_d_bits_data;
		}
		tick();
		a_done |= a_fire;
		d_done |= d_fire;
	}
	top->auto_control_xing_in_a_valid = 0;
	mmio_ops++;
	return (rdata >> (8 * lane)) & 0xff;
}

extern "C" uint8_t sys_read8(uintptr_t addr)
{
	return (uint8_t)tl_op(true, (uint32_t)(addr - BASE), 0);
}

extern "C" void sys_write8(uint8_t data, uintptr_t addr)
{
	tl_op(false, (uint32_t)(addr - BASE), data);
}

// ---------------------------------------------------------------------------------------

static std::string outdir;
static std::FILE *json;
static bool first_json = true;

static void jkv(const char *fmt, ...)
{
	va_list ap;
	std::fprintf(json, "%s\n  ", first_json ? "" : ",");
	first_json = false;
	va_start(ap, fmt);
	std::vfprintf(json, fmt, ap);
	va_end(ap);
}

static void hist_json(const char *name, const struct i2c_hist *h)
{
	std::string bins;
	char b[64];

	for (int i = 0; i < I2C_TARGET_HIST; i++) {
		if (h->bins[i]) {
			std::snprintf(b, sizeof(b), "%s\"%d\": %u", bins.empty() ? "" : ", ", i, h->bins[i]);
			bins += b;
		}
	}
	jkv("\"%s\": {\"n\": %llu, \"min\": %llu, \"max\": %llu, \"mean\": %.4f, \"bins\": {%s}}",
	    name, (unsigned long long)h->n, (unsigned long long)h->min, (unsigned long long)h->max,
	    h->n ? (double)h->sum / (double)h->n : 0.0, bins.c_str());
}

static void fresh_model(bool present = true)
{
	int scl = tgt.scl, sda = tgt.sda;

	ssd1306_model_init(&model, 0x3c, present);
	i2c_target_init(&tgt, &model);
	tgt.scl = scl;
	tgt.sda = sda;
}

static void hw_reset()
{
	hold_scl_forever = false;
	tgt.scl_low = false;
	tgt.sda_low = false;
	top->auto_control_xing_in_a_valid = 0;
	top->reset = 1;
	for (int i = 0; i < 20; i++) {
		tick();
	}
	top->reset = 0;
	tick();
}

static void save_model(const std::string &phase)
{
	static uint8_t pgm[16 + 128 * 64];
	size_t n = ssd1306_model_pgm(&model, pgm, sizeof(pgm));
	std::ofstream(outdir + "/" + phase + ".pgm", std::ios::binary)
		.write(reinterpret_cast<const char *>(pgm), (std::streamsize)n);
	std::ofstream(outdir + "/wire_" + phase + ".txt") << model.log;
}

static void phase_json(const std::string &phase, uint64_t c0, int rc_sum)
{
	char s[512];

	jkv("\"%s\": {\"cycles\": %llu, \"rc_sum\": %d, \"starts\": %lu, \"restarts\": %lu, "
	    "\"stops\": %lu, \"addr_ack\": %lu, \"addr_nack\": %lu, \"ctrl_bytes\": %lu, "
	    "\"bad_ctrl\": %lu, \"cmd_bytes\": %lu, \"data_bytes\": %lu, \"unknown_cmds\": %lu, "
	    "\"display_on\": %d, \"charge_pump\": %d, \"mode\": %u, \"bytes_on_wire\": %llu}",
	    phase.c_str(), (unsigned long long)(cyc - c0), rc_sum, model.n_start,
	    model.n_restart, model.n_stop, model.n_addr_ack, model.n_addr_nack,
	    model.n_ctrl_bytes, model.n_bad_ctrl, model.n_cmd_bytes, model.n_data_bytes,
	    model.n_unknown_cmds, model.display_on, model.charge_pump, model.mode,
	    (unsigned long long)tgt.n_bytes);
	hist_json((phase + "_period_in_byte").c_str(), &tgt.period_in_byte);
	hist_json((phase + "_high_in_byte").c_str(), &tgt.high_in_byte);
	hist_json((phase + "_low_in_byte").c_str(), &tgt.low_in_byte);
	i2c_hist_str(&tgt.period_in_byte, s, sizeof(s));
	std::printf("RESULT %-14s rc_sum=%d starts=%lu restarts=%lu stops=%lu data=%lu bad_ctrl=%lu cycles=%llu period_in_byte: %s\n",
		    phase.c_str(), rc_sum, model.n_start, model.n_restart, model.n_stop,
		    model.n_data_bytes, model.n_bad_ctrl, (unsigned long long)(cyc - c0), s);
	save_model(phase);
}

// One screen, as ssd1306.c + CFB issue it: the probe, the init bursts (from the host
// test's golden wire log), the window burst and the 1,024-byte GDDRAM burst.
struct burst {
	uint8_t ctrl;
	std::vector<uint8_t> bytes;
};
static std::vector<burst> init_bursts;
static std::vector<uint8_t> gddram;

static int send(const burst &b, bool as_burst_write)
{
	if (as_burst_write) {
		return glue_i2c_burst_write(0x3c, b.ctrl, b.bytes.data(), (uint32_t)b.bytes.size());
	}
	std::vector<uint8_t> one(1, b.ctrl);
	one.insert(one.end(), b.bytes.begin(), b.bytes.end());
	return glue_i2c_write(one.data(), (uint32_t)one.size(), 0x3c);
}

static int screen(bool as_burst_write, uint64_t *data_cycles)
{
	static const uint8_t nop[] = {0x00, 0xe3};
	int rc = glue_i2c_write(nop, 2, 0x3c) ? 1 : 0;

	for (const burst &b : init_bursts) {
		rc += send(b, as_burst_write) ? 1 : 0;
	}
	uint64_t c0 = cyc;
	rc += send({0x00, {0x20, 0x00, 0x21, 0x00, 0x7f, 0x22, 0x00, 0x07}}, as_burst_write) ? 1 : 0;
	rc += send({0x40, gddram}, as_burst_write) ? 1 : 0;
	*data_cycles = cyc - c0;
	return rc;
}

static void load_inputs(const std::string &bursts_path, const std::string &pgm_path)
{
	std::ifstream f(bursts_path);
	std::string line;

	while (std::getline(f, line)) {
		std::istringstream ss(line);
		unsigned v;
		burst b;
		if (!(ss >> std::hex >> v)) {
			continue;
		}
		b.ctrl = (uint8_t)v;
		while (ss >> std::hex >> v) {
			b.bytes.push_back((uint8_t)v);
		}
		init_bursts.push_back(b);
	}
	std::ifstream p(pgm_path, std::ios::binary);
	std::string hdr1, dims, maxv;
	std::getline(p, hdr1);
	std::getline(p, dims);
	std::getline(p, maxv);
	std::vector<uint8_t> px(128 * 64);
	p.read(reinterpret_cast<char *>(px.data()), (std::streamsize)px.size());
	if (hdr1 != "P5" || !p) {
		fprintf(stderr, "bad golden PGM %s\n", pgm_path.c_str());
		exit(2);
	}
	gddram.assign(1024, 0);
	for (int page = 0; page < 8; page++) {
		for (int x = 0; x < 128; x++) {
			for (int y = 0; y < 8; y++) {
				if (px[(page * 8 + y) * 128 + x]) {
					gddram[page * 128 + x] |= (uint8_t)(1U << y);
				}
			}
		}
	}
}

int main(int argc, char **argv)
{
	std::string bursts_path, pgm_path;

	for (int i = 1; i < argc; i++) {
		std::string a = argv[i];
		if (a == "--out" && i + 1 < argc) {
			outdir = argv[++i];
		} else if (a == "--init-bursts" && i + 1 < argc) {
			bursts_path = argv[++i];
		} else if (a == "--golden-pgm" && i + 1 < argc) {
			pgm_path = argv[++i];
		} else if (a == "--mmio-cycles" && i + 1 < argc) {
			mmio_extra_cycles = std::strtoull(argv[++i], nullptr, 0);
		}
	}
	if (outdir.empty() || bursts_path.empty() || pgm_path.empty()) {
		fprintf(stderr, "usage: %s --out DIR --init-bursts FILE --golden-pgm FILE [--mmio-cycles N]\n", argv[0]);
		return 2;
	}
	load_inputs(bursts_path, pgm_path);

	Verilated::commandArgs(argc, argv);
	top = new VTLI2C;
	fresh_model();
	top->reset = 1;
	for (int i = 0; i < 20; i++) {
		tick();
	}
	top->reset = 0;
	tick();

	json = std::fopen((outdir + "/results.json").c_str(), "w");
	std::fprintf(json, "{");
	jkv("\"mmio_extra_cycles\": %llu", (unsigned long long)mmio_extra_cycles);

	uint64_t c0, data_cyc;
	int rc;

	// A. 100 kHz, messages shaped as ssd1306.c sends them (i2c_burst_write)
	glue_init(BASE, 100000);
	fresh_model();
	c0 = cyc;
	rc = screen(true, &data_cyc);
	phase_json("burst_100k", c0, rc);
	jkv("\"burst_100k_frame_cycles\": %llu", (unsigned long long)data_cyc);

	// B. 100 kHz, the same bytes as one message per transfer (i2c_write with the control byte first)
	fresh_model();
	c0 = cyc;
	rc = screen(false, &data_cyc);
	phase_json("single_100k", c0, rc);
	jkv("\"single_100k_frame_cycles\": %llu", (unsigned long long)data_cyc);

	// C. 400 kHz, both shapes
	glue_init(BASE, 400000);
	fresh_model();
	c0 = cyc;
	rc = screen(true, &data_cyc);
	phase_json("burst_400k", c0, rc);
	jkv("\"burst_400k_frame_cycles\": %llu", (unsigned long long)data_cyc);
	fresh_model();
	c0 = cyc;
	rc = screen(false, &data_cyc);
	phase_json("single_400k", c0, rc);
	jkv("\"single_400k_frame_cycles\": %llu", (unsigned long long)data_cyc);

	// C2. 344,830 Hz asked for: prescale 19, the fastest setting whose MEASURED SCL stays
	//     inside Fast-mode's 400 kHz (P1 shows the TLI2C runs ~7.6 % fast at prescale 16).
	glue_init(BASE, 344830);
	fresh_model();
	c0 = cyc;
	rc = screen(false, &data_cyc);
	phase_json("single_345k", c0, rc);
	jkv("\"single_345k_frame_cycles\": %llu", (unsigned long long)data_cyc);

	// D. no ACK: address 0x3d with nothing there, then 0x3c must still work
	glue_init(BASE, 100000);
	fresh_model();
	glue_set_log(0);
	static const uint8_t nop[] = {0x00, 0xe3};
	int rc_nack = glue_i2c_write(nop, 2, 0x3d);
	int scl_held_low_after_nack = top->auto_io_out_scl_oe;
	int sda_held_low_after_nack = top->auto_io_out_sda_oe;
	int rc_after = glue_i2c_write(nop, 2, 0x3c);
	glue_set_log(1);
	jkv("\"nack\": {\"rc_nack\": %d, \"scl_oe_after_nack\": %d, \"sda_oe_after_nack\": %d, "
	    "\"rc_next_write_to_3c\": %d, \"model_cmds_after\": %zu}",
	    rc_nack, scl_held_low_after_nack, sda_held_low_after_nack, rc_after, model.n_cmds_kept);
	std::printf("RESULT nack           rc_nack=%d scl_oe_after=%d sda_oe_after=%d rc_next=%d\n",
		    rc_nack, scl_held_low_after_nack, sda_held_low_after_nack, rc_after);
	save_model("nack");

	static const uint8_t two_nops[] = {0x00, 0xe3, 0xe3};

	// D2. Raw prescale sweep, mechanism test. The driver only offers two prescales, so the
	//     divider is programmed directly here. An early reload on the master's OWN falling
	//     edge predicts period = 4*(p+1) + F + 4 + d0, where F = (p>>2)+1 is the input
	//     filter's sampling period: the shortfall against OpenCores' 5*(p+1) GROWS with the
	//     prescale. A filter that only delayed the master's view of SCL, with the divider
	//     free-running, would leave the period at 5*(p+1) whatever the prescale.
	{
		static const uint32_t ps[] = {8, 16, 32, 67, 100, 200};
		std::string rows;
		for (uint32_t pre : ps) {
			hw_reset();
			glue_init(BASE, 100000);
			tl_op(false, 0x08, 0x00);               // control: disable
			tl_op(false, 0x00, (uint8_t)(pre & 0xff));       // prescale lo
			tl_op(false, 0x04, (uint8_t)((pre >> 8) & 0xff)); // prescale hi
			tl_op(false, 0x08, 0x80);               // control: enable
			fresh_model();
			glue_set_log(0);
			(void)glue_i2c_write(two_nops, 3, 0x3c);
			glue_set_log(1);
			char row[256];
			std::snprintf(row, sizeof(row),
				      "%s{\"prescale\": %u, \"period_min\": %llu, \"period_max\": %llu, "
				      "\"period_mean\": %.3f, \"n\": %llu, \"opencores\": %u, \"predicted\": %u}",
				      rows.empty() ? "" : ", ", pre,
				      (unsigned long long)tgt.period_in_byte.min,
				      (unsigned long long)tgt.period_in_byte.max,
				      tgt.period_in_byte.n ? (double)tgt.period_in_byte.sum / (double)tgt.period_in_byte.n : 0.0,
				      (unsigned long long)tgt.period_in_byte.n, 5 * (pre + 1),
				      4 * (pre + 1) + ((pre >> 2) + 1) + 4 + (uint32_t)((-(int64_t)(4 + 4 * (pre + 1))) % (int64_t)((pre >> 2) + 1) + ((pre >> 2) + 1)) % ((pre >> 2) + 1));
			rows += row;
			std::printf("RESULT prescale=%-4u period %llu..%llu mean %.3f (OpenCores %u)\n", pre,
				    (unsigned long long)tgt.period_in_byte.min,
				    (unsigned long long)tgt.period_in_byte.max,
				    tgt.period_in_byte.n ? (double)tgt.period_in_byte.sum / (double)tgt.period_in_byte.n : 0.0,
				    5 * (pre + 1));
			std::fflush(stdout);
		}
		jkv("\"prescale_sweep\": [%s]", rows.c_str());
	}

	// E. clock stretching sweep. For each hold length the RTL is reset, the target holds SCL
	//    low for `hold` cycles from the falling edge that ends bit 4 of data byte 1 (the
	//    control byte of a 00 E3 E3 write), and the driver gets a 50 ms-equivalent budget.
	//    Then, without a reset: does i2c_sifive_configure() (control=0, prescale, control=EN)
	//    bring the controller back, measured by a second 00 E3 write under the same budget?
	static const uint64_t holds[] = {10, 60, 100, 130, 140, 200, 250, 300, 350, 400, 3448, 34483};
	const uint64_t budget = 1724138ULL; // 50 ms at 34.48 MHz
	std::string sweep;
	for (uint64_t hold : holds) {
		hw_reset();
		glue_init(BASE, 100000);
		fresh_model();
		tgt.stretch_byte = 1;
		tgt.stretch_bit = 4;
		tgt.stretch_cycles = hold;
		c0 = cyc;
		volatile int ret1 = 0, rc1 = 0, ret2 = 0, rc2 = 0;
		glue_set_log(0);
		budget_end = cyc + budget;
		if (setjmp(budget_jmp) == 0) {
			rc1 = glue_i2c_write(two_nops, 3, 0x3c);
			ret1 = 1;
		}
		budget_end = UINT64_MAX;
		top->auto_control_xing_in_a_valid = 0; /* a budget stop can land mid-transaction */
		tick();
		uint64_t cyc1 = cyc - c0;
		int oe_scl = top->auto_io_out_scl_oe, tip = (tl_op(true, 0x10, 0) & 0x02) ? 1 : 0;
		uint64_t hi_min = tgt.high_all.n ? tgt.high_all.min : 0;
		uint64_t hi_max = tgt.high_all.max, hi_n = tgt.high_all.n;
		std::string cmds1;
		char hx[8];
		for (size_t i = 0; i < model.n_cmds_kept; i++) {
			std::snprintf(hx, sizeof(hx), "%s%02x", i ? " " : "", model.cmds[i]);
			cmds1 += hx;
		}
		// recovery attempt, no reset
		size_t kept = model.n_cmds_kept;
		budget_end = cyc + budget;
		if (setjmp(budget_jmp) == 0) {
			glue_init(BASE, 100000);
			rc2 = glue_i2c_write(two_nops, 2, 0x3c);
			ret2 = 1;
		}
		budget_end = UINT64_MAX;
		glue_set_log(1);
		bool recovered = ret2 && rc2 == 0 && model.n_cmds_kept == kept + 1 && model.cmds[kept] == 0xe3;
		char row[512];
		std::snprintf(row, sizeof(row),
			      "%s{\"hold_cycles\": %llu, \"returned\": %d, \"rc\": %d, \"cycles\": %llu, "
			      "\"cmds_decoded\": \"%s\", \"scl_oe_at_end\": %d, \"tip_at_end\": %d, "
			      "\"high_min\": %llu, \"high_max\": %llu, \"high_n\": %llu, "
			      "\"reconfigure_then_write_returned\": %d, \"rc2\": %d, \"recovered\": %d}",
			      sweep.empty() ? "" : ", ", (unsigned long long)hold, ret1, rc1,
			      (unsigned long long)cyc1, cmds1.c_str(), oe_scl, tip,
			      (unsigned long long)hi_min, (unsigned long long)hi_max,
			      (unsigned long long)hi_n, ret2, rc2, recovered);
		sweep += row;
		std::printf("RESULT stretch hold=%-6llu returned=%d rc=%d cycles=%-8llu cmds='%s' scl_oe=%d tip=%d t_HIGH %llu..%llu (n=%llu) | reconfigure+write returned=%d rc=%d recovered=%d\n",
			    (unsigned long long)hold, ret1, rc1, (unsigned long long)cyc1, cmds1.c_str(),
			    oe_scl, tip, (unsigned long long)hi_min, (unsigned long long)hi_max,
			    (unsigned long long)hi_n, ret2, rc2, recovered);
		std::fflush(stdout);
	}
	jkv("\"stretch_sweep\": [%s]", sweep.c_str());

	// F. SCL wedged low from outside for 50 ms, then released: does the driver return while
	//    it is held, and does the controller work once it is released (reconfigure + write)?
	hw_reset();
	glue_init(BASE, 100000);
	fresh_model();
	hold_scl_forever = true;
	c0 = cyc;
	uint64_t ops0 = mmio_ops;
	volatile int returned = 0, rc_wedge = 0;
	glue_set_log(0);
	budget_end = cyc + budget;
	if (setjmp(budget_jmp) == 0) {
		rc_wedge = glue_i2c_write(nop, 2, 0x3c);
		returned = 1;
	}
	budget_end = UINT64_MAX;
	uint64_t wedge_cycles = cyc - c0, wedge_polls = mmio_ops - ops0;
	hold_scl_forever = false;
	volatile int ret2 = 0, rc2 = 0;
	top->auto_control_xing_in_a_valid = 0;
	tick();
	budget_end = cyc + budget;
	if (setjmp(budget_jmp) == 0) {
		glue_init(BASE, 100000);
		rc2 = glue_i2c_write(nop, 2, 0x3c);
		ret2 = 1;
	}
	budget_end = UINT64_MAX;
	glue_set_log(1);
	jkv("\"wedged_scl\": {\"returned\": %d, \"rc\": %d, \"cycles\": %llu, \"mmio_polls\": %llu, "
	    "\"after_release_reconfigure_write_returned\": %d, \"rc2\": %d, \"model_cmds\": %zu}",
	    returned, rc_wedge, (unsigned long long)wedge_cycles, (unsigned long long)wedge_polls,
	    ret2, rc2, model.n_cmds_kept);
	std::printf("RESULT wedged_scl     returned=%d rc=%d cycles=%llu | after release: reconfigure+write returned=%d rc=%d cmds=%zu\n",
		    returned, rc_wedge, (unsigned long long)wedge_cycles, ret2, rc2, model.n_cmds_kept);
	save_model("wedged");

	std::fprintf(json, "\n}\n");
	std::fclose(json);
	top->final();
	delete top;
	return 0;
}
