# 只测试：默认仅加载共享夹具；数据库由需要持久化的测试显式启动。
ExUnit.start(exclude: [:oracle, :realtime])
Logger.configure(level: :warning)
Code.require_file("support/world_fixtures.exs", __DIR__)
Code.require_file("../../data_service/test/support/database.exs", __DIR__)
Code.require_file("support/prefab_fixture.exs", __DIR__)
