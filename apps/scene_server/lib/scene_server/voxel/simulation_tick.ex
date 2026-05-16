defmodule SceneServer.Voxel.SimulationTick do
  @moduledoc """
  Phase 5.E per-chunk simulation tick scheduler state + helpers.

  ChunkProcess 在 `init/1` 时调用 `new/1` 注入配置中的 simulator 模块列表，
  并 schedule first tick (`100ms`)。每次 `handle_info(:simulation_tick, state)`
  收到调度信号时：

    1. 校验 lease / dirty_bounds / simulators 三个 fence；任一不满足则 skip。
    2. `run_tick/3` 依次调用每个 simulator 的 `tick/3`。
    3. 单 simulator 失败不阻塞其它 simulator；ChunkProcess emit
       `voxel_simulation_simulator_failed`，dirty_bounds 保留给下个 tick 重试。

  ## deterministic output_hash

  `output_hash/3` 由 ChunkProcess 在 tick 完成后计算，输入：

      hash(input_chunk_hash, dirty_bounds_truth, tick_seq, simulator_ids_truth)

  同输入 → 同输出，用于回归验证。
  """

  alias SceneServer.Voxel.DirtyMacroBounds
  alias SceneServer.Voxel.Hash

  defstruct tick_seq: 0,
            last_output_hash: 0,
            simulators: [],
            simulator_states: %{}

  @type t :: %__MODULE__{
          tick_seq: non_neg_integer(),
          last_output_hash: 0..0xFFFF_FFFF_FFFF_FFFF,
          simulators: [module()],
          simulator_states: %{optional(atom()) => term()}
        }

  @doc """
  Builds a fresh per-chunk SimulationTick state.

  `simulators` 是按调用顺序排列的 simulator 模块列表（实现 `SceneServer.Voxel.Simulator`
  behaviour）。Phase 5.E 默认空列表（框架就绪，未注 simulator）。
  """
  @spec new([module()]) :: t()
  def new(simulators) when is_list(simulators) do
    simulator_states =
      Map.new(simulators, fn module ->
        {simulator_id_or_module(module), nil}
      end)

    %__MODULE__{simulators: simulators, simulator_states: simulator_states}
  end

  @doc "Returns whether the scheduler has at least one simulator registered."
  @spec any_simulator?(t()) :: boolean()
  def any_simulator?(%__MODULE__{simulators: []}), do: false
  def any_simulator?(%__MODULE__{simulators: [_ | _]}), do: true

  @doc """
  Runs one tick across all registered simulators.

  Returns `{new_state, summary}` where `summary` is:

      %{
        cells_updated: non_neg_integer(),
        env_deltas: [{simulator_id, env_delta}],
        failures: [{simulator_id, reason}]
      }

  `failures` 上层 (ChunkProcess) 用来 emit `voxel_simulation_simulator_failed`。
  """
  @spec run_tick(t(), DirtyMacroBounds.t(), map()) :: {t(), map()}
  def run_tick(%__MODULE__{simulators: simulators} = state, %DirtyMacroBounds{} = dirty, env)
      when is_map(env) do
    {next_states, cells_updated, env_deltas, failures} =
      Enum.reduce(simulators, {state.simulator_states, 0, [], []}, fn module,
                                                                      {acc_states, acc_cells,
                                                                       acc_deltas, acc_failures} ->
        sim_id = simulator_id_or_module(module)
        prev_state = Map.get(acc_states, sim_id)

        case safe_tick(module, prev_state, dirty, env) do
          {:ok, new_state, %{cells_updated: cells, env_delta: env_delta}} ->
            {
              Map.put(acc_states, sim_id, new_state),
              acc_cells + cells,
              maybe_prepend_env_delta(acc_deltas, sim_id, env_delta),
              acc_failures
            }

          {:error, reason} ->
            # 失败保留旧 sim state；上层决定是否保留 dirty。
            {acc_states, acc_cells, acc_deltas, [{sim_id, reason} | acc_failures]}
        end
      end)

    summary = %{
      cells_updated: cells_updated,
      env_deltas: Enum.reverse(env_deltas),
      failures: Enum.reverse(failures)
    }

    next_state = %{
      state
      | simulator_states: next_states,
        tick_seq: state.tick_seq + 1
    }

    {next_state, summary}
  end

  @doc """
  Computes deterministic output_hash for this tick.

  输入：

    * `input_chunk_hash` —— tick 前 storage 的 `Codec.chunk_hash/1`（u64）
    * `dirty_bounds` —— 本 tick 消费的 dirty bounds（含 reason_flags）
    * `tick_seq` —— 本 tick 的 seq（tick 完成后的 seq；与 ChunkProcess.tick_seq 同步）
    * `simulator_ids` —— 参与本 tick 的 simulator id 列表（按调用顺序）
  """
  @spec output_hash(
          non_neg_integer(),
          DirtyMacroBounds.t(),
          non_neg_integer(),
          [atom()]
        ) :: 0..0xFFFF_FFFF_FFFF_FFFF
  def output_hash(input_chunk_hash, %DirtyMacroBounds{} = dirty, tick_seq, simulator_ids)
      when is_integer(input_chunk_hash) and is_integer(tick_seq) and is_list(simulator_ids) do
    {min_x, min_y, min_z} = dirty.min_macro
    {max_x, max_y, max_z} = dirty.max_macro

    simulator_payload =
      simulator_ids
      |> Enum.map(&Atom.to_string/1)
      |> Enum.intersperse("|")
      |> IO.iodata_to_binary()

    iodata = [
      <<input_chunk_hash::unsigned-big-integer-size(64)>>,
      <<min_x::unsigned-big-integer-size(8), min_y::unsigned-big-integer-size(8),
        min_z::unsigned-big-integer-size(8)>>,
      <<max_x::unsigned-big-integer-size(8), max_y::unsigned-big-integer-size(8),
        max_z::unsigned-big-integer-size(8)>>,
      <<dirty.reason_flags::unsigned-big-integer-size(16)>>,
      <<tick_seq::unsigned-big-integer-size(64)>>,
      <<byte_size(simulator_payload)::unsigned-big-integer-size(16)>>,
      simulator_payload
    ]

    Hash.digest64(iodata)
  end

  @doc "Returns simulator ids in calling order."
  @spec simulator_ids(t()) :: [atom()]
  def simulator_ids(%__MODULE__{simulators: simulators}) do
    Enum.map(simulators, &simulator_id_or_module/1)
  end

  @doc "Stores the last output_hash after a successful tick."
  @spec put_last_output_hash(t(), non_neg_integer()) :: t()
  def put_last_output_hash(%__MODULE__{} = state, hash)
      when is_integer(hash) and hash >= 0 do
    %{state | last_output_hash: hash}
  end

  # ---------------------------------------------------------------------------
  # helpers
  # ---------------------------------------------------------------------------

  defp simulator_id_or_module(module) when is_atom(module) do
    try do
      module.simulator_id()
    rescue
      UndefinedFunctionError -> module
    end
  end

  defp safe_tick(module, prev_state, dirty, env) do
    try do
      module.tick(prev_state, dirty, env)
    rescue
      UndefinedFunctionError ->
        {:error, :tick_not_implemented}

      exception ->
        {:error, {:simulator_raised, Exception.message(exception)}}
    catch
      kind, reason ->
        {:error, {:simulator_threw, kind, inspect(reason)}}
    end
  end

  defp maybe_prepend_env_delta(acc, _sim_id, nil), do: acc
  defp maybe_prepend_env_delta(acc, sim_id, env_delta), do: [{sim_id, env_delta} | acc]
end
