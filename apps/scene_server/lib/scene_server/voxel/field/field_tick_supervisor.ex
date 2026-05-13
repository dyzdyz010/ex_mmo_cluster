defmodule SceneServer.Voxel.Field.FieldTickSupervisor do
  @moduledoc """
  Phase 6 局部场最小目标:DynamicSupervisor,管理 per-region
  `SceneServer.Voxel.Field.FieldTickWorker` 进程池。worker 以
  `:temporary` restart 策略启动——region 在 worker 崩溃时直接丢弃,
  不做自动重建(field 永远是短寿、可重建的派生状态)。
  """

  use DynamicSupervisor

  alias SceneServer.Voxel.Field.FieldTickWorker

  @doc "Starts the DynamicSupervisor (named singleton by default)."
  def start_link(opts) when is_list(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @doc """
  Starts a child FieldTickWorker. Returns `{:ok, pid}` | `{:error, reason}`.

  Required `opts`:
    * `:region` — `%FieldRegion{}`
    * `:chunk_pid` — pid()
    * `:storage_fn` — `(-> Storage.t() | nil)`
    * `:logical_scene_id` — non_neg_integer()
  """
  @spec start_worker(keyword()) :: DynamicSupervisor.on_start_child()
  def start_worker(opts) when is_list(opts) do
    spec = %{
      id: make_ref(),
      start: {FieldTickWorker, :start_link, [opts]},
      restart: :temporary,
      type: :worker
    }

    DynamicSupervisor.start_child(__MODULE__, spec)
  end
end
