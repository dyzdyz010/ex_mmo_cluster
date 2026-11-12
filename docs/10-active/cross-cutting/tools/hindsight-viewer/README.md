# Hindsight 只读查看器（只测试）

在浏览器里用图形界面看 NPC 的长期记忆（Hindsight 记忆库 `npc-life-<角色编号>`）：概览、记忆、认识、人和物、后台任务。
只测试工具，不是分发运行时依赖。只用 Python 标准库，页面不引用任何外部资源。

- **启动**：双击 `start-viewer.cmd`，或 `python -B viewer.py`，再打开 <http://127.0.0.1:18940/>。关掉窗口即停止。
- **换 Hindsight 地址 / 端口**：`python -B viewer.py --hindsight http://127.0.0.1:18931 --port 18940`（`start-viewer.cmd` 也接受这些参数）。
- **只读保证**：`viewer.py` 只绑定 `127.0.0.1`，只把 `GET /api/<路径>` 转发为 Hindsight 的 `GET /<路径>`，其他方法一律 405；不缓存、不重试，超时 15 秒。
- **自动刷新**：勾选后每 10 秒一轮，上一轮没回来不发下一轮。
- **看导出文件**：点“打开导出文件…”，一次多选 JSON（如 `.demo/observe/<实跑>/export/` 下的 `hindsight-stats.json`、
  `hindsight-memories-list.json`、`hindsight-mental-model-*.json`），按文件名或内容识别类别，不经过服务。
  直接双击 `index.html` 打开时也能用离线模式。
