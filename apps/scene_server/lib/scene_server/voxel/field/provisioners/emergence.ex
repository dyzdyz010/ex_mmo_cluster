defmodule SceneServer.Voxel.Field.Provisioners.Emergence do
  @moduledoc """
  涌现场 provisioner:chunk 内有「正在 source / 正在反应」的内容时,起一个
  `[light_propagation, reaction]` region —— 权威光传播 + 光/热/化学反应。同 tick
  光层先写后读 gate 光敏反应(光 kernel 排反应前),`ReactionKernel` 同时注入材料
  `heat_output`(ember/火炬)与 `emit_heat`(燃烧/光致放热)的热到 truth。

  **「活性材料」取属性派生分类**(决策稿 §6):因所有反应被能量/光 gate、无常温
  自发反应,且 `FieldTickWorker` 每 tick 无条件 fanout 0x73,「活性」落到**材料的
  本征属性是否 source 光/热**——一个材料 active(发光/放热)当且仅当其默认属性满足
    * `light_emission > 0`(发光体,如 glowstone / ember),或
    * `heat_output > 0`(热源,如 ember / 火炬),或
    * 默认温度偏离环境 20℃(本征炽热材料,如未来设熔点温度的 lava)。
  chunk 含任一这样的材料即 active。冷惰性 chunk(plain stone/iron/…)→ 无 region。

  分类纯 O(1) 材料默认查(不逐 cell 走 `effective_attribute_at`——那是 O(n) 的
  `Enum.at`,全 chunk 扫成 O(n²))。region **不覆盖整 chunk**,而是 emergent cell 的
  bounding box 各轴扩一个本地半径(同温度异常 provisioning 的 local AABB 惯例)——
  全 chunk AABB 会让 `[light_propagation, reaction]` 每 tick 在 16³=4096 cell 上跑成
  O(n²) 阻塞 worker。region **自发现光源**(`LightPropagationKernel` 从 region storage
  取 `light_emission` / 热致 ≥Draper 源)、反应读 truth,故**无需 source_points**;光/热
  在 AABB 内传播到哪,被加热/照亮的惰性邻居就在那参与反应。

  注:① 光只在本地半径内传播(远距离照明不自动 provision,v1 取本地交互泡折中
  cost/reach);② 动态续命(光源移除后自维持燃烧、仅被邻居加热的格)留待 thermal
  provisioner + field-commit 触发重 sweep(step5)。两者均待 kernel 逐 cell O(1)
  访问优化后可放宽。

  世界内容驱动场 provisioning 的第二个 provisioner(电路之后),让光 / 化学 / 光门 /
  光合在有机玩法里真跑、并把 `:light` / `:light_color` 0x73 真流到客户端。见
  `docs/2026-06-23-world-content-driven-field-provisioning.md`。
  """

  @behaviour SceneServer.Voxel.Field.FieldProvisioner

  alias SceneServer.Voxel.Field.Kernels.LightPropagationKernel
  alias SceneServer.Voxel.Field.Kernels.ReactionKernel
  alias SceneServer.Voxel.MacroCellHeader
  alias SceneServer.Voxel.MaterialCatalog
  alias SceneServer.Voxel.Storage
  alias SceneServer.Voxel.Types

  @ambient_celsius 20.0
  @anomaly_threshold_celsius 0.5
  # temperature 属性的全局默认(20℃ 的 fixed32),materials 未覆写时回退此值 → 无热异常。
  @ambient_temperature_raw 1_310_720
  # emergent cell bbox 各轴外扩半径(本地交互泡;光/热在此泡内传播)。chunk 边界内 clamp。
  @emergence_radius 6
  @chunk_max_macro 15

  @impl true
  def telemetry_event, do: "voxel_emergence_provision"

  @impl true
  def source_key(%{logical_scene_id: scene_id, chunk_coord: chunk_coord}) do
    {:emergence, scene_id, chunk_coord}
  end

  @impl true
  def detect(%{storage: %Storage{} = storage, chunk_coord: chunk_coord}) do
    case emergent_aabb(storage) do
      nil ->
        {:inactive, :no_emergent_content, %{}}

      aabb ->
        attrs = %{
          chunk_coord: chunk_coord,
          aabb: aabb,
          kernels: [
            %{id: :light_propagation, module: LightPropagationKernel, opts: %{}},
            %{id: :reaction, module: ReactionKernel, opts: %{}}
          ],
          max_ticks: nil
        }

        {:active, attrs, %{aabb: aabb}}
    end
  end

  def detect(_context), do: {:inactive, :no_storage, %{}}

  @doc "活性谓词:chunk 是否含本征 source 光/热的材料(有则 emergent_aabb 非 nil)。"
  @spec emergent_content?(Storage.t()) :: boolean()
  def emergent_content?(%Storage{} = storage), do: emergent_aabb(storage) != nil
  def emergent_content?(_storage), do: false

  @doc "材料是否本征 source 光/热(发光体 / 热源 / 本征炽热)。属性派生,无 id 白名单。"
  @spec emergent_material?(non_neg_integer()) :: boolean()
  def emergent_material?(material_id) do
    material_default(material_id, "light_emission", 0) > 0 or
      material_default(material_id, "heat_output", 0) > 0 or
      abs(
        material_default(material_id, "temperature", @ambient_temperature_raw) /
          MaterialCatalog.fixed32_scale() - @ambient_celsius
      ) >= @anomaly_threshold_celsius
  end

  # 单 O(n) pass 扫 macro_headers:solid 且材料本征 source 光/热的 cell,聚成 bounding
  # box,各轴外扩 @emergence_radius 并 clamp 到 chunk。无 emergent cell → nil。
  defp emergent_aabb(%Storage{macro_headers: headers, normal_blocks: blocks}) do
    solid_mode = MacroCellHeader.cell_mode_solid_block()
    blocks_tuple = List.to_tuple(blocks)

    headers
    |> Enum.with_index()
    |> Enum.reduce(nil, fn {header, macro_index}, acc ->
      with true <- header.mode == solid_mode,
           block when not is_nil(block) <- safe_elem(blocks_tuple, header.payload_index),
           true <- emergent_material?(block.material_id) do
        {x, y, z} = Types.macro_coord!(macro_index)
        expand_bounds(acc, x, y, z)
      else
        _ -> acc
      end
    end)
    |> clamp_and_pad()
  end

  defp expand_bounds(nil, x, y, z), do: {{x, y, z}, {x, y, z}}

  defp expand_bounds({{min_x, min_y, min_z}, {max_x, max_y, max_z}}, x, y, z) do
    {{min(min_x, x), min(min_y, y), min(min_z, z)}, {max(max_x, x), max(max_y, y), max(max_z, z)}}
  end

  defp clamp_and_pad(nil), do: nil

  defp clamp_and_pad({{min_x, min_y, min_z}, {max_x, max_y, max_z}}) do
    {
      {pad_low(min_x), pad_low(min_y), pad_low(min_z)},
      {pad_high(max_x), pad_high(max_y), pad_high(max_z)}
    }
  end

  defp pad_low(v), do: max(0, v - @emergence_radius)
  defp pad_high(v), do: min(@chunk_max_macro, v + @emergence_radius)

  defp safe_elem(tuple, index)
       when is_integer(index) and index >= 0 and index < tuple_size(tuple),
       do: elem(tuple, index)

  defp safe_elem(_tuple, _index), do: nil

  defp material_default(material_id, attr_name, fallback) do
    MaterialCatalog.default_attribute_value(material_id, attr_name, fallback)
  end
end
