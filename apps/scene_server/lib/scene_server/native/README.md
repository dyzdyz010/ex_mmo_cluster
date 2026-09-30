# Scene native adapter map

- `voxim_movement.ex`：Rustler 适配 `native/voxim_movement_nif`，执行与 Voxim 客户端共享的移动内核。

适配层保持薄：业务规则与进程状态留在上层 Elixir 模块。
