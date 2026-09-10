defmodule SceneServer.Movement.CollisionUpdates do
  @moduledoc "World 的唯一 FIFO：自然事务一次安装，marker 截断本 tick 的前缀。"
  alias MmoContracts.Voxel.{CanonicalDelta, CanonicalSnapshot}

  defstruct [
    :world,
    :native,
    :baseline_world,
    :baseline_transaction_seq,
    artifacts: %{},
    revisions: [],
    queue: :queue.new(),
    revision: 0,
    transaction_seq: 0,
    build_us: 0,
    queue_wait_us: 0
  ]

  @doc "Scene 发布只读派生 world；覆盖 artifact 只引用收到的不可变 chunk。"
  def new(native), do: %__MODULE__{native: native, world: native.new_world()}

  @doc "仅在无角色的首次快照安装完整世界。"
  def initialize(updates, %CanonicalSnapshot{} = snapshot) do
    {us, world} =
      :timer.tc(fn -> updates.native.set_chunks(updates.world, operations(snapshot.chunks)) end)

    %{updates | world: world, revision: 1, transaction_seq: snapshot.transaction_seq, build_us: us,
      baseline_world: world, baseline_transaction_seq: snapshot.transaction_seq,
      revisions: [{0, 1, world}], artifacts: %{1 => %{}}}
  end

  @doc "以 World 的消息顺序接纳 immutable delta/marker。"
  def enqueue(updates, item, now), do: %{updates | queue: :queue.in({item, now}, updates.queue)}

  @doc "每步至多安装一个非空事务；空事务可跟随，marker 后留到下步。"
  def consume(updates, now), do: consume(updates, now, false, [])

  @doc "提交本世界 tick 的派生碰撞版本；不可变 binary 与旧版本共享。"
  def record_tick(updates, tick, events) do
    Enum.reduce(events, updates, fn
      {:delta, %{chunks: [_ | _] = chunks}, revision, _}, u ->
        u = record_artifact(u, revision, chunks)
        %{u | revisions: [{tick, revision, u.world} | u.revisions]}
      _, u -> u
    end)
  end

  @doc "接收 Scene 同源发布的版本与 artifact；共享 Native 句柄，不重复构建。"
  def ingest_publication(updates, _tick, seq, revision, versions, events) do
    updates = Enum.reduce(events, updates, fn
      {_, _, r, [_ | _] = chunks, _}, u -> record_artifact(u, r, chunks)
      _, u -> u
    end)

    world = case versions do
      [] -> updates.world
      [{_, _, world} | _] -> world
    end

    %{updates | world: world, transaction_seq: seq, revision: revision,
      revisions: versions ++ updates.revisions}
  end

  @doc "导出切点锚点及其后已发布历史；仅含 BEAM 数据，不携带 Native 或完整 L0。"
  def export_checkpoint(updates, cut_tick) do
    revisions = retained_revisions(updates.revisions, cut_tick)
      |> Enum.map(fn {tick, revision, _} ->
        {tick, revision, Map.fetch!(updates.artifacts, revision)}
      end)

    %{baseline_transaction_seq: updates.baseline_transaction_seq,
      transaction_seq: updates.transaction_seq, revision: updates.revision,
      revisions: revisions}
  end

  @doc "从共同初始基线恢复源历史；目标当前进度不改变源已发布的 tick/N/R。"
  def import_checkpoint(updates, %{baseline_transaction_seq: baseline} = checkpoint)
      when baseline == updates.baseline_transaction_seq do
    {us, {revisions, _, _}} = :timer.tc(fn ->
      checkpoint.revisions |> Enum.reverse() |> Enum.reduce(
        {[], updates.baseline_world, %{}},
        fn {tick, revision, overrides}, {revisions, previous_world, previous_overrides} ->
          chunks = overrides
            |> Enum.reject(fn {coord, chunk} -> Map.get(previous_overrides, coord) == chunk end)
            |> Enum.sort_by(&elem(&1, 0))
            |> Enum.map(&elem(&1, 1))

          world = if chunks == [], do: previous_world,
            else: updates.native.set_chunks(previous_world, operations(chunks))

          {[{tick, revision, world} | revisions], world, overrides}
        end)
    end)

    artifacts = Map.new(checkpoint.revisions, fn {_, revision, overrides} -> {revision, overrides} end)
    {:ok, %{updates | world: elem(hd(revisions), 2), revisions: revisions,
      artifacts: artifacts, transaction_seq: checkpoint.transaction_seq,
      revision: checkpoint.revision, queue: :queue.new(),
      build_us: updates.build_us + us, queue_wait_us: 0}}
  end

  def import_checkpoint(_updates, _checkpoint), do: {:error, :incompatible_collision_baseline}

  @doc "按角色模拟 tick 选择精确的历史碰撞，不回滚 canonical 世界。"
  def at_tick(updates, tick) do
    {_, revision, world} = Enum.find(updates.revisions, fn {t, _, _} -> t <= tick end)
    {world, revision}
  end

  @doc "所有角色已执行的最早模拟 tick 之前只保留一份锚点版本。"
  def retire_before(updates, tick) do
    revisions = retained_revisions(updates.revisions, tick)
    artifacts = Map.take(updates.artifacts, Enum.map(revisions, &elem(&1, 1)))
    %{updates | revisions: revisions, artifacts: artifacts}
  end

  defp retained_revisions(revisions, tick) do
    {newer, older} = Enum.split_while(revisions, fn {t, _, _} -> t > tick end)
    newer ++ Enum.take(older, 1)
  end

  defp record_artifact(updates, revision, chunks) do
    overrides = Enum.reduce(chunks, Map.fetch!(updates.artifacts, revision - 1), fn chunk, acc ->
      Map.put(acc, chunk.coord, chunk)
    end)
    %{updates | artifacts: Map.put(updates.artifacts, revision, overrides)}
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
