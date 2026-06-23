defmodule SceneServer.Voxel.Field.Provisioners.EmergenceTest do
  # Emergence provisioner 的活性谓词 + 本地 AABB 单测(纯数据,无 ChunkProcess)。
  use ExUnit.Case, async: true

  alias SceneServer.Voxel.Field.Provisioners.Emergence
  alias SceneServer.Voxel.MaterialCatalog
  alias SceneServer.Voxel.NormalBlockData
  alias SceneServer.Voxel.Storage

  defp put(storage, coord, name) do
    Storage.put_solid_block(
      storage,
      coord,
      NormalBlockData.new(MaterialCatalog.material_id(name))
    )
  end

  test "emergent_material?:发光体/热源/本征炽热 active,冷惰性材料 inactive" do
    # glowstone(纯发光体)、ember(发光 + 热源)→ active。
    assert Emergence.emergent_material?(MaterialCatalog.material_id(:glowstone))
    assert Emergence.emergent_material?(MaterialCatalog.material_id(:ember))

    # stone / iron / dirt / water:冷惰性(无 light_emission/heat_output、温度默认 20℃)→ inactive。
    for inert <- [:stone, :iron, :dirt, :water] do
      refute Emergence.emergent_material?(MaterialCatalog.material_id(inert)),
             "#{inert} 应为非 emergent(冷惰性,不本征 source 光/热)"
    end
  end

  test "emergent_content?:含 glowstone 的 chunk active,纯 stone chunk inactive" do
    base = Storage.empty(1, {0, 0, 0})

    refute Emergence.emergent_content?(put(base, {0, 0, 0}, :stone)),
           "纯 stone chunk 无 emergent 内容"

    assert Emergence.emergent_content?(put(base, {1, 0, 0}, :glowstone)),
           "含 glowstone(发光体)→ emergent"
  end

  test "detect:emergent cell 的 bbox 各轴扩本地半径并 clamp 到 chunk,不取整 chunk" do
    storage = put(Storage.empty(1, {0, 0, 0}), {1, 0, 0}, :glowstone)
    context = %{storage: storage, chunk_coord: {0, 0, 0}, logical_scene_id: 1}

    assert {:active, attrs, detail} = Emergence.detect(context)

    # 有序流水线:温度扩散 → 光传播 → 反应。
    assert [%{id: :temperature_diffusion}, %{id: :light_propagation}, %{id: :reaction}] =
             attrs.kernels

    assert attrs.max_ticks == nil

    # glowstone 在 {1,0,0},半径 12 → bbox 扩成 {{0,0,0},{13,12,12}}(各轴 clamp 到 [0,15],
    # 1-12 截到 0、1+12=13、0+12=12)。覆盖全部有意义光程;kernel O(1) 后大 AABB 不再 O(n²)。
    assert attrs.aabb == {{0, 0, 0}, {13, 12, 12}}
    assert detail.aabb == attrs.aabb
  end

  test "detect:纯惰性 chunk → inactive(无 region)" do
    storage = put(Storage.empty(1, {0, 0, 0}), {0, 0, 0}, :stone)
    context = %{storage: storage, chunk_coord: {0, 0, 0}, logical_scene_id: 1}

    assert {:inactive, :no_emergent_content, _detail} = Emergence.detect(context)
  end

  test "source_key:按 scene + chunk_coord 稳定" do
    context = %{
      storage: Storage.empty(1, {0, 0, 0}),
      chunk_coord: {2, 0, -1},
      logical_scene_id: 7
    }

    assert Emergence.source_key(context) == {:emergence, 7, {2, 0, -1}}
  end
end
