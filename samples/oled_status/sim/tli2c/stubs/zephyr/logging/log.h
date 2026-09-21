/* SPDX-License-Identifier: Apache-2.0 */
/* Host stub: just enough of <zephyr/logging/log.h> to compile drivers/i2c/i2c_sifive.c unmodified. */
#pragma once
#include <stdio.h>
extern int stub_log_enabled;
#define LOG_MODULE_REGISTER(...)
#define LOG_ERR(...) do { if (stub_log_enabled) { fprintf(stderr, "[i2c_sifive] " __VA_ARGS__); fputc('\n', stderr); } } while (0)
#define LOG_WRN LOG_ERR
#define LOG_INF(...)
#define LOG_DBG(...)
