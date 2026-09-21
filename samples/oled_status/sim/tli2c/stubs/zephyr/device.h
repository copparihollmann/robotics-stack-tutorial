/* SPDX-License-Identifier: Apache-2.0 */
#pragma once
#include <stddef.h>
#include <stdint.h>
#include <stdbool.h>
#include <errno.h>
struct device {
	const char *name;
	const void *config;
	const void *api;
	void *data;
};
#define DEVICE_API(_class, _name) const struct _class##_driver_api _name
#define DT_INST_FOREACH_STATUS_OKAY(fn)
