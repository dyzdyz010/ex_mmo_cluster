# 分级：`@moduletag :t0` 秒级纯逻辑（`--only t0`）；无 tag 为默认集成；`:slow` 单项 ≥ 45 s，夜间／阶段验收 `--include slow`。
ExUnit.start(exclude: [:slow], assert_receive_timeout: 1_000)
Code.require_file("../../data_service/test/support/database.exs", __DIR__)
Code.require_file("../../scene_server/test/support/body_store.exs", __DIR__)
