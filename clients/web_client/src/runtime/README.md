# Runtime

职责：

- 组装 world、render、movement、observe、CLI。
- 维护浏览器主循环、固定 tick、HUD 和输入路由。
- 作为当前浏览器客户端的单一运行时所有者。

边界：

- runtime 自己不定义 voxel truth 和 mesher 算法，只调度它们。
- runtime 自己不定义协议常量，只消费 `net/`。
- runtime 对调试面的义务最高：任何关键状态变化都应能通过 CLI 或 observe 日志读到。
