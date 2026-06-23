defmodule SceneServer.Voxel.Field.Provisioners.ElectricCircuit do
  @moduledoc """
  电路场 provisioner:chunk 内有 power source + load 且构成闭合回路时,起一个
  `[circuit_current]` region。世界内容驱动场 provisioning 的**第一个** provisioner
  —— 本是 `ChunkProcess` 里硬编码的 auto_circuit,抽成统一 `FieldProvisioner` 契约的
  实现(探测/regions 规格逐字节保持;遥测事件名仍 `voxel_auto_circuit_refreshed`)。

  探测纯函数式(只读 `ParticipantProjection`);ensure/release/遥测留在 `ChunkProcess`
  的通用 sweep。
  """

  @behaviour SceneServer.Voxel.Field.FieldProvisioner

  alias SceneServer.Voxel.Field.CircuitComponentAnalysis
  alias SceneServer.Voxel.Field.FieldRegion
  alias SceneServer.Voxel.Field.Kernels.CircuitCurrentKernel
  alias SceneServer.Voxel.Field.ParticipantProjection
  alias SceneServer.Voxel.MaterialCatalog
  alias SceneServer.Voxel.Types

  @impl true
  def telemetry_event, do: "voxel_auto_circuit_refreshed"

  @impl true
  def source_key(%{logical_scene_id: scene_id, chunk_coord: chunk_coord}) do
    {:auto_circuit, scene_id, chunk_coord}
  end

  @impl true
  def detect(%{projection: projection, chunk_coord: chunk_coord}) do
    aabb = auto_circuit_aabb()
    source_points = auto_circuit_source_points(projection, aabb)
    load_count = auto_circuit_role_count(projection, aabb, :load)

    cond do
      source_points == [] ->
        {:inactive, :no_power_source,
         %{source_count: 0, load_count: load_count, closed_circuit_count: 0}}

      load_count == 0 ->
        {:inactive, :no_load,
         %{source_count: length(source_points), load_count: 0, closed_circuit_count: 0}}

      true ->
        # 只有 source + load 都在才计闭合回路——这一步建 FieldRegion → FieldLayer →
        # field_kernel NIF。提前短路(原 storage_has_auto_circuit_roles? 的 `and` 短路语义)
        # 避免无电内容的 chunk 在每次 subscribe/sweep 白调 NIF(否则 gate/auth 等只缓存
        # _build、无 Rust 的 job 在订阅普通 chunk 时撞 undefined NIF)。
        closed_circuit_count =
          auto_circuit_closed_circuit_count(projection, aabb, chunk_coord, source_points)

        detail = %{
          source_count: length(source_points),
          load_count: load_count,
          closed_circuit_count: closed_circuit_count
        }

        if closed_circuit_count == 0 do
          {:inactive, :no_closed_circuit, detail}
        else
          attrs = %{
            chunk_coord: chunk_coord,
            aabb: aabb,
            kernels: [auto_circuit_kernel_spec()],
            source_points: source_points,
            max_ticks: nil,
            source_points_mode: :replace
          }

          {:active, attrs, detail}
        end
    end
  end

  # --- 以下探测助手逐字节抽自原 ChunkProcess auto_circuit_*。 ---

  defp auto_circuit_kernel_spec do
    %{
      id: :circuit_current,
      module: CircuitCurrentKernel,
      opts: %{
        current_limit_amps: MaterialCatalog.power_source_defaults().current_limit_amps
      }
    }
  end

  defp auto_circuit_closed_circuit_count(projection, aabb, chunk_coord, source_points) do
    region =
      FieldRegion.new(%{
        region_id: 0,
        chunk_coord: chunk_coord,
        aabb: aabb,
        kernels: [auto_circuit_kernel_spec()],
        source_points: source_points
      })

    region
    |> CircuitComponentAnalysis.active_circuit_components(projection)
    |> length()
  end

  defp auto_circuit_source_points(projection, aabb) do
    voltage = MaterialCatalog.power_source_defaults().voltage

    aabb
    |> auto_circuit_aabb_macro_indices()
    |> Enum.filter(&ParticipantProjection.electric_role?(projection, &1, :source))
    |> Enum.map(fn macro_index ->
      %{
        macro_index: macro_index,
        field_type: :electric_potential,
        source_mode: :persistent,
        value: voltage
      }
    end)
  end

  defp auto_circuit_role_count(projection, aabb, role) do
    aabb
    |> auto_circuit_aabb_macro_indices()
    |> Enum.count(&ParticipantProjection.electric_role?(projection, &1, role))
  end

  defp auto_circuit_aabb, do: {{0, 0, 0}, {15, 15, 15}}

  defp auto_circuit_aabb_macro_indices({{min_x, min_y, min_z}, {max_x, max_y, max_z}}) do
    for x <- min_x..max_x, y <- min_y..max_y, z <- min_z..max_z do
      Types.macro_index!({x, y, z})
    end
  end
end
