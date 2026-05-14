defmodule SceneServer.Voxel.Field.DevFieldCreate do
  @moduledoc """
  Dev-only helper: creates a default temperature FieldRegion on a chunk so the
  field debug overlay can be smoke-tested without a running game session.

  Called from `AuthServerWeb.IngameController.voxel_dev_field_create/2` via
  dynamic dispatch (same pattern as `WorldServer.Voxel.DevSeed`).
  """

  alias SceneServer.Voxel.{ChunkDirectory, ChunkProcess}

  @default_max_ticks 600
  @default_source_value 500.0

  @doc """
  Creates a temperature FieldRegion on the named chunk and returns a summary.

  Options:
    * `:logical_scene_id` (default 1)
    * `:chunk_coord`      `{cx, cy, cz}` (default `{0, 0, 0}`)
    * `:max_ticks`        (default 600 = 60 s at 10 Hz)
    * `:source_value`     heat-source temperature °C (default 500.0)
  """
  @spec create_dev_region(keyword()) :: {:ok, map()} | {:error, term()}
  def create_dev_region(opts \\ []) do
    logical_scene_id = Keyword.get(opts, :logical_scene_id, 1)
    chunk_coord = Keyword.get(opts, :chunk_coord, {0, 0, 0})
    max_ticks = Keyword.get(opts, :max_ticks, @default_max_ticks)
    source_value = Keyword.get(opts, :source_value, @default_source_value)

    with {:ok, chunk_pid} <-
           ChunkDirectory.ensure_chunk(%{
             logical_scene_id: logical_scene_id,
             chunk_coord: chunk_coord
           }),
         {:ok, region_id} <-
           ChunkProcess.create_field_region(
             chunk_pid,
             build_attrs(chunk_coord, source_value, max_ticks)
           ) do
      {cx, cy, cz} = chunk_coord

      {:ok,
       %{
         region_id: region_id,
         logical_scene_id: logical_scene_id,
         chunk_coord: %{x: cx, y: cy, z: cz},
         field_types: ["temperature"],
         max_ticks: max_ticks,
         source_value: source_value
       }}
    end
  end

  defp build_attrs(chunk_coord, source_value, max_ticks) do
    # Centre of the chunk (macro index 7 + 7*16 + 7*256 = 1911)
    centre_index = 7 + 7 * 16 + 7 * 256

    %{
      chunk_coord: chunk_coord,
      aabb: {{0, 0, 0}, {15, 15, 15}},
      field_types: [:temperature],
      source_points: [
        %{macro_index: centre_index, field_type: :temperature, value: source_value}
      ],
      max_ticks: max_ticks
    }
  end
end
