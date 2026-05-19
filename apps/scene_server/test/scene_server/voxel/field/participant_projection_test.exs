defmodule SceneServer.Voxel.Field.ParticipantProjectionTest do
  use ExUnit.Case, async: true

  alias SceneServer.Voxel.{AttributeCatalog, NormalBlockData, Storage, Types}
  alias SceneServer.Voxel.Field.ParticipantProjection

  @iron 5
  @wood 3

  setup do
    case start_supervised({AttributeCatalog, []}) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  test "solid conductive macro exposes all electric faces as connected" do
    projection =
      Storage.new(7, {0, 0, 0})
      |> put_solid({0, 0, 0}, @iron)
      |> ParticipantProjection.build()

    macro_index = Types.macro_index!({0, 0, 0})

    assert ParticipantProjection.electric_conductive_cell?(projection, macro_index)
    assert ParticipantProjection.electric_face_conductive?(projection, macro_index, :x_neg)
    assert ParticipantProjection.electric_face_conductive?(projection, macro_index, :x_pos)

    assert ParticipantProjection.electric_faces_connected?(
             projection,
             macro_index,
             :x_neg,
             :x_pos
           )

    assert ParticipantProjection.electric_faces_connected?(
             projection,
             macro_index,
             :source,
             :z_pos
           )
  end

  test "broken refined prefab conductor exposes conductive faces but no face bridge" do
    projection =
      Storage.new(7, {0, 0, 0})
      |> put_refined_conductor({0, 0, 0}, [
        Types.micro_index!({0, 3, 3}),
        Types.micro_index!({7, 3, 3})
      ])
      |> ParticipantProjection.build()

    macro_index = Types.macro_index!({0, 0, 0})

    assert ParticipantProjection.electric_conductive_cell?(projection, macro_index)
    assert ParticipantProjection.electric_face_conductive?(projection, macro_index, :x_neg)
    assert ParticipantProjection.electric_face_conductive?(projection, macro_index, :x_pos)

    refute ParticipantProjection.electric_faces_connected?(
             projection,
             macro_index,
             :x_neg,
             :x_pos
           )

    assert ParticipantProjection.electric_object_refs(projection, macro_index) == [
             %{owner_object_id: 42, owner_part_id: 3}
           ]
  end

  test "connected refined prefab conductor bridges opposite electric faces" do
    projection =
      Storage.new(7, {0, 0, 0})
      |> put_refined_conductor(
        {0, 0, 0},
        Enum.map(0..7, &Types.micro_index!({&1, 3, 3}))
      )
      |> ParticipantProjection.build()

    macro_index = Types.macro_index!({0, 0, 0})

    assert ParticipantProjection.electric_conductive_cell?(projection, macro_index)

    assert ParticipantProjection.electric_faces_connected?(
             projection,
             macro_index,
             :x_neg,
             :x_pos
           )

    refute ParticipantProjection.electric_faces_connected?(
             projection,
             macro_index,
             :y_neg,
             :y_pos
           )
  end

  test "reachable electric contacts stay on the component entered through the shared face" do
    projection =
      Storage.new(7, {0, 0, 0})
      |> put_refined_conductor(
        {0, 0, 0},
        [Types.micro_index!({0, 1, 1})] ++
          Enum.map(0..7, &Types.micro_index!({&1, 6, 6}))
      )
      |> ParticipantProjection.build()

    macro_index = Types.macro_index!({0, 0, 0})

    assert ParticipantProjection.electric_face_contacts(projection, macro_index, :x_neg) ==
             MapSet.new([{1, 1}, {6, 6}])

    assert ParticipantProjection.electric_reachable_face_contacts(
             projection,
             macro_index,
             :x_neg,
             MapSet.new([{1, 1}]),
             :x_pos
           ) == MapSet.new()

    assert ParticipantProjection.electric_reachable_face_contacts(
             projection,
             macro_index,
             :x_neg,
             MapSet.new([{6, 6}]),
             :x_pos
           ) == MapSet.new([{6, 6}])
  end

  test "non-conductive refined prefab material does not expose electric faces" do
    projection =
      Storage.new(7, {0, 0, 0})
      |> Storage.put_micro_blocks(
        {0, 0, 0},
        Enum.map(0..7, fn x ->
          {Types.micro_index!({x, 3, 3}), %{material_id: @wood, health: 100}}
        end)
      )
      |> ParticipantProjection.build()

    macro_index = Types.macro_index!({0, 0, 0})

    refute ParticipantProjection.electric_conductive_cell?(projection, macro_index)
    refute ParticipantProjection.electric_face_conductive?(projection, macro_index, :x_neg)

    refute ParticipantProjection.electric_faces_connected?(
             projection,
             macro_index,
             :x_neg,
             :x_pos
           )
  end

  defp put_solid(storage, coord, material_id) do
    Storage.put_solid_block(storage, coord, NormalBlockData.new(material_id))
  end

  defp put_refined_conductor(storage, coord, slots) do
    Storage.put_micro_blocks(
      storage,
      coord,
      Enum.map(slots, fn slot ->
        {slot,
         %{
           material_id: @iron,
           health: 100,
           owner_object_id: 42,
           owner_part_id: 3
         }}
      end)
    )
  end
end
