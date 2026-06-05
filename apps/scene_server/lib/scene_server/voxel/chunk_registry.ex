defmodule SceneServer.Voxel.ChunkRegistry do
  @moduledoc """
  进程身份注册设施：`{logical_scene_id, chunk_coord}` → 权威 `ChunkProcess` pid。

  阶段3.1（进程身份注册化 S1）的核心。这是**同节点单主的唯一真相源**：

  * `ChunkProcess` 通过 `via/2` 生成的 via-tuple 在 `start_link` 时注册进
    `Registry`（`:unique`）。via-tuple 直接写进 child_spec 的 `start` 参数，
    监督树重启天然去重——同 key 第二次 `start_child` 会拿到
    `{:error, {:already_started, pid}}`，绝不会出现两个权威进程。
  * `ChunkDirectory` 退化为无状态 facade，所有 lookup 都经 `lookup/2`
    解析这张表，**不再**持有自己的进程映射（避免双真相源）。

  跨节点单主不在本表职责内：那由 World lease/epoch 栅栏裁决，本表只解决
  同一 BEAM 节点内的去重。

  ## 名字解析

  默认注册表名是模块名 `#{inspect(__MODULE__)}`，由 `SceneServer.VoxelSup`
  以 `{Registry, keys: :unique, name: ...}` 启动。测试可注入独立命名的
  Registry（见 `via/3` / `lookup/3`），与隔离的 `VoxelChunkSup` /
  `ChunkDirectory` 配对，互不串扰。
  """

  @typedoc "Chunk 进程身份 key。"
  @type key :: {non_neg_integer(), {integer(), integer(), integer()}}

  @doc "默认注册表名。`SceneServer.VoxelSup` 以此名启动 `Registry`。"
  @spec default_name() :: module()
  def default_name, do: __MODULE__

  @doc """
  返回 chunk 的 via-tuple，写进 `GenServer.start_link/3` 的 name 参数即完成注册。

  `start_child` 重启同 key 时，`Registry` 保证只有一个进程注册成功，第二个
  得到 `{:error, {:already_started, pid}}`。
  """
  @spec via(non_neg_integer(), {integer(), integer(), integer()}, module()) ::
          {:via, Registry, {module(), key()}}
  def via(logical_scene_id, chunk_coord, registry \\ __MODULE__) do
    {:via, Registry, {registry, key(logical_scene_id, chunk_coord)}}
  end

  @doc """
  按 `{logical_scene_id, chunk_coord}` 解析已注册的权威 `ChunkProcess` pid。

  返回 `{:ok, pid}` 或 `:not_started`（无注册项）。这是 facade 路由 / 跨进程
  fan-out 的唯一查找入口。
  """
  @spec lookup(non_neg_integer(), {integer(), integer(), integer()}, module()) ::
          {:ok, pid()} | :not_started
  def lookup(logical_scene_id, chunk_coord, registry \\ __MODULE__) do
    case Registry.lookup(registry, key(logical_scene_id, chunk_coord)) do
      [{pid, _value}] -> {:ok, pid}
      [] -> :not_started
    end
  end

  @doc "构造注册 key。"
  @spec key(non_neg_integer(), {integer(), integer(), integer()}) :: key()
  def key(logical_scene_id, chunk_coord), do: {logical_scene_id, chunk_coord}
end
