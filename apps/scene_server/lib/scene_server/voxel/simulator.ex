defmodule SceneServer.Voxel.Simulator do
  @moduledoc """
  Phase 5.E simulator behaviour. 每个 chunk 上 `SceneServer.Voxel.ChunkProcess`
  以 10 Hz (100ms) 节奏调度低频规则帧；每帧按 `simulators` 配置依次回调每个
  simulator 的 `tick/3`。

  Phase 5.F 接 `TemperatureDiffusionSimulator`，Phase 6 接 FieldLayer tick
  simulators，均遵循此 behaviour。Phase 5.E 框架就绪，**不注任何具体
  simulator**。

  ## tick/3 契约

    * `state` —— per-chunk per-simulator state（由 simulator 自己定义；默认初始
      值是 `nil`，simulator 第一次被调度时若需要初始化可自行 lazy-init）。
    * `dirty_bounds` —— 上一帧累计的脏 macro bounds，由 ChunkProcess 从
      `storage.dirty_bounds` 注入；半开区间 `[min_macro, max_macro)`。
    * `env` —— 当前 tick 的 chunk 上下文 map。

      | key | 说明 |
      |---|---|
      | `:chunk_coord` | `{cx, cy, cz}` |
      | `:logical_scene_id` | i64 |
      | `:lease_token` | 当前 lease（fence 用；可作为 simulator 自检） |
      | `:storage` | 当前 `Storage.t()`（**只读快照**，simulator 不能直接 mutate） |
      | `:neighbor_lookup` | `(chunk_coord -> {:ok, Storage.t()} | :error)` 或 `nil` |

  ## 返回值

    * `{:ok, new_state, %{cells_updated: non_neg_integer(), env_delta: term() | nil}}`
      —— `env_delta` Phase 5.E 暂未定义具体 schema；Phase 5.F 温湿度 simulator
      会用它带 `environment_summaries` 写回意图。Phase 5.E ChunkProcess 暂时仅
      用于 observe / 计数累计。

    * `{:error, reason :: atom()}` —— 单 simulator 失败不阻塞其它 simulator；
      ChunkProcess 会 emit `voxel_simulation_simulator_failed` 并保留 dirty
      bounds 给下个 tick 重试。
  """

  alias SceneServer.Voxel.DirtyMacroBounds

  @doc "Returns a stable simulator id atom（用于 deterministic output_hash）。"
  @callback simulator_id() :: atom()

  @doc """
  Runs one simulation tick for this chunk.

  Phase 5.E ChunkProcess 仅在 dirty_bounds 非空且 lease 有效时调度本回调。
  """
  @callback tick(
              state :: term(),
              dirty_bounds :: DirtyMacroBounds.t(),
              env :: %{
                chunk_coord: {integer(), integer(), integer()},
                logical_scene_id: non_neg_integer(),
                lease_token: term(),
                storage: term(),
                neighbor_lookup: (term() -> {:ok, term()} | :error) | nil
              }
            ) ::
              {:ok, new_state :: term(),
               %{cells_updated: non_neg_integer(), env_delta: term() | nil}}
              | {:error, atom()}

  @optional_callbacks [tick: 3]
end
