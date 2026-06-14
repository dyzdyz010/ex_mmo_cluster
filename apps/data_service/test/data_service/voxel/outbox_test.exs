defmodule DataService.Voxel.OutboxTest do
  # 梯队3 step3.9:durable replication outbox(AUTH-9/10)。共享 voxel_outbox 表,async:false + 清表。
  use ExUnit.Case, async: false

  alias DataService.Voxel.Outbox

  setup do
    Outbox.reset()
    :ok
  end

  defp append(scene, coord, base, new, payload, rc \\ "state") do
    Outbox.append(%{
      logical_scene_id: scene,
      chunk_coord: coord,
      base_chunk_version: base,
      new_chunk_version: new,
      reliability_class: rc,
      payload: payload
    })
  end

  test "append + read_since 重放错过的 delta(按版本升序)" do
    coord = {0, 0, 0}
    assert :ok = append(1, coord, 0, 1, <<1>>)
    assert :ok = append(1, coord, 1, 2, <<2>>)
    assert :ok = append(1, coord, 2, 3, <<3>>)

    # since 1 → 重放 v2、v3。
    records = Outbox.read_since(1, coord, 1)
    assert Enum.map(records, & &1.new_chunk_version) == [2, 3]
    assert Enum.map(records, & &1.payload) == [<<2>>, <<3>>]
    assert Enum.map(records, & &1.base_chunk_version) == [1, 2]
  end

  test "read_since 0 重放全部" do
    coord = {1, 2, 3}
    append(7, coord, 0, 1, <<10>>)
    append(7, coord, 1, 2, <<20>>)

    assert Outbox.read_since(7, coord, 0) |> length() == 2
  end

  test "watermark = max committed new_chunk_version(无则 0)" do
    coord = {5, 5, 5}
    assert Outbox.watermark(1, coord) == 0

    append(1, coord, 0, 1, <<1>>)
    append(1, coord, 1, 4, <<2>>)
    assert Outbox.watermark(1, coord) == 4
  end

  test "不同 chunk / scene 隔离" do
    append(1, {0, 0, 0}, 0, 5, <<1>>)
    append(1, {1, 0, 0}, 0, 9, <<2>>)
    append(2, {0, 0, 0}, 0, 7, <<3>>)

    assert Outbox.watermark(1, {0, 0, 0}) == 5
    assert Outbox.watermark(1, {1, 0, 0}) == 9
    assert Outbox.watermark(2, {0, 0, 0}) == 7
    assert Outbox.read_since(1, {0, 0, 0}, 0) |> length() == 1
  end

  test "reliability_class 默认 state,可覆盖" do
    coord = {0, 0, 0}
    append(1, coord, 0, 1, <<1>>)
    append(1, coord, 1, 2, <<2>>, "bulk")

    classes = Outbox.read_since(1, coord, 0) |> Enum.map(& &1.reliability_class)
    assert classes == ["state", "bulk"]
  end

  test "reset 清空" do
    append(1, {0, 0, 0}, 0, 1, <<1>>)
    assert Outbox.watermark(1, {0, 0, 0}) == 1
    assert :ok = Outbox.reset()
    assert Outbox.watermark(1, {0, 0, 0}) == 0
  end
end
