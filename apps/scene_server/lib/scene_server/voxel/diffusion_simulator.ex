defmodule SceneServer.Voxel.DiffusionSimulator do
  @moduledoc """
  Phase 5.F 通用扩散 simulator（3D 7-stencil，macro 粒度）。

  本 simulator 参数化 `attribute_name` (`"temperature"` / `"moisture"`)、`alpha`
  和 `dt`，从而单一模块支持多 attribute（按草案 F-2 推荐方案）。

  ## 算法

      ∂T/∂t = α × ∇²T

      离散化：
      T'(x,y,z) = T(x,y,z) + α × dt × (
        T(x-1,y,z) + T(x+1,y,z) +
        T(x,y-1,z) + T(x,y+1,z) +
        T(x,y,z-1) + T(x,y,z+1) -
        6 × T(x,y,z)
      )

  - 字段语义复用既有 `MacroEnvironmentSummary.current_temperature /
    current_moisture`，i16 raw delta（相对 catalog default）。simulator 在 i16
    raw 域上做扩散；Phase 5.D `effective_attribute_at` 在外侧仍把 L1 base +
    L5 delta sum 起来。
  - 边界处理：拉模式邻 chunk + Neumann fallback（草案 F-3 推荐）。`env.neighbor_lookup`
    为 `nil` 或邻 chunk 不可读时退化为绝热（邻居视为同温 → 贡献 0）。
  - α / dt 全部从 simulator 配置取，**Phase 5.F 不接 catalog thermal_conductivity
    动态查询**（草案 §2.1 推荐 v1 α 从配置；v2 可改为 per-cell α from effective
    attribute）。

  ## simulator_id

  动态从 `attribute_name` 派生：

      "temperature" → :diffusion_temperature
      "moisture"    → :diffusion_moisture

  由于 `SceneServer.Voxel.SimulationTick.simulator_id_or_module/1` 调用
  `module.simulator_id()`（无参数 0-arity），本模块的 `simulator_id/0` 默认
  返回 `:diffusion_temperature`。多实例注册时，`SimulationTick.new/1` 接受
  的是 module 列表；本 Phase 5.F 通过 `{module, config}` 二元 tuple 模式
  在 ChunkProcess 解析为多个独立 simulator 实例（见 `chunk_process.ex` 的
  `resolve_simulators/1`）。

  ## tick/3 (behaviour) 与 tick/4 (with config)

    * `tick/3` —— Simulator behaviour 必需的回调。state 是 per-simulator 的
      持久 state（本 simulator 无状态需求，仅返回 nil 或 prev_state）。
      Phase 5.E 框架默认通过 `module.tick(state, dirty, env)` 调用，所以
      `state` 中需要携带 config。为支持多实例同模块，ChunkProcess 在
      simulator_states 中注入 `{:configured, %DiffusionSimulator{}}` 作为初始
      state；首次调用时 simulator 也会从 env[:diffusion_config_<id>] 兜底。
    * `tick/4` —— 直接传入 config 的纯函数版本，方便单测。
  """

  @behaviour SceneServer.Voxel.Simulator

  alias SceneServer.Voxel.DirtyMacroBounds
  alias SceneServer.Voxel.Hash
  alias SceneServer.Voxel.Types

  defstruct attribute_name: "temperature",
            alpha: 0.05,
            dt: 0.1

  @type t :: %__MODULE__{
          attribute_name: String.t(),
          alpha: float(),
          dt: float()
        }

  @i16_min -0x8000
  @i16_max 0x7FFF
  @no_index 0xFFFF_FFFF

  @doc """
  Returns the default simulator id atom.

  Note: when registering multiple DiffusionSimulator instances (one per
  attribute), the actual id used by SimulationTick is computed via
  `simulator_id_for/1` from the configured attribute_name.
  """
  @impl true
  @spec simulator_id() :: atom()
  def simulator_id, do: :diffusion_temperature

  @doc "Returns the simulator id for a given configured DiffusionSimulator struct."
  @spec simulator_id_for(t()) :: atom()
  def simulator_id_for(%__MODULE__{attribute_name: "temperature"}), do: :diffusion_temperature
  def simulator_id_for(%__MODULE__{attribute_name: "moisture"}), do: :diffusion_moisture

  def simulator_id_for(%__MODULE__{attribute_name: name}) when is_binary(name) do
    String.to_atom("diffusion_" <> name)
  end

  @doc """
  Behaviour callback. Reads the configured DiffusionSimulator from `state` (if
  it's a struct) or from `env[:diffusion_config]` as a fallback. If neither is
  set, defaults to the temperature config.
  """
  @impl true
  @spec tick(term(), DirtyMacroBounds.t(), map()) ::
          {:ok, term(), %{cells_updated: non_neg_integer(), env_delta: map() | nil}}
          | {:error, atom()}
  def tick(state, dirty, env) do
    config = resolve_config(state, env)
    tick(state, dirty, env, config)
  end

  @doc """
  Pure tick with explicit config. Returns
  `{:ok, new_state, %{cells_updated, env_delta}}`.
  """
  @spec tick(term(), DirtyMacroBounds.t(), map(), t()) ::
          {:ok, term(), %{cells_updated: non_neg_integer(), env_delta: map() | nil}}
  def tick(state, %DirtyMacroBounds{} = dirty, env, %__MODULE__{} = config) do
    if DirtyMacroBounds.empty?(dirty) do
      {:ok, state, %{cells_updated: 0, env_delta: nil}}
    else
      storage = Map.fetch!(env, :storage)
      neighbor_lookup = Map.get(env, :neighbor_lookup)
      chunk_coord = Map.fetch!(env, :chunk_coord)

      field_mask = field_mask_for(config.attribute_name)
      field_key = field_key_for(config.attribute_name)

      # iterate macro cells in dirty half-open bounds
      {min_x, min_y, min_z} = dirty.min_macro
      {max_x, max_y, max_z} = dirty.max_macro

      ops =
        for x <- min_x..(max_x - 1)//1,
            y <- min_y..(max_y - 1)//1,
            z <- min_z..(max_z - 1)//1 do
          macro_idx = Types.macro_index!({x, y, z})

          cur = read_value(storage, {x, y, z}, config.attribute_name)

          neighbors = [
            read_neighbor_value(storage, neighbor_lookup, chunk_coord, {x - 1, y, z}, cur,
              attribute_name: config.attribute_name
            ),
            read_neighbor_value(storage, neighbor_lookup, chunk_coord, {x + 1, y, z}, cur,
              attribute_name: config.attribute_name
            ),
            read_neighbor_value(storage, neighbor_lookup, chunk_coord, {x, y - 1, z}, cur,
              attribute_name: config.attribute_name
            ),
            read_neighbor_value(storage, neighbor_lookup, chunk_coord, {x, y + 1, z}, cur,
              attribute_name: config.attribute_name
            ),
            read_neighbor_value(storage, neighbor_lookup, chunk_coord, {x, y, z - 1}, cur,
              attribute_name: config.attribute_name
            ),
            read_neighbor_value(storage, neighbor_lookup, chunk_coord, {x, y, z + 1}, cur,
              attribute_name: config.attribute_name
            )
          ]

          # Stencil computation in float, rounded back to i16.
          delta = config.alpha * config.dt * (Enum.sum(neighbors) - 6 * cur)
          new_val = round(cur + delta)
          new_val = clip_i16(new_val)

          source_hash = compute_source_hash(macro_idx, cur, neighbors, config)

          base_op = %{
            macro_index: macro_idx,
            field_mask: field_mask,
            source_hash: source_hash
          }

          Map.put(base_op, field_key, new_val)
        end

      env_delta = %{
        chunk_coord: chunk_coord,
        ops: ops
      }

      {:ok, state, %{cells_updated: length(ops), env_delta: env_delta}}
    end
  end

  # ---------------------------------------------------------------------------
  # helpers
  # ---------------------------------------------------------------------------

  defp resolve_config(%__MODULE__{} = c, _env), do: c
  defp resolve_config({:configured, %__MODULE__{} = c}, _env), do: c

  defp resolve_config(_state, env) do
    case Map.get(env, :diffusion_config) do
      %__MODULE__{} = c -> c
      _ -> %__MODULE__{}
    end
  end

  defp field_mask_for("temperature"), do: 0x01
  defp field_mask_for("moisture"), do: 0x02

  defp field_mask_for(other),
    do: raise(ArgumentError, "unknown attribute_name for DiffusionSimulator: #{inspect(other)}")

  defp field_key_for("temperature"), do: :temperature
  defp field_key_for("moisture"), do: :moisture

  defp field_key_for(other),
    do: raise(ArgumentError, "unknown attribute_name for DiffusionSimulator: #{inspect(other)}")

  # Reads the i16 raw current value (temperature or moisture) for an in-chunk
  # macro cell. Returns 0 when the cell has no environment summary attached.
  defp read_value(storage, {x, y, z}, attribute_name)
       when x in 0..15 and y in 0..15 and z in 0..15 do
    macro_idx = Types.macro_index!({x, y, z})
    header = Enum.at(storage.macro_headers, macro_idx)

    cond do
      is_nil(header) ->
        0

      header.environment_index == @no_index ->
        0

      true ->
        summary = Enum.at(storage.environment_summaries, header.environment_index)

        case {attribute_name, summary} do
          {_, nil} -> 0
          {"temperature", s} -> s.current_temperature
          {"moisture", s} -> s.current_moisture
        end
    end
  end

  defp read_value(_storage, _coord, _attribute_name), do: 0

  # Reads a neighbor macro value. If coord is in-chunk → read storage; if
  # out-of-chunk → consult neighbor_lookup; if neighbor unavailable → Neumann
  # fallback (return self_value so neighbor - self = 0).
  defp read_neighbor_value(storage, neighbor_lookup, chunk_coord, {nx, ny, nz}, self_value, opts) do
    attribute_name = Keyword.fetch!(opts, :attribute_name)

    cond do
      nx in 0..15 and ny in 0..15 and nz in 0..15 ->
        read_value(storage, {nx, ny, nz}, attribute_name)

      is_function(neighbor_lookup, 1) ->
        # Resolve adjacent chunk coord + local coord.
        {neighbor_chunk_coord, local_neighbor} =
          resolve_cross_chunk_coord(chunk_coord, {nx, ny, nz})

        case neighbor_lookup.(neighbor_chunk_coord) do
          {:ok, neighbor_storage} ->
            read_value(neighbor_storage, local_neighbor, attribute_name)

          _ ->
            self_value
        end

      true ->
        self_value
    end
  end

  defp resolve_cross_chunk_coord({cx, cy, cz}, {nx, ny, nz}) do
    {dcx, lx} = chunk_axis(nx)
    {dcy, ly} = chunk_axis(ny)
    {dcz, lz} = chunk_axis(nz)
    {{cx + dcx, cy + dcy, cz + dcz}, {lx, ly, lz}}
  end

  defp chunk_axis(n) when n < 0, do: {-1, n + 16}
  defp chunk_axis(n) when n > 15, do: {1, n - 16}
  defp chunk_axis(n), do: {0, n}

  defp clip_i16(n) when n < @i16_min, do: @i16_min
  defp clip_i16(n) when n > @i16_max, do: @i16_max
  defp clip_i16(n), do: n

  # source_hash captures macro_index + cur + 6 neighbors + simulator config
  # so it changes when inputs change, and matches across reruns with same input.
  defp compute_source_hash(macro_idx, cur, neighbors, %__MODULE__{} = config) do
    iodata = [
      <<macro_idx::unsigned-big-integer-size(16)>>,
      <<cur::signed-big-integer-size(16)>>,
      Enum.map(neighbors, fn v -> <<clip_i16(v)::signed-big-integer-size(16)>> end),
      <<round(config.alpha * 1_000_000)::signed-big-integer-size(32)>>,
      <<round(config.dt * 1_000_000)::signed-big-integer-size(32)>>,
      config.attribute_name
    ]

    h64 = Hash.digest64(iodata)
    Bitwise.band(h64, 0xFFFF_FFFF)
  end
end
