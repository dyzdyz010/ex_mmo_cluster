defmodule SceneServer.Native.FieldKernel do
  @moduledoc """
  Rustler binding for pure, chunk-local field computation kernels.

  This is the native boundary for field math that is deterministic, read-only,
  and bounded by one chunk-local AABB. Authority, process lifecycle,
  FieldLayer mutation, voxel truth writes, and observe effects remain in
  Elixir.
  """

  use Rustler, otp_app: :scene_server, crate: "field_kernel"

  @type aabb :: {{0..15, 0..15, 0..15}, {0..15, 0..15, 0..15}}
  @type face_contacts ::
          {non_neg_integer(), non_neg_integer(), non_neg_integer(), non_neg_integer(),
           non_neg_integer(), non_neg_integer()}
  @type component :: {non_neg_integer(), face_contacts()}
  @type entry :: {0..4095, float(), float(), [component()]}
  @type discharge_cell :: {0..4095, float(), float()}
  @type temperature_cell :: {0..4095, float()}
  @type thermal_properties :: {0..4095, integer(), integer(), integer()}
  @type electric_source :: {0..4095, float()}

  @doc """
  Finds a deterministic conductive path inside one chunk-local inclusive AABB.
  """
  @spec find_conduction_path(
          [entry()],
          aabb(),
          0..4095,
          0..4095,
          float(),
          [{0..4095, float()}],
          pos_integer()
        ) ::
          {:ok, [0..4095]}
          | {:error,
             :source_not_conductive
             | :target_not_conductive
             | :frontier_exhausted
             | :unreachable}
  def find_conduction_path(
        _entries,
        _aabb,
        _source_macro_index,
        _target_macro_index,
        _source_value,
        _ionization_cells,
        _max_frontier
      ),
      do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Finds a deterministic dielectric-breakdown path inside one chunk-local AABB.
  """
  @spec find_discharge_path(
          [discharge_cell()],
          aabb(),
          0..4095,
          0..4095,
          float(),
          [{0..4095, float()}],
          pos_integer()
        ) ::
          {:ok, [0..4095]}
          | {:error, :frontier_exhausted | :no_discharge_path}
  def find_discharge_path(
        _cells,
        _aabb,
        _source_macro_index,
        _target_macro_index,
        _source_value,
        _ionization_cells,
        _max_frontier
      ),
      do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Computes sparse temperature deltas for one deterministic diffusion tick.
  """
  @spec diffuse_temperature(
          [temperature_cell()],
          [0..4095],
          aabb(),
          [thermal_properties()],
          float(),
          float(),
          float(),
          float()
        ) :: [temperature_cell()]
  def diffuse_temperature(
        _cells,
        _candidates,
        _aabb,
        _thermal_properties,
        _diffusion_seconds,
        _ambient_dt_seconds,
        _ambient_loss_per_second,
        _cell_size_meters
      ),
      do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  Propagates electric potential and ionization for one chunk-local field tick.
  """
  @spec propagate_electric_potential(
          [electric_source()],
          [entry()],
          aabb(),
          [temperature_cell()]
        ) :: {[temperature_cell()], [temperature_cell()]}
  def propagate_electric_potential(
        _sources,
        _entries,
        _aabb,
        _ionization_cells
      ),
      do: :erlang.nif_error(:nif_not_loaded)
end
