/* SPDX-License-Identifier: Apache-2.0
 * Capture a photo through the camera device and publish it for the ARM reader.
 * DMA has no abort: keep the destination allocated until the next SoC reset.
 */
#include <zephyr/kernel.h>
#include <zephyr/sys/printk.h>
#include <ospi_camera.h>

#ifndef CAM_MCLKDIV
#define CAM_MCLKDIV 2
#endif

static uint8_t frame[256u * 1024u] __aligned(64);
static const struct device *const cam = DEVICE_DT_GET(DT_ALIAS(camera0));

int main(void)
{
	struct ospi_camera_capture cap;
	const char *stage, *detail;
	uint32_t addr = (uint32_t)(uintptr_t)frame;
	uint32_t sum = 0, mclk_hz = 0;

	if (!device_is_ready(cam)) {
		printk("CAM_RESULT shield=unknown ok=0 reason=camera_not_ready\n");
		return 1;
	}
	ospi_camera_set_mclk_div(cam, CAM_MCLKDIV, NULL, &mclk_hz);
	printk("CAM_BOOT sample=cam_capture board=%s mclkdiv=%u mclk_hz=%u\n",
	       CONFIG_BOARD, CAM_MCLKDIV, mclk_hz);
	int rc = ospi_camera_take_photo(cam, frame, sizeof(frame), &cap, &stage, &detail);
	int present = cap.model_id == 0x01b0;
	printk("CAM_SHIELD present=%d\n", present);
	printk("CAM_SENSOR model_id=0x%04x ok=%d\n", cap.model_id, present);
	if (rc != 0) {
		printk("CAM_ERROR stage=%s detail=%s reset_required=%u dma_status=0x%x\n",
		       stage, detail, cap.reset_required, cap.dma_status);
		printk("CAM_RESULT shield=%d ok=0\n", present);
		return 1;
	}
	for (uint32_t i = 0; i < cap.drained; i++) {
		sum += frame[i];
	}
	/* Compute the checksum before eviction, then leave the frame untouched. */
	ospi_camera_flush_to_dram(cam, NULL);
	printk("CAM_GEOM src=lastframe width=%u height=%u bytes=%u\n",
	       cap.measured_width, cap.measured_height, cap.drained);
	printk("CAM_FRAME ok=1 rc=0 addr=0x%08x phys=0x%08x width=%u height=%u "
	       "bytes=%u min=%u max=%u sum=%u saweof=1 dma_status=0x%x "
	       "bayer=BGGR rotate=180\n",
	       addr, 0x10000000u | (addr & 0x0fffffffu), cap.measured_width,
	       cap.measured_height, cap.drained, cap.vmin, cap.vmax, sum, cap.dma_status);
	printk("CAM_RESULT shield=1 ok=1\n");
	return 0;
}
