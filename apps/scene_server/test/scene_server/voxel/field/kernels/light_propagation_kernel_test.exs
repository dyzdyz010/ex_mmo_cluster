defmodule SceneServer.Voxel.Field.Kernels.LightPropagationKernelTest do
  # 光学正交系统:LightPropagationKernel 把 truth(light_emission / opacity / temperature)投影成
  # 光源 + 不透明度,经纯 LightPropagation flood 写回 :light 场层。非 DB,Storage.empty fixture。
  use ExUnit.Case, async: false

  alias SceneServer.Voxel.{
    AttributeCatalog,
    MaterialCatalog,
    NormalBlockData,
    Storage,
    TagCatalog,
    Types
  }

  alias SceneServer.Voxel.Field.{FieldLayer, FieldRegion, KernelContext}
  alias SceneServer.Voxel.Field.Kernels.LightPropagationKernel

  setup do
    for cat <- [AttributeCatalog, TagCatalog] do
      case start_supervised({cat, []}) do
        {:ok, _pid} -> :ok
        {:error, {:already_started, _pid}} -> :ok
      end
    end

    :ok
  end

  # 直线 AABB 0..4(沿 x);macro_index(x,0,0) = x。
  defp line_region do
    FieldRegion.new(%{
      region_id: 1,
      chunk_coord: {0, 0, 0},
      aabb: {{0, 0, 0}, {4, 0, 0}},
      kernels: [%{id: :light_propagation, module: LightPropagationKernel}]
    })
  end

  defp put(storage, x, material_name) do
    id = MaterialCatalog.material_id(material_name)
    Storage.put_solid_block(storage, Types.macro_index!({x, 0, 0}), NormalBlockData.new(id))
  end

  # 跑一 tick,返回 :light 层(读 light(x) = FieldLayer.get)。
  defp run(storage, opts \\ %{}) do
    region = line_region()
    context = KernelContext.new(region, 1, storage)
    {:cont, region, []} = LightPropagationKernel.tick(region, context, opts)
    layer = FieldRegion.get_layer(region, :light)
    fn x -> FieldLayer.get(layer, Types.macro_index!({x, 0, 0})) end
  end

  test "ember 发光源点亮自身 + 经空气向邻衰减传播(单调)" do
    # ember(light_emission 1500W → 满 255)在 0,其余空 cell(透明)。attenuation 0.7。
    light = Storage.empty(1, {0, 0, 0}) |> put(0, :ember) |> run()

    assert_in_delta light.(0), 255.0, 1.0e-3, "ember 源满亮 255"
    assert light.(1) > 0.0 and light.(1) < light.(0), "向 1 衰减传播"
    assert light.(2) > 0.0 and light.(2) < light.(1), "单调递减"
  end

  test "无光源 → :light 层全 0(惰性安全)" do
    light = Storage.empty(1, {0, 0, 0}) |> put(0, :stone) |> put(1, :stone) |> run()
    for x <- 0..4, do: assert(light.(x) == 0.0)
  end

  test "光敏元件(不透明 photo_sensor)相邻光源仍被照亮(接收照度)" do
    # ember 在 0,photo_sensor(不透明)在 1 → 1 接收照度被点亮(opacity 门控外传非受光)。
    light = Storage.empty(1, {0, 0, 0}) |> put(0, :ember) |> put(1, :photo_sensor) |> run()
    assert light.(1) > 0.0, "不透明光敏元件相邻光源被照亮"
  end

  test "不透明墙挡光:墙受光面亮、墙后暗" do
    # ember 在 0,stone(不透明)在 2,cell 1/3/4 空。光经 1 到达 2(受光),但 2 onward=0 → 3/4 暗。
    light =
      Storage.empty(1, {0, 0, 0})
      |> put(0, :ember)
      |> put(2, :stone)
      |> run()

    assert light.(0) > 0.0
    assert light.(1) > 0.0
    assert light.(2) > 0.0, "墙受光面被照亮"
    assert light.(3) == 0.0, "墙后暗"
    assert light.(4) == 0.0
  end

  test "热致白炽:高温 cell(无 light_emission)因热发光" do
    # iron(无 light_emission)在 0,设其温度 1500℃ → 热致 thermal_light>0 → 当光源。
    hot_raw = round(1500.0 * 65_536)

    storage =
      Storage.empty(1, {0, 0, 0})
      |> put(0, :iron)
      |> Storage.put_attribute_for_cell(Types.macro_index!({0, 0, 0}), "temperature", hot_raw)

    light = run(storage)
    assert light.(0) > 0.0, "高温铁因热致白炽发光(无 light_emission 也发光)"
  end

  test "model_card 声明形式属性(单调/确定/有界/遮挡)" do
    card = LightPropagationKernel.model_card()
    assert card.kernel_id == :light_propagation
    text = Enum.join(card.assumptions, " ")
    assert text =~ "单调衰减"
    assert text =~ "确定性"
    assert text =~ "遮挡"
    assert card.safety_valve.type == :flood_budget
  end
end
