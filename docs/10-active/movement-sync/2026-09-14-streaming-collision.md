# Voxim 全域碰撞流送

用户要求正式地图全域可玩，体素流送与权威碰撞一起推进。
当前决策、窗口与移交合同、验收矩阵及状态统一记录在
[Voxim Streaming](../../../../Voxim/Docs/Playtest/Streaming.md)。
本增量扩展 Voxel kind 4，现有 Session/Voxel/M1 字节不改；不迁移归档客户端。
状态：正式 Voxim 入口已接通，本机打包双端长距离往返、XYZ 窗口、远处采建实跑通过；
公网与容量未验收。Gate 不再用固定 probe 盒拒绝普通建造，真实距离、材料和目标占用由 World 接纳。
