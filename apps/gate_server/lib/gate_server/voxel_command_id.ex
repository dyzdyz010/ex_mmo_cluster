defmodule GateServer.VoxelCommandId do
  @moduledoc """
  客户端体素写命令的稳定幂等键派生(AUTH-4 / SEC-4,梯队1 step1.5b)。

  权威体素写命令(单方块编辑、prefab 放置)在 gate 连接层用
  `(kind, logical_scene_id, actor_cid, client_intent_seq)` 派生一个稳定的
  `command_id` 字符串,沿 gate → scene → store 线程化,在 durable 写入事务内
  `DataService.Voxel.CommandLog` 登记一次,保证重复命令不产生重复 durable 副作用。

  **不改 wire**:`command_id` 在服务端派生,wire 仍只携带 `request_id` /
  `client_intent_seq` / `logical_scene_id`(满足"字段只追加"纪律)。

  **客户端契约**:同一逻辑意图的重试必须复用同 `client_intent_seq`——这是 seq 的
  本义。若客户端在重试时自增 seq,服务端去重不触发(属客户端跟进项),但服务端机制
  按 `command_id` 去重的形态不变。

  `kind` 区分命令族(`"edit"` / `"prefab"`),避免不同命令族 seq 空间重叠时撞键。
  """

  @doc "单方块/微块体素编辑命令的 command_id。"
  @spec edit(non_neg_integer(), non_neg_integer(), non_neg_integer()) :: String.t()
  def edit(logical_scene_id, actor_cid, client_intent_seq),
    do: build("edit", logical_scene_id, actor_cid, client_intent_seq)

  @doc "prefab 放置命令的 command_id。"
  @spec prefab(non_neg_integer(), non_neg_integer(), non_neg_integer()) :: String.t()
  def prefab(logical_scene_id, actor_cid, client_intent_seq),
    do: build("prefab", logical_scene_id, actor_cid, client_intent_seq)

  defp build(kind, logical_scene_id, actor_cid, client_intent_seq)
       when is_binary(kind) and is_integer(logical_scene_id) and is_integer(actor_cid) and
              is_integer(client_intent_seq) do
    "#{kind}:#{logical_scene_id}:#{actor_cid}:#{client_intent_seq}"
  end
end
