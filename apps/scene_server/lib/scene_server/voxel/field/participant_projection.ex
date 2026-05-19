defmodule SceneServer.Voxel.Field.ParticipantProjection do
  @moduledoc """
  Read-only field participant projection derived from voxel/object truth.

  This module is the boundary between chunk/refined/prefab truth and field
  kernels. Kernels consume projection facts such as electric face connectivity
  instead of querying prefab or object registries directly.

  The first slice implements electric projection only:

    * solid conductive macro cells expose all six faces as one connected body;
    * refined macro cells derive connectivity from conductive micro components;
    * empty/non-conductive cells expose no electric faces.
  """

  alias SceneServer.Voxel.MacroCellHeader
  alias SceneServer.Voxel.MaterialCatalog
  alias SceneServer.Voxel.MicroLayer
  alias SceneServer.Voxel.NormalBlockData
  alias SceneServer.Voxel.RefinedCellData
  alias SceneServer.Voxel.Storage
  alias SceneServer.Voxel.Types

  import Bitwise

  @fixed32_scale 65_536.0
  @min_channel_conductivity 1.0
  @faces [:x_neg, :x_pos, :y_neg, :y_pos, :z_neg, :z_pos]

  defstruct chunk_version: 0,
            material_catalog_version: 0,
            entries: %{}

  @type face :: :x_neg | :x_pos | :y_neg | :y_pos | :z_neg | :z_pos
  @type entry :: %{
          electric: %{
            conductive_faces: MapSet.t(face()),
            face_connections: MapSet.t({face(), face()}),
            conductivity: float(),
            dielectric_strength: float(),
            object_refs: [{non_neg_integer(), non_neg_integer()}]
          }
        }
  @type t :: %__MODULE__{
          chunk_version: non_neg_integer(),
          material_catalog_version: non_neg_integer(),
          entries: %{optional(non_neg_integer()) => entry()}
        }

  @doc "Builds a projection for the current chunk storage snapshot."
  @spec build(Storage.t()) :: t()
  def build(%Storage{} = storage) do
    storage = Storage.normalize!(storage)

    entries =
      storage.macro_headers
      |> Enum.with_index()
      |> Enum.reduce(%{}, fn {header, macro_index}, acc ->
        case build_entry(storage, header) do
          nil -> acc
          entry -> Map.put(acc, macro_index, entry)
        end
      end)

    %__MODULE__{
      chunk_version: storage.chunk_version,
      material_catalog_version: 0,
      entries: entries
    }
  end

  @doc "Returns true when a macro cell has any electric conductive face."
  @spec electric_conductive_cell?(t(), non_neg_integer()) :: boolean()
  def electric_conductive_cell?(%__MODULE__{} = projection, macro_index) do
    projection
    |> electric_faces(macro_index)
    |> MapSet.size()
    |> Kernel.>(0)
  end

  @doc "Returns true when a macro face has at least one conductive micro contact."
  @spec electric_face_conductive?(t(), non_neg_integer(), face()) :: boolean()
  def electric_face_conductive?(%__MODULE__{} = projection, macro_index, face)
      when face in @faces do
    projection
    |> electric_faces(macro_index)
    |> MapSet.member?(face)
  end

  @doc """
  Returns true when electric current can move through a macro cell.

  `:source` is a virtual entry face used by source cells. It can exit through
  any conductive face without requiring an incoming physical face.
  """
  @spec electric_faces_connected?(t(), non_neg_integer(), face() | :source, face()) :: boolean()
  def electric_faces_connected?(%__MODULE__{} = projection, macro_index, :source, exit_face)
      when exit_face in @faces do
    electric_face_conductive?(projection, macro_index, exit_face)
  end

  def electric_faces_connected?(%__MODULE__{} = projection, macro_index, face, face)
      when face in @faces do
    electric_face_conductive?(projection, macro_index, face)
  end

  def electric_faces_connected?(%__MODULE__{} = projection, macro_index, entry_face, exit_face)
      when entry_face in @faces and exit_face in @faces do
    projection
    |> electric_connections(macro_index)
    |> MapSet.member?(connection_key(entry_face, exit_face))
  end

  @doc "Reads an electric projection attribute in normalized float units."
  @spec electric_attribute(t(), non_neg_integer(), String.t(), float()) :: float()
  def electric_attribute(%__MODULE__{} = projection, macro_index, attr_name, fallback)
      when is_binary(attr_name) and is_number(fallback) do
    case Map.get(projection.entries, macro_index) do
      %{electric: electric} ->
        case attr_name do
          "electric_conductivity" -> electric.conductivity
          "dielectric_strength" -> electric.dielectric_strength
          _other -> fallback * 1.0
        end

      _other ->
        fallback * 1.0
    end
  end

  defp build_entry(storage, %MacroCellHeader{} = header) do
    cond do
      header.mode == MacroCellHeader.cell_mode_solid_block() ->
        build_solid_entry(storage, header)

      header.mode == MacroCellHeader.cell_mode_refined() ->
        build_refined_entry(storage, header)

      true ->
        nil
    end
  end

  defp build_solid_entry(storage, %MacroCellHeader{} = header) do
    case Enum.at(storage.normal_blocks, header.payload_index) do
      %NormalBlockData{material_id: material_id} ->
        conductivity = material_float(material_id, "electric_conductivity", 0.0)
        dielectric_strength = material_float(material_id, "dielectric_strength", 3.0)

        if conductivity >= @min_channel_conductivity do
          electric_entry(
            MapSet.new(@faces),
            all_face_connections(),
            conductivity,
            dielectric_strength,
            []
          )
        else
          nil
        end

      _other ->
        nil
    end
  end

  defp build_refined_entry(storage, %MacroCellHeader{} = header) do
    case Enum.at(storage.refined_cells, header.payload_index) do
      %RefinedCellData{} = cell ->
        conductive_slots = conductive_slots(cell.layers)
        components = connected_components(conductive_slots)
        component_faces = Enum.map(components, &component_faces/1)
        conductive_faces = component_faces |> Enum.reduce(MapSet.new(), &MapSet.union/2)
        face_connections = component_faces |> Enum.reduce(MapSet.new(), &add_face_connections/2)

        if MapSet.size(conductive_faces) > 0 do
          electric_entry(
            conductive_faces,
            face_connections,
            refined_conductivity(cell.layers),
            refined_dielectric_strength(cell.layers),
            refined_object_refs(cell.layers)
          )
        else
          nil
        end

      _other ->
        nil
    end
  end

  defp electric_entry(faces, connections, conductivity, dielectric_strength, object_refs) do
    %{
      electric: %{
        conductive_faces: faces,
        face_connections: connections,
        conductivity: conductivity,
        dielectric_strength: dielectric_strength,
        object_refs: object_refs
      }
    }
  end

  defp electric_faces(projection, macro_index) do
    case Map.get(projection.entries, macro_index) do
      %{electric: %{conductive_faces: faces}} -> faces
      _other -> MapSet.new()
    end
  end

  defp electric_connections(projection, macro_index) do
    case Map.get(projection.entries, macro_index) do
      %{electric: %{face_connections: connections}} -> connections
      _other -> MapSet.new()
    end
  end

  defp conductive_slots(layers) do
    layers
    |> Enum.filter(fn %MicroLayer{material_id: material_id} ->
      material_float(material_id, "electric_conductivity", 0.0) >= @min_channel_conductivity
    end)
    |> Enum.flat_map(&layer_slots/1)
    |> MapSet.new()
  end

  defp layer_slots(%MicroLayer{mask_words: mask_words}) do
    mask_words
    |> Enum.with_index()
    |> Enum.flat_map(fn {word, word_index} ->
      if word == 0 do
        []
      else
        for bit <- 0..63, band(word, bsl(1, bit)) != 0 do
          word_index * 64 + bit
        end
      end
    end)
  end

  defp connected_components(slots) do
    slots
    |> MapSet.to_list()
    |> do_connected_components(slots, [])
  end

  defp do_connected_components([], _remaining, acc), do: acc

  defp do_connected_components([slot | rest], remaining, acc) do
    if MapSet.member?(remaining, slot) do
      {component, remaining} = flood_component([slot], remaining, MapSet.new())
      rest = Enum.filter(rest, &MapSet.member?(remaining, &1))
      do_connected_components(rest, remaining, [component | acc])
    else
      do_connected_components(rest, remaining, acc)
    end
  end

  defp flood_component([], remaining, component), do: {component, remaining}

  defp flood_component([slot | queue], remaining, component) do
    cond do
      not MapSet.member?(remaining, slot) ->
        flood_component(queue, remaining, component)

      true ->
        remaining = MapSet.delete(remaining, slot)
        component = MapSet.put(component, slot)

        neighbors =
          slot
          |> neighboring_slots()
          |> Enum.filter(&MapSet.member?(remaining, &1))

        flood_component(queue ++ neighbors, remaining, component)
    end
  end

  defp neighboring_slots(slot) do
    {x, y, z} = Types.micro_coord!(slot)

    [
      {x - 1, y, z},
      {x + 1, y, z},
      {x, y - 1, z},
      {x, y + 1, z},
      {x, y, z - 1},
      {x, y, z + 1}
    ]
    |> Enum.filter(fn {nx, ny, nz} ->
      nx in 0..7 and ny in 0..7 and nz in 0..7
    end)
    |> Enum.map(&Types.micro_index!/1)
  end

  defp component_faces(component) do
    component
    |> Enum.reduce(MapSet.new(), fn slot, faces ->
      {x, y, z} = Types.micro_coord!(slot)

      faces
      |> maybe_put_face(x == 0, :x_neg)
      |> maybe_put_face(x == 7, :x_pos)
      |> maybe_put_face(y == 0, :y_neg)
      |> maybe_put_face(y == 7, :y_pos)
      |> maybe_put_face(z == 0, :z_neg)
      |> maybe_put_face(z == 7, :z_pos)
    end)
  end

  defp maybe_put_face(faces, true, face), do: MapSet.put(faces, face)
  defp maybe_put_face(faces, false, _face), do: faces

  defp add_face_connections(faces, acc) do
    face_list = MapSet.to_list(faces)

    Enum.reduce(face_list, acc, fn face_a, outer_acc ->
      Enum.reduce(face_list, outer_acc, fn face_b, inner_acc ->
        if face_a == face_b do
          inner_acc
        else
          MapSet.put(inner_acc, connection_key(face_a, face_b))
        end
      end)
    end)
  end

  defp all_face_connections do
    add_face_connections(MapSet.new(@faces), MapSet.new())
  end

  defp connection_key(face_a, face_b) do
    [face_a, face_b]
    |> Enum.sort_by(&face_rank/1)
    |> List.to_tuple()
  end

  defp face_rank(:x_neg), do: 0
  defp face_rank(:x_pos), do: 1
  defp face_rank(:y_neg), do: 2
  defp face_rank(:y_pos), do: 3
  defp face_rank(:z_neg), do: 4
  defp face_rank(:z_pos), do: 5

  defp refined_conductivity(layers) do
    layers
    |> Enum.map(fn %MicroLayer{material_id: material_id} ->
      material_float(material_id, "electric_conductivity", 0.0)
    end)
    |> Enum.max(fn -> 0.0 end)
  end

  defp refined_dielectric_strength(layers) do
    layers
    |> Enum.map(fn %MicroLayer{material_id: material_id} ->
      material_float(material_id, "dielectric_strength", 3.0)
    end)
    |> Enum.min(fn -> 3.0 end)
  end

  defp refined_object_refs(layers) do
    layers
    |> Enum.reject(&(&1.owner_object_id == 0))
    |> Enum.map(&{&1.owner_object_id, &1.owner_part_id})
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp material_float(material_id, attr_name, fallback) do
    material_id
    |> MaterialCatalog.default_attribute_value(attr_name, round(fallback * @fixed32_scale))
    |> Kernel./(@fixed32_scale)
  end
end
