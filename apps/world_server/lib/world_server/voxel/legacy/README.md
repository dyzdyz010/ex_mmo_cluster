# WorldServer 体素 legacy/offline 边界

本目录只保存已归档 XZ 数据的离线审计与迁移适配器，不属于现役 world-pack、
launcher、在线 runtime 或完整 XYZ 窗口验收链。

- 所有公开入口必须使用 `WorldServer.Voxel.Legacy` 命名空间。
- 所有执行入口默认关闭，调用者必须显式传 `legacy_offline?: true`。
- 产物不得发布为当前 world-pack truth，也不得作为缺包、coverage 或远景壳 fallback。
- 新的空间、LOD、cache、prefetch 与 handoff 功能不得依赖本目录。

当前仅保留 `XzSvoSourceMaterializer`，用于读取或迁移历史 XZ SVO source coverage。
