defmodule MmoTest.BodyStore do
  @moduledoc """
  只测试：移动、复制与路由场景的内存身体存储依赖。

  每个测试用独立 Agent 保留快照和会话写入权；不验证数据库或冷重启持久化。
  同一场景内的多个 Scene 共享该测试的 Agent，跨测试不共享状态。
  """
  use Agent

  @doc "由当前测试或 peer 监督树拥有独立快照状态。"
  def start_link(_opts), do: Agent.start_link(fn -> %{} end)

  @doc "按会话代次领取写入权，并返回该测试内已保存的字节。"
  def claim(cid, owner_epoch, opts) do
    Agent.get_and_update(Keyword.fetch!(opts, :store), fn bodies ->
      case Map.get(bodies, cid) do
        nil ->
          {{:ok, nil}, Map.put(bodies, cid, {owner_epoch, nil})}

        {previous_epoch, snapshot} when previous_epoch <= owner_epoch ->
          {{:ok, snapshot}, Map.put(bodies, cid, {owner_epoch, snapshot})}

        _ ->
          {{:error, :stale_owner}, bodies}
      end
    end)
  end

  @doc "仅保存当前写入者提交的快照。"
  def save(cid, owner_epoch, snapshot, opts) when is_binary(snapshot) do
    Agent.get_and_update(Keyword.fetch!(opts, :store), fn bodies ->
      case Map.get(bodies, cid) do
        {^owner_epoch, _} -> {:ok, Map.put(bodies, cid, {owner_epoch, snapshot})}
        _ -> {{:error, :stale_owner}, bodies}
      end
    end)
  end
end
