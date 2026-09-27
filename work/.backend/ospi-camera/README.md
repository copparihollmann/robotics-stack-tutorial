# Seat camera sources

This directory ships with the notebook on `seat-content`. It contains the camera
application, Zephyr device module, host renderer and PYNQ board definition, copied
from tutorial commit `b7f703cef79e8067c1b6fddf876085a4d9d4326b`.
The embedded ospi-camera source provenance and license are under
`modules/ospi_camera/backend/`.

`iiswc_lab.camera_build()` builds these files with the seat's preinstalled Zephyr
toolchain, using this directory as its board root. Rendering also resolves here.
Neither operation fetches sources or consults the camera code in `~/tut`.
The provisioned toolchain/environment and connected camera-equipped board remain
prerequisites; live capture is not yet hardware-validated.
