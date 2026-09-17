# Baselines

## v0.22
First stable Vulkan 1.4 baseline with the legacy KGSL zero-timeout fence polling fix.

## v0.26
Qualcomm/Samsung flexible YUV420 / NV21 mapping fixed.

## v0.28
Camera compatibility restored for the explicit NV21 path.

## v0.29
Removed dead legacy-KGSL probes and bring-up success logging.

## v0.30
Enabled KGSL NAP (`force_no_nap=0`).

## v0.31
Set KGSL `idle_timer=40` after on-device A/B testing.

## v0.32 — GOLDEN FUNCTIONAL BASELINE
Adds the Mesa 26.2.2 KGSL sync-object merge fix for mixed timestamp/sync-FD and cross-queue timestamp merges. This is the reference point for new behavior experiments.

Golden source branch in the old repository: `agent/a52-turnip-vulkan14-syncmerge-v032`.
Historical head: `d9b3f4e1c51e9669d7159ec1dcd51a1a4abde062`.
