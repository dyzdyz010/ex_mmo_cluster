defmodule SceneServer.Voxel.Reaction.ReactionKernelNeighborTest do
  # 化学扩展(2026-06-21):验 ReactionKernel 给每个 cell 填 neighbor_materials(多反应物门控数据)。
  # 用 adjacency-only 自定义规则经 opts.rules 注入,避开温度/相变干扰,纯测「邻居材料是否被预算进 cell」。
  use ExUnit.Case, async: false

  alias SceneServer.Voxel.{
    AttributeCatalog,
    MaterialCatalog,
    NormalBlockData,
    Storage,
    TagCatalog,
    Types
  }

  alias SceneServer.Voxel.Field.{FieldRegion, KernelContext}
  alias SceneServer.Voxel.Field.Kernels.ReactionKernel
  alias SceneServer.Voxel.Reaction.{Rule, Rules}

  setup do
    for cat <- [AttributeCatalog, TagCatalog] do
      case start_supervised({cat, []}) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end

    :ok
  end

  # 在 (0,0,0)/(1,0,0) 放两个相邻 solid 块(materials 由参数定)。
  defp two_block_storage(mat_a, mat_b) do
    a = MaterialCatalog.material_id(mat_a)
    b = MaterialCatalog.material_id(mat_b)
    m0 = Types.macro_index!({0, 0, 0})
    m1 = Types.macro_index!({1, 0, 0})

    Storage.empty(1, {0, 0, 0})
    |> Storage.put_solid_block(m0, NormalBlockData.new(a))
    |> Storage.put_solid_block(m1, NormalBlockData.new(b))
  end

  # 单块(无邻居)在 (0,0,0)。
  defp one_block_storage(mat) do
    Storage.empty(1, {0, 0, 0})
    |> Storage.put_solid_block(Types.macro_index!({0, 0, 0}), NormalBlockData.new(MaterialCatalog.material_id(mat)))
  end

  # adjacency-only 规则:stone + 相邻 water → 加 :wet(无温度条件,不与相变/氧化冲突)。
  defp wet_rule do
    Rule.new!(
      id: :test_wet,
      kind: :tag_reaction,
      material: :stone,
      require_neighbor_materials: [:water],
      effects: [{:add_tag, :wet}]
    )
  end

  defp tick(storage, aabb, rules) do
    region =
      FieldRegion.new(%{
        region_id: 1,
        chunk_coord: {0, 0, 0},
        aabb: aabb,
        kernels: [%{id: :reaction, module: ReactionKernel, opts: %{}}]
      })

    context = KernelContext.new(region, 1, storage)
    {:cont, _region, effects} = ReactionKernel.tick(region, context, %{rules: rules})
    effects
  end

  defp stone_macro, do: Types.macro_index!({0, 0, 0})

  test "相邻 water 的 stone 被填入 neighbor_materials → 规则触发(加 :wet)" do
    effects = tick(two_block_storage(:stone, :water), {{0, 0, 0}, {1, 0, 0}}, [wet_rule()])

    assert Enum.any?(effects, fn
             {:set_tag, %{macro_index: idx, add: add}} -> idx == stone_macro() and :wet in add
             _ -> false
           end)
  end

  test "无相邻 water(单块 stone)→ neighbor_materials 空 → 规则不触发" do
    effects = tick(one_block_storage(:stone), {{0, 0, 0}, {0, 0, 0}}, [wet_rule()])

    refute Enum.any?(effects, fn
             {:set_tag, %{add: add}} -> :wet in add
             _ -> false
           end)
  end

  test "相邻是 iron(非 water)→ 不触发(只填实际邻居材料,无误报)" do
    effects = tick(two_block_storage(:stone, :iron), {{0, 0, 0}, {1, 0, 0}}, [wet_rule()])

    refute Enum.any?(effects, fn
             {:set_tag, %{add: add}} -> :wet in add
             _ -> false
           end)
  end

  test "真实多反应物规则经 kernel:相邻熔岩的水(默认温度)闪蒸成 steam" do
    # lava@(0,0,0) + water@(1,0,0)。水默认温度(0..100℃ 之间)不触发 water 相变,故 water cell 上
    # 唯一 transform 是真实 :water_flash_to_steam(经 kernel 填 neighbor_materials + Rules.all())。
    steam = MaterialCatalog.material_id(:steam)
    water_macro = Types.macro_index!({1, 0, 0})
    effects = tick(two_block_storage(:lava, :water), {{0, 0, 0}, {1, 0, 0}}, Rules.all())

    assert Enum.any?(effects, fn
             {:transform_material, %{macro_index: ^water_macro, to_material_id: to}} -> to == steam
             _ -> false
           end)
  end
end
