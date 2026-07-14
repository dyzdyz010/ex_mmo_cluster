# Legacy/offline 体素脚本

本目录不属于现役 launcher、runtime 或验收入口。这里的脚本只处理已归档 XZ
projection/SVO coverage 数据，且必须显式传 `--allow-legacy-xz` 才会执行。

- `legacy_xz_svo_source_materialize.exs`：审计或迁移历史 XZ SVO source coverage。
- `legacy_xz_lod_projection_pressure_probe.exs`：写 canonical XYZ snapshot 后，显式重建
  历史 XZ heightmap rows，用于离线放大率审计。

任何完整 XYZ 窗口、3D 远景壳、cache、prefetch 或 handoff 实现都不得引用这些脚本。
