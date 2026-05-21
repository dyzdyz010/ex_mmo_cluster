defmodule SceneServer.Voxel.Field.NativeBackend.ConductionPathInput do
  @moduledoc """
  Native DTO encoder for the conduction path field solver.

  ParticipantProjection remains the field-facts boundary; this module owns the
  Rustler ABI shape for the native conduction path kernel.
  """

  alias SceneServer.Voxel.Field.{FieldLayer, ParticipantProjection}
  alias SceneServer.Voxel.Types

  import Bitwise

  @faces [:x_neg, :x_pos, :y_neg, :y_pos, :z_neg, :z_pos]
  @face_codes %{x_neg: 0, x_pos: 1, y_neg: 2, y_pos: 3, z_neg: 4, z_pos: 5}

  defstruct entries: [],
            aabb: {{0, 0, 0}, {0, 0, 0}},
            source_macro_index: 0,
            target_macro_index: 0,
            source_value: 0.0,
            ionization_cells: [],
            max_frontier: 1

  @type face_contacts ::
          {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer(),
           non_neg_integer(), non_neg_integer()}
  @type component :: {non_neg_integer(), face_contacts()}
  @type entry :: {0..4095, float(), float(), [component()]}
  @type aabb :: {{0..15, 0..15, 0..15}, {0..15, 0..15, 0..15}}
  @type t :: %__MODULE__{
          entries: [entry()],
          aabb: aabb(),
          source_macro_index: 0..4095,
          target_macro_index: 0..4095,
          source_value: float(),
          ionization_cells: [{0..4095, float()}],
          max_frontier: pos_integer()
        }

  @spec new(
          ParticipantProjection.t(),
          {{0..15, 0..15, 0..15}, {0..15, 0..15, 0..15}},
          0..4095,
          0..4095,
          number(),
          FieldLayer.t(),
          pos_integer()
        ) :: t()
  def new(
        %ParticipantProjection{} = projection,
        aabb,
        source_macro_index,
        target_macro_index,
        source_value,
        %FieldLayer{} = ionization_layer,
        max_frontier
      ) do
    %__MODULE__{
      entries: conduction_entries(projection, aabb),
      aabb: aabb,
      source_macro_index: source_macro_index,
      target_macro_index: target_macro_index,
      source_value: source_value * 1.0,
      ionization_cells: ionization_cells(ionization_layer, aabb),
      max_frontier: max(max_frontier, 1)
    }
  end

  @spec conduction_entries(ParticipantProjection.t(), nil | aabb()) :: [entry()]
  def conduction_entries(%ParticipantProjection{entries: entries}, aabb \\ nil) do
    entries
    |> Enum.filter(fn {macro_index, _entry} -> in_aabb?(macro_index, aabb) end)
    |> Enum.flat_map(fn
      {macro_index, %{electric: electric}} ->
        components = Enum.map(electric.components, &native_component/1)

        if components == [] do
          []
        else
          [
            {
              macro_index,
              electric.conductivity * 1.0,
              electric.dielectric_strength * 1.0,
              components
            }
          ]
        end

      _other ->
        []
    end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp in_aabb?(_macro_index, nil), do: true

  defp in_aabb?(macro_index, {{min_x, min_y, min_z}, {max_x, max_y, max_z}})
       when is_integer(macro_index) do
    {x, y, z} = Types.macro_coord!(macro_index)

    x >= min_x and x <= max_x and y >= min_y and y <= max_y and z >= min_z and z <= max_z
  rescue
    _ -> false
  end

  defp in_aabb?(_macro_index, _aabb), do: false

  defp ionization_cells(%FieldLayer{} = ionization_layer, aabb) do
    ionization_layer
    |> FieldLayer.active_cells(aabb, 0)
    |> Enum.map(fn {macro_index, value} -> {macro_index, value * 1.0} end)
  end

  defp native_component(%{faces: faces, face_contacts: face_contacts}) do
    face_mask =
      Enum.reduce(faces, 0, fn face, acc ->
        bor(acc, bsl(1, Map.fetch!(@face_codes, face)))
      end)

    contacts =
      @faces
      |> Enum.map(fn face ->
        face_contacts
        |> Map.get(face, MapSet.new())
        |> contact_mask()
      end)
      |> List.to_tuple()

    {face_mask, contacts}
  end

  defp contact_mask(contacts) do
    Enum.reduce(contacts, 0, fn {first_axis, second_axis}, acc ->
      bor(acc, bsl(1, first_axis * 8 + second_axis))
    end)
  end
end
