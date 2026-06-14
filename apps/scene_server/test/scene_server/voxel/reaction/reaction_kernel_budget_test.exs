defmodule SceneServer.Voxel.Reaction.ReactionKernelBudgetTest do
  # 功能完善 · 反应层 R5d(评审修复):安全阀预算须覆盖**每 tick 全部效果**(含燃烧辐射蔓延向量),
  # 而非仅 transform——否则失控级联的真正传播路径不受约束。
  use ExUnit.Case, async: false

  alias SceneServer.Voxel.{
    AttributeCatalog,
    MaterialCatalog,
    NormalBlockData,
    Storage,
    TagCatalog,
    TagSet,
    Types
  }

  alias SceneServer.Voxel.Field.{FieldRegion, KernelContext}
  alias SceneServer.Voxel.Field.Kernels.ReactionKernel

  setup do
    for cat <- [AttributeCatalog, TagCatalog] do
      case start_supervised({cat, []}) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end

    :ok
  end

  defp burning_storage do
    {:ok, burning_id, _} = TagCatalog.lookup_by_name("burning")
    wood = MaterialCatalog.material_id(:wood)
    m0 = Types.macro_index!({0, 0, 0})
    m1 = Types.macro_index!({1, 0, 0})

    storage = Storage.empty(1, {0, 0, 0})
    {storage, ref} = Storage.intern_tag_set(storage, %TagSet{tag_ids: [burning_id]})

    storage
    |> Storage.put_solid_block(m0, %{NormalBlockData.new(wood) | tag_set_ref: ref})
    |> Storage.put_solid_block(m1, %{NormalBlockData.new(wood) | tag_set_ref: ref})
  end

  defp tick(storage, max_effects) do
    region =
      FieldRegion.new(%{
        region_id: 1,
        chunk_coord: {0, 0, 0},
        aabb: {{0, 0, 0}, {1, 0, 0}},
        kernels: [%{id: :reaction, module: ReactionKernel, opts: %{}}]
      })

    context = KernelContext.new(region, 1, storage)

    {:cont, _region, effects} =
      ReactionKernel.tick(region, context, %{max_effects_per_tick: max_effects})

    effects
  end

  test "max_effects_per_tick 截断每 tick 全部效果(含辐射蔓延)" do
    storage = burning_storage()

    # 两个 burning wood:各产 burn(heat+progress=2)+ 互相辐射(2)→ 共 ~6 效果,远超 2。
    assert length(tick(storage, 1000)) > 2
    # 预算 2 → 截断到 2(reaction 在前优先,radiation 溢出被截)。
    assert length(tick(storage, 2)) == 2
  end
end
