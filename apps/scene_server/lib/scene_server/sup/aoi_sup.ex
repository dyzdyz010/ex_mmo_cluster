defmodule SceneServer.AoiSup do
  @moduledoc """
  Supervisor subtree for shared AOI infrastructure.

  Layout(启动顺序有意义,见下):

  - `SceneServer.Aoi.RemoteMirrorLedger` — remote halo mirror/prewarm request ledger
  - `SceneServer.Aoi.IndexHeir` — AOI 索引 ETS 表的 heir(必须先于 IndexStore 启动,
    才能在 IndexStore 崩溃时接管表所有权)
  - `SceneServer.Aoi.IndexStore` — 八叉树句柄 + CID 索引 ETS 表的权威 owner
    (替代旧的单点 `AoiManager` GenServer;`AoiManager` 现在是无状态 facade,不进监督树)
  - `SceneServer.AoiItemSup` — dynamic supervisor for per-actor AOI items

  ## 进程身份 / 句柄所有权(S1)

  旧版 `AoiManager` 既是 CID 索引的进程、又是八叉树句柄的唯一持有者,崩溃重启会造新空树
  导致存活 `AoiItem` 句柄孤儿化、AOI 视图脑裂。现在句柄所有权落到极简的 `IndexStore`
  (由 `IndexHeir` 跨重启锚定),`AoiManager` 退化为无状态 facade,热路径直接走 ETS /
  八叉树 NIF,无单点同步 call。

  策略用 `:one_for_one`:`IndexStore` 崩溃重启时,ETS 表已被 `IndexHeir` 接管并由重启后的
  `IndexStore` 认领回来——八叉树句柄与 CID 索引原样 hydrate,**存活的 `AoiItem` 不需要、
  也不应该被一起重启**(这正是去单点的目的:管理者崩溃不波及视图)。`IndexHeir` 在
  `IndexStore` 之前启动,保证崩溃瞬间有合法 heir 接管表。
  """

  use Supervisor

  # defp poolboy_config() do
  #   [
  #     name: {:local, :aoi_worker},
  #     worker_module: SceneServer.Aoi.AoiWorker,
  #     size: 100,
  #     max_overflow: 10
  #   ]
  # end

  @doc "Starts the AOI subtree root."
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, [], opts)
  end

  def init(_init_arg) do
    children = [
      {SceneServer.Aoi.RemoteMirrorLedger, name: SceneServer.Aoi.RemoteMirrorLedger},
      # heir 必须先于 store 启动:store 崩溃时 ETS 才有合法 heir 接管表所有权。
      {SceneServer.Aoi.IndexHeir, name: SceneServer.Aoi.IndexHeir},
      {SceneServer.Aoi.IndexStore, name: SceneServer.Aoi.IndexStore},
      {SceneServer.AoiItemSup, name: SceneServer.AoiItemSup}
      # :poolboy.child_spec(:aoi_worker, poolboy_config())
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
