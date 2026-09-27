# Camera backend

Embedded runtime sources from [lorenshung/ospi-camera](https://github.com/lorenshung/ospi-camera)
at `694b8e99da9d0c7d1900f9bba13cbb3e72a278d2`, under the included Apache-2.0 license.

Local adaptations add bounded two-frame DMA, explicit sensor-state initialization,
and a per-device context supplied by the existing Zephyr binding. The host renderer
in `../host/frame-to-colour.py` adds the shield's 180-degree mounting rotation and
an uncorrected display mode for the tutorial.
Tests, examples, build artifacts and unrelated RTL sources are not vendored.

The current FPGA image already provides the compatible DMA register interface;
no new bitstream is required. Capture failures after DMA is armed require a SoC reset
before the destination can be reused. Live capture on the tutorial board remains
unverified; software builds and local checks do not establish hardware acceptance.
