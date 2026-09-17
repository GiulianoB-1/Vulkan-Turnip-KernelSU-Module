# Vulkan Turnip KernelSU Module

Mesa Turnip Vulkan driver work for the Samsung Galaxy A52 5G (`a52xq`, Snapdragon 750G / Adreno 619), packaged as a persistent KernelSU module.

This repository contains the Android/KGSL compatibility work, YUV import fixes, Vulkan 1.4 enablement, KernelSU packaging, probes, diagnostics, and performance investigations that were previously developed inside the touchGrass kernel repository.

## Repository policy

- `main` is the **v0.32 golden functional baseline**.
- Experimental work must live on dedicated branches.
- The current bandwidth/autotune investigation lives on `diagnostic/autotune-udp-v036`.
- Kernel development remains in `GiulianoB-1/A52-touchGrass-4.19.325-SukiSU`.

## Golden baseline

v0.32 retains the stable Vulkan 1.4 A619 stack and includes the legacy KGSL zero-timeout fence polling fix, Android YUV/NV21 compatibility work, Camera compatibility, NAP + 40 ms idle policy, and the KGSL mixed timestamp/sync-FD merge fix that resolved the Warframe crash.

See `docs/BASELINES.md` and `docs/TESTING.md`.
