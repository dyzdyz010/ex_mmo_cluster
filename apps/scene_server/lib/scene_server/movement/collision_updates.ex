defmodule SceneServer.Movement.CollisionUpdates do
  @moduledoc "World 的唯一 FIFO：自然事务一次安装，marker 截断本 tick 的前缀。"
  alias MmoContracts.Voxel.{CanonicalDelta, CanonicalSnapshot}

  defstruct [
    :world,
    :native,
    revisions: [],
    queue: :queue.new(),
    revision: 0,
    transaction_seq: 0,
    build_us: 0,
    queue_wait_us: 0
  ]

  @doc "Scene 发布只读派生 world，不保留另一份 canonical cells。"
  def new(native), do: %__MODULE__{native: native, world: native.new_world()}

  @doc "仅在无角色的首次快照安装完整世界。"
  def initialize(updates, %CanonicalSnapshot{} = snapshot) do
    {us, world} =
      :timer.tc(fn -> updates.native.set_chunks(updates.world, operations(snapshot.chunks)) end)

    %{updates | world: world, revision: 1, transaction_seq: snapshot.transaction_seq, build_us: us,
      revisions: [{0, 1, world}]}
  end

  @doc "以 World 的消息顺序接纳 immutable delta/marker。"
  def enqueue(updates, item, now), do: %{updates | queue: :queue.in({item, now}, updates.queue)}

  @doc "每步至多安装一个非空事务；空事务可跟随，marker 后留到下步。"
  def consume(updates, now), do: consume(updates, now, false, [])

  @doc "提交本世界 tick 的派生碰撞版本；不可变 binary 与旧版本共享。"
  def record_tick(updates, tick, events) do
    Enum.reduce(events, updates, fn
      {:delta, %{chunks: [_ | _]}, revision, _}, u ->
        %{u | revisions: [{tick, revision, u.world} | u.revisions]}
      _, u -> u
    end)
  end

  @doc "按角色模拟 tick 选择精确的历史碰撞，不回滚 canonical 世界。"
  def at_tick(updates, tick) do
    {_, revision, world} = Enum.find(updates.revisions, fn {t, _, _} -> t <= tick end)
    {world, revision}
  end

  @doc "所有角色已执行的最早模拟 tick 之前只保留一份锚点版本。"
  def retire_before(updates, tick) do
    {newer, older} = Enum.split_while(updates.revisions, fn {t, _, _} -> t > tick end)
    %{updates | revisions: newer ++ Enum.take(older, 1)}
  end

  defp consume(updates, now, changed, events) do
    case :queue.peek(updates.queue) do
      :empty ->
        {updates, Enum.reverse(events)}

      {:value, {{:marker, ref, snapshot}, _}} ->
        {{:value, _}, queue} = :queue.out(updates.queue)
        {%{updates | queue: queue}, Enum.reverse([{:marker, ref, snapshot} | events])}

      {:value, {%CanonicalDelta{chunks: chunks}, _}} when changed and chunks != [] ->
        {updates, Enum.reverse(events)}

      {:value, {%CanonicalDelta{} = delta, received}} ->
        {{:value, _}, queue} = :queue.out(updates.queue)
        true = delta.transaction_seq == updates.transaction_seq + 1

        {us, revision, world} =
          if delta.chunks == [] do
            {0, updates.revision, updates.world}
          else
            {us, world} =
              :timer.tc(fn ->
                updates.native.set_chunks(updates.world, operations(delta.chunks))
              end)

            {us, updates.revision + 1, world}
          end

        updates = %{
          updates
          | world: world,
            queue: queue,
            revision: revision,
            transaction_seq: delta.transaction_seq,
            build_us: updates.build_us + us,
            queue_wait_us: max(updates.queue_wait_us, now - received)
        }

        consume(updates, now, changed or delta.chunks != [], [
          {:delta, delta, revision, us} | events
        ])
    end
  end

  @doc "按 W1 已保证的坐标序交 P1，仅转换 POD，不重新查询 World。"
  def operations(chunks) do
    Enum.map(chunks, fn c -> {:set, c.coord, c.n, c.scale_m, c.origin_m, c.cells} end)
  end
end
