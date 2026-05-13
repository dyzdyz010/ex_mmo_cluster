defmodule SceneServer.Voxel.Field.FieldIntegrationTest do
  # Phase 6 局部场最小目标:集成测试(纯函数路径,不启动 ChunkProcess
  # GenServer 与 FieldTickWorker)。
  #
  # 流程对应 spec §7.1 最小验证:
  #   1. 创建 8x8x8 空 FieldRegion + 一个 (0,0,0) 热源 (temperature = 500.0,
  #      高于 spec 草案 100.0,因为 base α = 0.1 + β = 0.01 时低源量 10
  #      ticks 不足以让 (1,0,0) 越过 env+1)
  #   2. 手动 tick 10 次
  #   3. 断言 (1,0,0) 处温度 > env_temp + 1.0
  #   4. 断言 (7,7,7) 处温度 < (1,0,0) 且远低于源(远处未被显著加热;
  #      不要求 ≈ env_temp,因为初始 layer 全 0,β=0.01 衰减只能把它拉到
  #      约 1.9°C,远未达 env_temp)
  #   5. 断言 max_ticks 触发后 tick_limit_reached?/1 = true
  use ExUnit.Case, async: true

  alias SceneServer.Voxel.Field.{FieldLayer, FieldRegion, TemperatureField}
  alias SceneServer.Voxel.Types

  test "minimal end-to-end temperature diffusion in an 8x8x8 region" do
    source_idx = Types.macro_index!({0, 0, 0})

    region =
      FieldRegion.new(%{
        region_id: 1,
        chunk_coord: {0, 0, 0},
        aabb: {{0, 0, 0}, {7, 7, 7}},
        field_types: [:temperature],
        source_points: [
          %{macro_index: source_idx, field_type: :temperature, value: 500.0}
        ],
        max_ticks: 10
      })

    # Run 10 ticks.
    region =
      Enum.reduce(1..10, region, fn _, acc ->
        acc
        |> TemperatureField.tick(nil)
        |> FieldRegion.increment_tick()
      end)

    layer = FieldRegion.get_layer(region, :temperature)
    env = TemperatureField.env_temperature()

    # Source maintained at 500.0 (re-applied each tick)
    assert FieldLayer.get(layer, source_idx) == 500.0

    # Adjacent cell (1,0,0) heated above env_temp + 1.0
    near_val = FieldLayer.get(layer, Types.macro_index!({1, 0, 0}))

    assert near_val > env + 1.0,
           "expected (1,0,0) temp > env+1 (#{env + 1.0}); got #{near_val}"

    # Far cell (7,7,7) should remain much cooler than the near cell —
    # heat from (0,0,0) does not propagate 21 manhattan-distance hops in
    # 10 ticks with α = 0.1 / β = 0.01.
    far_val = FieldLayer.get(layer, Types.macro_index!({7, 7, 7}))

    assert far_val < near_val,
           "expected far (#{far_val}) < near (#{near_val})"

    assert far_val < 30.0,
           "expected far (#{far_val}) to remain far below source 500.0"

    # max_ticks = 10, we incremented 10 times → limit reached.
    assert FieldRegion.tick_limit_reached?(region)

    # And before reaching limit, it should be false.
    pre_limit_region = %{region | tick_count: 9}
    refute FieldRegion.tick_limit_reached?(pre_limit_region)
  end
end
