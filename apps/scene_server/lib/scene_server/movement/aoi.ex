defmodule SceneServer.Movement.AOI do
  @moduledoc """
  Replication 独占的不可变 AOI 派生状态；32m 三维候选格与 30/34m 滞回。
  输入仅含已到 origin 的步后实体值，输出为 C1 生命周期和绝对快照。
  每个观察者用单调计数器分配关系 generation；离开即删关系，断线即删观察者。
  """
  alias MmoContracts.{Session, Movement}

  @cell_m 32
  @enter_m 30
  @leave_m 34

  @doc "创建空关系状态；不拥有进程、时钟或物理世界。"
  def new, do: %{}

  @doc """
  接收含 identity、entity ID/epoch、state、simulation_tick、collision_revision 的只读值与公共 tick。
  返回 `{新状态, 可靠 Enter/Leave 列表, Snapshot 列表}`；调用者先发送全部生命周期。
  """
  def update(aoi, entities, tick) do
    frame = frame(entities)
    update_frame(aoi, frame, tick, Map.new(entities, &{&1.identity, true}))
  end

  @doc "一次构造全部目标的不可变空间索引，供各观察者分组共用。"
  def frame(entities) do
    entities = Enum.sort_by(entities, & &1.entity_id)
    by_key = Map.new(entities, &{key(&1), &1})
    grid = Enum.group_by(entities, &cell(&1.state.position))
    # 同格观察者复用排好序的候选集；关系顺序只在进入/离开时重建。
    candidates =
      Map.new(grid, fn {coord, _} ->
        {coord, candidates(grid, coord) |> Enum.sort_by(& &1.entity_id)}
      end)

    %{entities: entities, by_key: by_key, candidates: candidates}
  end

  @doc "只推进所给观察者的关系；目标来自完整帧，分组不改变代际和实际 tick。"
  def update_frame(
        aoi,
        %{entities: entities, by_key: by_key, candidates: candidates},
        tick,
        observers
      ) do
    entities = Enum.filter(entities, &Map.has_key?(observers, &1.identity))

    {next, lifecycle, snapshots} =
      Enum.reduce(entities, {new(), [], []}, fn observer, {next, lifecycle, snapshots} ->
        {generation, visible, ordered} = Map.get(aoi, observer.identity, {0, %{}, []})

        {retained, leaves} =
          Enum.reduce(ordered, {visible, []}, fn target, {seen, events} ->
            case Map.fetch(by_key, target) do
              {:ok, entity} ->
                if near?(observer, entity, @leave_m),
                  do: {seen, events},
                  else:
                    {Map.delete(seen, target),
                     [leave(observer.identity, target, visible[target], tick) | events]}

              :error ->
                {Map.delete(seen, target),
                 [leave(observer.identity, target, visible[target], tick) | events]}
            end
          end)

        {generation, visible, enters} =
          Enum.reduce(
            candidates[cell(observer.state.position)],
            {generation, retained, []},
            fn entity, {gen, seen, events} ->
              target = key(entity)

              if entity.entity_id != observer.entity_id and not Map.has_key?(seen, target) and
                   near?(observer, entity, @enter_m) do
                gen = gen + 1

                event = %Session.EntityEnter{
                  identity: observer.identity,
                  entity_id: entity.entity_id,
                  entity_epoch: entity.entity_epoch,
                  interest_generation: gen,
                  server_tick: entity.simulation_tick,
                  state: entity.state
                }

                {gen, Map.put(seen, target, gen), [event | events]}
              else
                {gen, seen, events}
              end
            end
          )

        ordered =
          if leaves == [] and enters == [],
            do: ordered,
            else: visible |> Map.keys() |> Enum.sort()

        groups =
          Enum.reduce(ordered, %{}, fn target, groups ->
            entity = Map.fetch!(by_key, target)

            record = %Movement.SnapshotRecord{
              entity_id: entity.entity_id,
              entity_epoch: entity.entity_epoch,
              interest_generation: visible[target],
              collision_revision: entity.collision_revision,
              state: entity.state
            }

            Map.update(groups, entity.simulation_tick, [record], &[record | &1])
          end)

        messages =
          for {simulation_tick, records} <- Enum.sort(groups) do
            %Movement.Snapshot{
              identity: observer.identity,
              server_tick: simulation_tick,
              records: Enum.reverse(records)
            }
          end

        {Map.put(next, observer.identity, {generation, visible, ordered}),
         [Enum.reverse(leaves) ++ Enum.reverse(enters) | lifecycle], [messages | snapshots]}
      end)

    {next, lifecycle |> Enum.reverse() |> List.flatten(),
     snapshots |> Enum.reverse() |> List.flatten()}
  end

  @doc "立即清理断线实体/观察者；只给仍在场的观察者返回本代 Leave。"
  def remove(aoi, identity, entity_id, entity_epoch, tick) do
    target = {entity_id, entity_epoch}

    aoi
    |> Map.delete(identity)
    |> Enum.sort()
    |> Enum.reduce({new(), []}, fn {observer, {generation, visible, ordered}}, {next, events} ->
      {old, visible} = Map.pop(visible, target)
      leaves = if old == nil, do: [], else: [leave(observer, target, old, tick)]

      {Map.put(next, observer, {generation, visible, List.delete(ordered, target)}),
       [leaves | events]}
    end)
    |> then(fn {state, events} -> {state, events |> Enum.reverse() |> List.flatten()} end)
  end

  @doc "只读关系/代际值，供 Scene observe 和自动化记录；不包含角色物理状态。"
  def observe(aoi) do
    aoi
    |> Enum.sort()
    |> Enum.map(fn {identity, {generation, visible, ordered}} ->
      %{
        identity: identity,
        last_generation: generation,
        visible:
          Enum.map(ordered, fn {id, epoch} = key ->
            %{entity_id: id, entity_epoch: epoch, interest_generation: Map.fetch!(visible, key)}
          end)
      }
    end)
  end

  defp leave(identity, {id, epoch}, generation, tick),
    do: %Session.EntityLeave{
      identity: identity,
      entity_id: id,
      entity_epoch: epoch,
      interest_generation: generation,
      server_tick: tick
    }

  defp key(entity), do: {entity.entity_id, entity.entity_epoch}
  defp cell({x, y, z}), do: {floor(x / @cell_m), floor(y / @cell_m), floor(z / @cell_m)}

  defp candidates(grid, {x, y, z}) do
    for dx <- -1..1,
        dy <- -1..1,
        dz <- -1..1,
        entity <- Map.get(grid, {x + dx, y + dy, z + dz}, []),
        do: entity
  end

  defp near?(a, b, radius) do
    {ax, ay, az} = a.state.position
    {bx, by, bz} = b.state.position
    dx = ax - bx
    dy = ay - by
    dz = az - bz
    dx * dx + dy * dy + dz * dz <= radius * radius
  end
end
