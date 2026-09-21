/* SPDX-License-Identifier: Apache-2.0 */
#ifndef SSD1306_EMUL_H_
#define SSD1306_EMUL_H_

#include <stdint.h>
#include "ssd1306_model.h"

enum ssd1306_emul_wire {
	SSD1306_EMUL_WIRE_CONTRACT,
	SSD1306_EMUL_WIRE_STOCK_SIFIVE,
};

void ssd1306_emul_set_wire(enum ssd1306_emul_wire w);
struct ssd1306_model *ssd1306_emul_model(uint16_t addr);

#endif
