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

  # 梯队2 step2.7c(BND-1):旧无状态向量 NIF diffuse_temperature/9 + propagate_electric_potential/4
  # 已删除(no dual-path)——场层本体常驻 Rust,统一走句柄版 diffuse_temperature_sim /
  # propagate_electric_potential_sim(原地演化 cell_sim)。

  # -------------------------------------------------------------------------
  # BND-1(梯队2 step2.7a):场层本体常驻 Rust ResourceArc<FieldLayerSim> 脚手架。
  # 句柄(reference)由 Elixir 持有,数据留 Rust。本步未接 FieldLayer(flip 在 2.7c)。
  # -------------------------------------------------------------------------

  @typedoc "Rust 常驻场层句柄(ResourceArc<FieldLayerSim>)。"
  @type cell_sim :: reference()

  @doc "新建一个常驻 Rust 的场层(quantization: \"float\" | \"integer\")。"
  @spec cell_sim_new(float(), float(), String.t()) :: cell_sim()
  def cell_sim_new(_baseline, _threshold, _quantization),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc "原地写绝对值到 macro_index(返回 :ok)。"
  @spec cell_sim_put(cell_sim(), 0..4095, float()) :: :ok
  def cell_sim_put(_sim, _macro_index, _value), do: :erlang.nif_error(:nif_not_loaded)

  @doc "读 macro_index 的绝对值。"
  @spec cell_sim_get(cell_sim(), 0..4095) :: float()
  def cell_sim_get(_sim, _macro_index), do: :erlang.nif_error(:nif_not_loaded)

  @doc "active cells(过 aabb inclusive + |delta| >= epsilon,按 idx 升序)。"
  @spec cell_sim_active_cells(cell_sim(), aabb(), float()) :: [temperature_cell()]
  def cell_sim_active_cells(_sim, _aabb, _epsilon), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  温度扩散句柄版(梯队2 step2.7b):原地演化 CellSim(返回 :ok),复用与 `diffuse_temperature`
  相同 stencil(逐位数值等价),数据不再每 tick 进出序列化(BND-1)。
  """
  @spec diffuse_temperature_sim(
          cell_sim(),
          [0..4095],
          aabb(),
          [thermal_properties()],
          float(),
          float(),
          float(),
          float()
        ) :: :ok
  def diffuse_temperature_sim(
        _sim,
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
  电势传播句柄版(梯队2 step2.7b):读 ionization_sim active(旧)→ 复用与
  `propagate_electric_potential` 相同计算 → 写 potential_sim(merge)+ ionization_sim
  (clear aabb 再 put)。逐位数值等价旧路径,数据留 Rust(BND-1)。返回 :ok。
  """
  @spec propagate_electric_potential_sim(
          cell_sim(),
          cell_sim(),
          [electric_source()],
          [entry()],
          aabb()
        ) :: :ok
  def propagate_electric_potential_sim(
        _potential_sim,
        _ionization_sim,
        _sources,
        _entries,
        _aabb
      ),
      do: :erlang.nif_error(:nif_not_loaded)
end
