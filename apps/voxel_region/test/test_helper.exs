# 只测试：默认仅加载共享夹具；数据库由需要持久化的测试显式启动。
# 分级：`@moduletag :t0` 秒级纯逻辑（`--only t0`）；无 tag 为默认集成；`:slow` 单项 ≥ 45 s，夜间／阶段验收 `--include slow`；
# `:oracle`（含 S4 的 `:t2` 样本，需外部 oracle 目录）、`:realtime`、`:benchmark`／`:bench`、`:sim` 按需显式运行。
ExUnit.start(exclude: [:slow, :oracle, :realtime, :benchmark, :sim, :bench])
Logger.configure(level: :warning)
Code.require_file("support/world_fixtures.exs", __DIR__)
Code.require_file("support/held_page_log.exs", __DIR__)
Code.require_file("support/null_log.exs", __DIR__)
Code.require_file("support/binary_retention.exs", __DIR__)
Code.require_file("support/simulation_io_log.exs", __DIR__)
Code.require_file("support/world_clock.exs", __DIR__)
Code.require_file("../../data_service/test/support/database.exs", __DIR__)
Code.require_file("support/prefab_fixture.exs", __DIR__)
Code.require_file("support/damage_invariant.exs", __DIR__)
Code.require_file("support/page_invariant.exs", __DIR__)
