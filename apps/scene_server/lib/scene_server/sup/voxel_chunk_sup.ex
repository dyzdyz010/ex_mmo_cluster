defmodule SceneServer.VoxelChunkSup do
  @moduledoc """
  Dynamic supervisor for hot voxel chunk processes.

  ## 进程身份与重启（阶段3.1）

  每个 `SceneServer.Voxel.ChunkProcess` 用 via-tuple（见
  `SceneServer.Voxel.ChunkRegistry`）注册自己的进程身份。`start_chunk/2`
  把身份写进 child_spec 的 `start` 参数，因此：

  * 同 `{logical_scene_id, chunk_coord}` 第二次 `start_child` 会因
    `Registry` 去重而返回 `{:error, {:already_started, pid}}`，由
    `ChunkDirectory.ensure_chunk` 复用现有 pid（不会出现双权威）。
  * `ChunkProcess` 的 restart 策略是 `:transient`（见其 `child_spec/1`）：
    正常退出 / lease 撤销不重启，崩溃才重启并经 init 从权威存储 hydrate。

  `max_restarts` / `max_seconds` 显式设大但有限：单 coord 反复崩溃（如
  hydrate 一直失败）最终耗尽整棵 chunk 监督树的重启预算，由 `ChunkProcess`
  在 `terminate` 上报 observe 让 World 标记该 coord 不可用，而不是让坏
  coord 把进程拉起来无限空转。
  """

  use DynamicSupervisor

  # 单 coord 崩溃恢复需要一定重启预算，但要防止坏 coord（hydrate 永久失败、
  # 下游持续不可用）把监督树拖进重启风暴。耗尽后整棵 chunk 子树重启，
  # ChunkProcess.terminate 已上报 observe 供 World 裁决该 coord 不可用。
  @max_restarts 30
  @max_seconds 5

  @doc "Starts the dynamic chunk supervisor."
  def start_link(opts \\ []) do
    DynamicSupervisor.start_link(__MODULE__, [], opts)
  end

  @doc """
  Starts one `SceneServer.Voxel.ChunkProcess` child.

  `opts` 必须带 `:logical_scene_id` / `:chunk_coord`（用于 via-tuple 注册）。
  via-tuple 由 `ChunkProcess.child_spec/1` 写进 `start` 参数，因此重启天然
  去重：同 key 第二次启动返回 `{:error, {:already_started, pid}}`，调用方
  （`ChunkDirectory.ensure_chunk`）复用该 pid。
  """
  def start_chunk(supervisor \\ __MODULE__, opts) do
    DynamicSupervisor.start_child(supervisor, {SceneServer.Voxel.ChunkProcess, opts})
  end

  @doc """
  终止一个 `SceneServer.Voxel.ChunkProcess` 子进程（阶段2.4 空闲驱逐退场）。

  退场所有权归 `ChunkDirectory` facade：facade 复核 chunk 仍空闲并完成
  persist 后，调用本函数 `DynamicSupervisor.terminate_child/2`。因为
  `ChunkProcess` 是 `:transient`，被 supervisor 主动终止（`:shutdown`）
  **不会重启**——这正是驱逐想要的：进程退出 + 注册项由 `Registry` 随
  `:DOWN` 摘除，下次 `ensure_chunk` 再按需冷启并从持久化 hydrate。

  与崩溃路径的区别：崩溃是异常退出（reason != :normal/:shutdown），
  `:transient` 会重启并 hydrate；驱逐是 supervisor 计划内终止，不重启。
  """
  @spec terminate_chunk(Supervisor.supervisor(), pid()) :: :ok | {:error, :not_found}
  def terminate_chunk(supervisor \\ __MODULE__, chunk_pid) when is_pid(chunk_pid) do
    DynamicSupervisor.terminate_child(supervisor, chunk_pid)
  end

  @impl true
  def init(_init_arg) do
    DynamicSupervisor.init(
      strategy: :one_for_one,
      max_restarts: @max_restarts,
      max_seconds: @max_seconds
    )
  end
end
