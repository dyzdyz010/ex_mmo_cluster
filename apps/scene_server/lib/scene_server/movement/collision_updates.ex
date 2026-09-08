defmodule SceneServer.Movement.CollisionUpdates do
  @moduledoc "World 的唯一 FIFO：自然事务一次安装，marker 截断本 tick 的前缀。"
  alias MmoContracts.Voxel.{CanonicalDelta, CanonicalSnapshot}

  defstruct [
    :world,
    :native,
    revisions: [],
    native_revision: 0,
    native_chunks: %{},
    queue: :queue.new(),
    revision: 0,
    transaction_seq: 0,
    build_us: 0,
    queue_wait_us: 0
  ]

  @doc "Scene 唯一持有此派生 world，不保留另一份 canonical cells。"
  def new(native), do: %__MODULE__{native: native, world: native.new_world()}

  @doc "仅在无角色的首次快照安装完整世界。"
  def initialize(updates, %CanonicalSnapshot{} = snapshot) do
    {us, :ok} =
      :timer.tc(fn -> updates.native.set_chunks(updates.world, operations(snapshot.chunks)) end)

    chunks = Map.new(snapshot.chunks, &{&1.coord, &1})
    %{updates | revision: 1, transaction_seq: snapshot.transaction_seq, build_us: us,
      revisions: [{0, 1, chunks}], native_revision: 1, native_chunks: chunks}
  end

  @doc "以 World 的消息顺序接纳 immutable delta/marker。"
  def enqueue(updates, item, now), do: %{updates | queue: :queue.in({item, now}, updates.queue)}

  @doc "每步至多安装一个非空事务；空事务可跟随，marker 后留到下步。"
  def consume(updates, now), do: consume(updates, now, false, [])

  @doc "提交本世界 tick 的派生碰撞版本；不可变 binary 与旧版本共享。"
  def record_tick(updates, tick, events) do
    Enum.reduce(events, updates, fn
      {:delta, %{chunks: [_ | _] = chunks}, revision, _}, u ->
        {_, _, previous} = hd(u.revisions)
        next = Enum.reduce(chunks, previous, &Map.put(&2, &1.coord, &1))
        %{u | revisions: [{tick, revision, next} | u.revisions],
          native_revision: revision, native_chunks: next}
      _, u -> u
    end)
  end

  @doc "按角色模拟 tick 选择精确的历史碰撞，不回滚 canonical 世界。"
  def at_tick(updates, tick) do
    {_, revision, chunks} = Enum.find(updates.revisions, fn {t, _, _} -> t <= tick end)
    if revision == updates.native_revision do
      {updates, revision}
    else
      changed = for {coord, chunk} <- chunks, Map.get(updates.native_chunks, coord) != chunk, do: chunk
      {us, :ok} = :timer.tc(fn ->
        updates.native.set_chunks(updates.world, operations(Enum.sort_by(changed, & &1.coord)))
      end)
      {%{updates | native_revision: revision, native_chunks: chunks, build_us: updates.build_us + us}, revision}
    end
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

        {us, revision} =
          if delta.chunks == [] do
            {0, updates.revision}
          else
            {us, :ok} =
              :timer.tc(fn ->
                updates.native.set_chunks(updates.world, operations(delta.chunks))
              end)

            {us, updates.revision + 1}
          end

        updates = %{
          updates
          | queue: queue,
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
