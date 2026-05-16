defmodule SceneServer.Voxel.Field.FieldIntegrationTest do
  # Phase 6 局部场最小目标:集成测试(纯函数路径,不启动 ChunkProcess
  # GenServer 与 FieldTickWorker)。
  #
  # 流程对应 spec §7.1 最小验证:
  #   1. 创建 8x8x8 空 FieldRegion + 一个 (0,0,0) 热源 (temperature = 500.0)
  #   2. 手动 tick 10 次
  #   3. 断言 (1,0,0) 处温度按真实 10Hz SI 步长轻微上升
  #   4. 断言 (7,7,7) 处温度 < (1,0,0) 且远低于源(远处未被显著加热;
  #      真实 1m voxel 不会在 1 秒内跨 21 个 manhattan hops)
  #   5. 断言 max_ticks 触发后 tick_limit_reached?/1 = true
  use ExUnit.Case, async: true

  alias SceneServer.Voxel.Field.{FieldLayer, FieldRegion, TemperatureField}
  alias SceneServer.Voxel.Field.Kernels.TemperatureDiffusionKernel
  alias SceneServer.Voxel.Types

  test "minimal end-to-end temperature diffusion in an 8x8x8 region" do
    source_idx = Types.macro_index!({0, 0, 0})

    region =
      FieldRegion.new(%{
        region_id: 1,
        chunk_coord: {0, 0, 0},
        aabb: {{0, 0, 0}, {7, 7, 7}},
        kernels: [%{id: :temperature_diffusion, module: TemperatureDiffusionKernel}],
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

    # Adjacent cell (1,0,0) is measurably warmer, but real 1m voxels do not
    # jump by whole degrees over one second with the default material.
    near_val = FieldLayer.get(layer, Types.macro_index!({1, 0, 0}))

    assert near_val > env,
           "expected (1,0,0) temp > env (#{env}); got #{near_val}"

    assert near_val < env + 0.02,
           "expected (1,0,0) to stay within a small physical increment; got #{near_val}"

    # Far cell (7,7,7) should remain much cooler than the near cell —
    # heat from (0,0,0) does not propagate 21 manhattan-distance hops in
    # 10 ticks with dt-scaled physical diffusion.
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
