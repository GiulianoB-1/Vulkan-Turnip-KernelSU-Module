# Android UI bandwidth investigation

Controlled Settings scrolling showed Turnip using much higher average memory bandwidth than stock Qualcomm while GPU busy time remained similar. Kernel GPUBW tracing showed that the extra same-IB bus events were driven by changing average-bandwidth votes, not extra IB transitions.

Forced GMEM reduced memory bandwidth substantially but increased GPU busy/stall cost. Forced SYSMEM closely matched default Turnip behavior. Synthetic RGBA AHardwareBuffers appeared linear/noncompressed on both drivers, so a simple lost-UBWC explanation was not established.

Current goal: observe actual Turnip GMEM/SYSMEM/autotune decisions for Android UI renderpasses without changing rendering behavior.
