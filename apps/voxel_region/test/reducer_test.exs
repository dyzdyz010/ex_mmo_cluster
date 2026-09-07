defmodule VoxelRegion.ReducerTest do
  @moduledoc """
  T-1：Rust 在线世界生成器直接生成相邻两级 region，父 region 的每个 owned 格必须等于 8 个子格的
  `Reducer.reduce_cell`，材质与表皮逐格相等（R5-A `RecursiveAndSourcePathsFollowChosenOracle` 的服务端版）。
  """
  use ExUnit.Case, async: false

  alias VoxelRegion.{Native, Payload, Reducer}

  @config {1337, -200, 326, 586, 4, 381.77066, 1223.743774, 96}

  defp generate(level, region) do
    {elapsed_us, raw} = :timer.tc(Native, :generate_region, [level, region, @config])
    {:ok, payload} = Payload.decode_body(raw)
    {%{payload | level: level, region: region}, elapsed_us}
  end

  defp check_level(level, {rx, ry, rz} = parent) do
    {coarse, parent_us} = generate(level, parent)
    assert map_size(coarse.records) > 0, "fixture must contain surface skin records"
    assert byte_size(coarse.maps) > 0, "fixture must exercise non-uniform skin maps"

    {children, child_us} =
      for dz <- 0..1, dy <- 0..1, dx <- 0..1, reduce: {%{}, 0} do
        {payloads, elapsed_us} ->
          region = {2 * rx + dx, 2 * ry + dy, 2 * rz + dz}
          {payload, generated_us} = generate(level - 1, region)
          {Map.put(payloads, region, payload), elapsed_us + generated_us}
      end

    {ox, oy, oz} = Payload.origin(parent)

    mismatches =
      for lz <- 1..64, ly <- 1..64, lx <- 1..64, reduce: [] do
        acc ->
          cell = {ox + lx, oy + ly, oz + lz}
          expected = Payload.value(coarse, {lx, ly, lz})

          reduced_children =
            for oct <- 0..7 do
              cx = elem(cell, 0) * 2 + Bitwise.band(oct, 1)
              cy = elem(cell, 1) * 2 + Bitwise.band(Bitwise.bsr(oct, 1), 1)
              cz = elem(cell, 2) * 2 + Bitwise.band(Bitwise.bsr(oct, 2), 1)
              child_region = {Integer.floor_div(cx, 64), Integer.floor_div(cy, 64), Integer.floor_div(cz, 64)}
              Payload.value(Map.fetch!(children, child_region), Payload.local(child_region, {cx, cy, cz}))
            end

          got = Reducer.reduce_cell(reduced_children, level)
          if got == expected or length(acc) >= 5, do: acc, else: [{cell, expected, got} | acc]
      end

    IO.puts(
      "reducer fixture L#{level - 1}->L#{level} #{inspect(parent)} generated parent=#{format_ms(parent_us)}ms children=#{format_ms(child_us)}ms total=#{format_ms(parent_us + child_us)}ms"
    )

    assert mismatches == [],
           "L#{level} #{inspect(parent)}: #{inspect(mismatches, limit: 5, printable_limit: 200)}"

    coarse.map_extent
  end

  defp format_ms(elapsed_us), do: Float.round(elapsed_us / 1_000, 3)

  test "L1 generated region equals reduction of its eight L0 child regions" do
    assert check_level(1, {-1, 2, 0}) == 2
  end

  test "L2 generated region equals reduction of its eight L1 child regions" do
    assert check_level(2, {0, 1, -1}) == 4
  end

  test "L3 generated region equals reduction of its eight L2 child regions" do
    assert check_level(3, {-1, 0, 0}) == 4
  end

  test "mode: non-zero majority, ties to the smallest id, all zero -> 0" do
    assert Reducer.mode([0, 0, 0]) == 0
    assert Reducer.mode([3, 1, 3, 1]) == 1
    assert Reducer.mode([2, 2, 7, 0]) == 2
    assert Reducer.reduce_material([1, 1, 1, 1, 0, 0, 0, 0]) == 0
    assert Reducer.reduce_material([1, 1, 1, 1, 2, 0, 0, 0]) == 1
  end
end
