defmodule SceneServer.Voxel.Field.LightE2ETest do
  # 光学正交系统 e2e(光成真机制):光源 → LightPropagationKernel 写 :light 场 → 同 tick
  # ReactionKernel 读 :light gate 光敏反应 → photo_sensor 产 {:set_tag :illuminated} 效果
  # (经 SystemActor 落 truth,与既有 :open/:rusting tag 同路径)。确定性 kernel-chain,非 DB。
  use ExUnit.Case, async: false

  alias SceneServer.Voxel.{
    AttributeCatalog,
    MaterialCatalog,
    NormalBlockData,
    Storage,
    TagCatalog,
    Types
  }

  alias SceneServer.Voxel.Field.{FieldRegion, FieldSource, KernelContext}
  alias SceneServer.Voxel.Field.Kernels.{LightPropagationKernel, ReactionKernel}

  setup do
    for cat <- [AttributeCatalog, TagCatalog] do
      case start_supervised({cat, []}) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end

    :ok
  end

  # 直线 AABB 0..4,跑 [光传播, 反应] 两 kernel(同 FieldTickWorker fold 顺序,region 线程)。
  defp region do
    FieldRegion.new(%{
      region_id: 1,
      chunk_coord: {0, 0, 0},
      aabb: {{0, 0, 0}, {4, 0, 0}},
      kernels: [
        %{id: :light_propagation, module: LightPropagationKernel},
        %{id: :reaction, module: ReactionKernel}
      ]
    })
  end

  defp put(storage, x, material_name) do
    id = MaterialCatalog.material_id(material_name)
    Storage.put_solid_block(storage, Types.macro_index!({x, 0, 0}), NormalBlockData.new(id))
  end

  # 按 region.kernels 顺序 fold:每 kernel 收 threaded region,产 effects 累积(同 FieldTickWorker)。
  defp run_chain(region, storage) do
    context = KernelContext.new(region, 1, storage)

    {_final_region, effects} =
      Enum.reduce(region.kernels, {region, []}, fn spec, {reg, acc} ->
        {:cont, next_region, eff} = spec.module.tick(reg, context, Map.get(spec, :opts, %{}))
        {next_region, acc ++ eff}
      end)

    effects
  end

  defp illuminates?(effects, macro_index) do
    Enum.any?(effects, fn
      {:set_tag, %{macro_index: ^macro_index, add: add}} -> :illuminated in add
      _ -> false
    end)
  end

  test "光成真机制:ember 光源照亮相邻 photo_sensor(置 :illuminated)" do
    sensor = Types.macro_index!({1, 0, 0})

    effects =
      Storage.empty(1, {0, 0, 0})
      |> put(0, :ember)
      |> put(1, :photo_sensor)
      |> then(&run_chain(region(), &1))

    assert illuminates?(effects, sensor),
           "ember 光经光场照到相邻 photo_sensor → :illuminated(光改 truth 态)"
  end

  test "遮光:不透明墙挡在光源与 photo_sensor 之间 → 不点亮" do
    # ember 在 0,stone 墙在 1,photo_sensor 在 2:光被墙挡(墙 onward 0)→ sensor 暗。
    sensor = Types.macro_index!({2, 0, 0})

    effects =
      Storage.empty(1, {0, 0, 0})
      |> put(0, :ember)
      |> put(1, :stone)
      |> put(2, :photo_sensor)
      |> then(&run_chain(region(), &1))

    refute illuminates?(effects, sensor), "墙后 photo_sensor 不被照亮(遮光)"
  end

  test "无光源 → photo_sensor 不点亮(惰性安全)" do
    sensor = Types.macro_index!({1, 0, 0})

    effects =
      Storage.empty(1, {0, 0, 0})
      |> put(0, :stone)
      |> put(1, :photo_sensor)
      |> then(&run_chain(region(), &1))

    refute illuminates?(effects, sensor)
  end

  test "热致发光跨系统:高温铁(无 light_emission)的光照亮相邻 photo_sensor" do
    # iron 在 0 设 1500℃ → 热致白炽当光源 → 照亮相邻 photo_sensor。电/热 → 光 → 光敏 跨系统涌现。
    sensor = Types.macro_index!({1, 0, 0})
    hot_raw = round(1500.0 * 65_536)

    effects =
      Storage.empty(1, {0, 0, 0})
      |> put(0, :iron)
      |> Storage.put_attribute_for_cell(Types.macro_index!({0, 0, 0}), "temperature", hot_raw)
      |> put(1, :photo_sensor)
      |> then(&run_chain(region(), &1))

    assert illuminates?(effects, sensor), "高温铁热致发光照亮 photo_sensor(热→光→光敏)"
  end

  test "FieldSource :light 源默认跑 [光传播, 反应] kernel(光排反应前)" do
    source = FieldSource.normalize(%{source_kind: :light})
    ids = Enum.map(source.kernel_specs, & &1.id)
    assert ids == [:light_propagation, :reaction]
  end
end
