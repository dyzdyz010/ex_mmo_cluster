defmodule SceneServer.Voxel.Field.NativeBackend.ElectricPotentialInput do
  @moduledoc """
  Native DTO encoder for electric potential propagation.

  Runtime source ownership and FieldLayer mutation stay in Elixir. This module
  freezes source points, current ionization values, and read-only electric
  projection facts for one native electric propagation step.
  """

  alias SceneServer.Voxel.Field.ParticipantProjection
  alias SceneServer.Voxel.Field.NativeBackend.ConductionPathInput
  alias SceneServer.Voxel.Types

  defstruct sources: [],
            entries: [],
            aabb: {{0, 0, 0}, {0, 0, 0}}

  @type source :: {0..4095, float()}
  @type t :: %__MODULE__{
          sources: [source()],
          entries: [ConductionPathInput.entry()],
          aabb: {{0..15, 0..15, 0..15}, {0..15, 0..15, 0..15}}
        }

  # 梯队2 step2.7c(BND-1):ionization 层本体常驻 Rust,`propagate_electric_potential_sim` 直读
  # ionization 句柄,故本 DTO **不再序列化 ionization_cells**——只冻结 sources / entries / aabb。
  @spec new(
          [map()],
          {{0..15, 0..15, 0..15}, {0..15, 0..15, 0..15}},
          ParticipantProjection.t()
        ) :: t()
  def new(source_points, aabb, %ParticipantProjection{} = projection)
      when is_list(source_points) do
    %__MODULE__{
      sources: sources(source_points, aabb, projection),
      entries: ConductionPathInput.conduction_entries(projection, aabb),
      aabb: aabb
    }
  end

  defp sources(source_points, aabb, %ParticipantProjection{} = projection) do
    source_points
    |> Enum.filter(fn source ->
      macro_index = macro_index(source)

      field_type(source) == :electric_potential and in_aabb?(macro_index, aabb) and
        ParticipantProjection.electric_conductive_cell?(projection, macro_index)
    end)
    |> Enum.reduce(%{}, fn source, acc ->
      macro_index = macro_index(source)
      value = source_value(source)

      Map.update(acc, macro_index, value, fn previous -> max(previous, value) end)
    end)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {macro_index, value} -> {macro_index, value * 1.0} end)
  end

  defp field_type(source), do: Map.get(source, :field_type, Map.get(source, "field_type"))
  defp source_value(source), do: Map.get(source, :value, Map.get(source, "value", 0.0)) * 1.0
  defp macro_index(source), do: Map.get(source, :macro_index, Map.get(source, "macro_index"))

  defp in_aabb?(macro_index, {{min_x, min_y, min_z}, {max_x, max_y, max_z}})
       when is_integer(macro_index) do
    {x, y, z} = Types.macro_coord!(macro_index)

    x >= min_x and x <= max_x and y >= min_y and y <= max_y and z >= min_z and z <= max_z
  rescue
    _ -> false
  end

  defp in_aabb?(_macro_index, _aabb), do: false
end
