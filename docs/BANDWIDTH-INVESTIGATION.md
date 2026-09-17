# Android UI bandwidth investigation

Controlled Settings scrolling showed Turnip using much higher average memory bandwidth than stock Qualcomm while GPU busy time remained similar. Kernel GPUBW tracing showed that the extra same-IB bus events were driven by changing average-bandwidth votes, not extra IB transitions.

Forced GMEM reduced memory bandwidth substantially but increased GPU busy/stall cost. Forced SYSMEM closely matched default Turnip behavior. Synthetic RGBA AHardwareBuffers appeared linear/noncompressed on both drivers, so a simple lost-UBWC explanation was not established.

Current goal: observe actual Turnip GMEM/SYSMEM/autotune decisions for Android UI renderpasses without changing rendering behavior.

## Current diagnostic branch

`diagnostic/autotune-udp-v036` carries the v0.33-v0.36 diagnostic progression. v0.36 bypasses the ROM's unreliable userspace log-write path by sending bounded diagnostic packets over UDP loopback to a bundled on-device receiver. It also adds a device-level heartbeat outside `tu_autotune` so Vulkan device creation can be distinguished from autotune construction.
