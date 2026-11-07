defmodule VoxelRegion.SkinPageTest do
  @moduledoc "只测试：真实 Pages format2 编解码边界，旧 map 的读兼容与写回滚兼容；无数据库替身。"
  use ExUnit.Case, async: true
  @moduletag :t0
  alias MmoContracts.Voxel.{Payload, SkinField, Skins}
  alias VoxelRegion.World.Pages

  test "base pages admit legacy maps in loader and still persist legacy maps" do
    unit = {:page, :base, {1, {-2, 0, 1}}}
    author = %Payload{level: 1, region: {-2, 0, 1}, cells: :binary.copy(<<11, 0>>, 287_496),
      records: %{{1, 2, 3} => Skins.uniform(19)}}
    canonical = Payload.admit(author)
    legacy = Payload.persisted(canonical)
    assert is_map(legacy.records) and not is_struct(legacy.records)
    old_row = Pages.row(unit, legacy)
    assert Pages.decode(old_row.payload) == legacy
    assert {^unit, loaded} = Pages.unit_value(old_row)
    assert is_struct(loaded.records, SkinField)
    assert Payload.skins(loaded, {1, 2, 3}, 11) == Skins.uniform(19)
    assert Payload.encode(loaded, %{}, 3, 123) == Payload.encode(legacy, %{}, 3, 123)
    new_row = Pages.row(unit, loaded)
    assert Pages.decode(new_row.payload) == legacy
  end
end
