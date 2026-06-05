defmodule SceneServer.Voxel.ChunkPersistPool do
  @moduledoc """
  有界 write-behind 持久化池（阶段5.2 voxel-storage-1：对 DB 施背压）。

  ## 问题

  chunk 的快照持久化是 write-behind 的：订阅者可以先收到 delta，DB 写在后台异步
  完成（`ChunkProcess.enqueue_snapshot_persist`）。原实现对每次写都裸 `Task.start`
  做 DB 写——高速写时（如 prefab 批量落方块 / 高频 field tick）会**无界**派生并发
  persist Task，每个 Task 都向 Postgres 池要连接，把背压全部压到 Ecto 连接池上，
  尾延迟与内存随写速恶化。

  ## 机制

  本池是一个**全 scene 共享的有界 poolboy worker pool**：每个 persist Task 在真正
  写 DB **之前**经 `transaction/2` 从池里 checkout 一个 worker；池满时 checkout
  **阻塞 Task 自身**（不是 chunk 进程的 mailbox——chunk 早已把 persist 派进 unlinked
  Task，自己继续处理后续消息）。因此并发 DB 写数被池大小 + overflow 钳死，多余写在
  Task 层排队等 worker，对 DB 形成可控背压而非无界冲击。

  - **谁拥有状态**：本池**无领域状态**。worker 是无状态执行体，只在 checkout 期间
    跑调用方给的 DB 写函数。chunk 仍是 voxel 真相唯一权威；DB（ChunkSnapshotStore）
    仍是崩溃恢复权威存储。池只控制“同时有多少 persist 在写 DB”。
  - **背压传导**：`transaction/2` 在池满时按 `@checkout_timeout_ms` 等待 worker；
    超时返回 `{:error, :persist_pool_timeout}`，由 persist Task 当作一次 persist
    失败（commit durable-ack 据此 reply error + 保留 fence，与 DB 写失败同构，不丢
    正确性）。
  - **可降级**：池未启动（测试 / 极早启动窗口）时 `transaction/2` 直接**就地执行**
    `fun`（不经池），保证功能不依赖池存在——池只是背压设施，不是正确性前提。

  ## 池大小

  默认 `@default_size` 个常驻 worker + `@default_max_overflow` 个临时 worker，可由
  `:scene_server` 应用配置 `:chunk_persist_pool` 覆盖（`size` / `max_overflow` /
  `checkout_timeout_ms`）。取值思路：略小于 Postgres 连接池上限，使 persist 写不至于
  把连接吃光、与其它 DB 路径（订阅 hydrate / 事务 fence 持久化）抢连接。
  """

  @pool_name __MODULE__

  @default_size 8
  @default_max_overflow 8
  @checkout_timeout_ms 5_000

  @doc "poolboy 池名（也是本模块的 child id）。"
  @spec pool_name() :: atom()
  def pool_name, do: @pool_name

  @doc """
  返回挂进监督树的 poolboy child_spec。

  放在 `SceneServer.VoxelSup` 里、`ChunkDirectory` 之前启动，使任何 chunk 的首个
  persist 都能 checkout 到 worker。
  """
  @spec child_spec(keyword()) :: :supervisor.child_spec()
  def child_spec(_opts) do
    config = config()

    pool_opts = [
      name: {:local, @pool_name},
      worker_module: SceneServer.Voxel.ChunkPersistPool.Worker,
      size: config.size,
      max_overflow: config.max_overflow
    ]

    %{
      id: @pool_name,
      start: {:poolboy, :start_link, [pool_opts, []]},
      type: :worker,
      restart: :permanent,
      shutdown: 5_000
    }
  end

  @doc """
  在一个 checkout 的 pool worker 上执行 `fun`（DB 写）。

  * 池已启动：经 `:poolboy.transaction/3` checkout worker，让 worker 进程跑 `fun`，
    完成后归还。池满时 checkout 阻塞（背压）；`@checkout_timeout_ms` 内拿不到 worker
    返回 `{:error, :persist_pool_timeout}`。
  * 池未启动：就地执行 `fun`（不背压，但功能不受影响）。

  `fun` 应是幂等可重试的 DB 写（持久化层已做版本围栏 / 冲突检测）。
  """
  @spec transaction((-> term())) :: term()
  def transaction(fun) when is_function(fun, 0) do
    case Process.whereis(@pool_name) do
      nil ->
        # 池未启动——就地执行（降级，无背压）。
        fun.()

      _pid ->
        run_in_pool(fun)
    end
  end

  defp run_in_pool(fun) do
    timeout = config().checkout_timeout_ms

    :poolboy.transaction(
      @pool_name,
      fn worker -> SceneServer.Voxel.ChunkPersistPool.Worker.run(worker, fun) end,
      timeout
    )
  catch
    # poolboy checkout 超时（池持续饱和）：当作一次 persist 失败，由调用方
    # （persist Task）按失败处理（commit durable-ack reply error + 保留 fence）。
    :exit, {:timeout, _} ->
      {:error, :persist_pool_timeout}

    :exit, reason ->
      {:error, {:persist_pool_unavailable, reason}}
  end

  defp config do
    raw = Application.get_env(:scene_server, :chunk_persist_pool, [])

    %{
      size: Keyword.get(raw, :size, @default_size),
      max_overflow: Keyword.get(raw, :max_overflow, @default_max_overflow),
      checkout_timeout_ms: Keyword.get(raw, :checkout_timeout_ms, @checkout_timeout_ms)
    }
  end

  defmodule Worker do
    @moduledoc """
    无状态 poolboy worker：在 checkout 期间执行调用方给的 DB 写函数。

    worker 是一个极简 GenServer，唯一职责是在自己的进程里跑 `run/2` 的 `fun` 并把
    结果同步回给 checkout 方。把 DB 写跑在 worker 进程而非 checkout 方进程，使**并发
    写数 = 池里被 checkout 的 worker 数**，从而被池大小钳死（背压）。
    """

    use GenServer

    @doc false
    def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, [])

    @doc """
    在 `worker` 进程上同步执行 `fun` 并返回其结果。

    用一个略大于 DB 写重试上限的内部超时兜底：worker 卡死时不让 checkout 方
    无限挂起，归还 worker（poolboy 会因 worker 退出重建）。
    """
    @spec run(pid(), (-> term())) :: term()
    def run(worker, fun) when is_function(fun, 0) do
      GenServer.call(worker, {:run, fun}, 30_000)
    end

    @impl true
    def init(:ok), do: {:ok, %{}}

    @impl true
    def handle_call({:run, fun}, _from, state) do
      result = fun.()
      {:reply, result, state}
    rescue
      exception ->
        {:reply, {:error, {:persist_worker_exception, Exception.message(exception)}}, state}
    catch
      kind, reason ->
        {:reply, {:error, {:persist_worker_caught, kind, reason}}, state}
    end
  end
end
