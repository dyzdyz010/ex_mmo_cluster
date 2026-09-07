defmodule SceneServer.Movement.AOI do
  @moduledoc """
  Scene 独占的不可变 AOI 派生状态；32m 三维候选格与 30/34m 滞回。
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
  接收 `%{identity, entity_id, entity_epoch, state}` 列表和 Scene 步后 tick/revision。
  返回 `{新状态, 可靠 Enter/Leave 列表, Snapshot 列表}`；调用者先发送全部生命周期。
  """
  def update(aoi, entities, tick, revision) do
    entities = Enum.sort_by(entities, & &1.entity_id)
    by_key = Map.new(entities, &{key(&1), &1})
    grid = Enum.group_by(entities, &cell(&1.state.position))

    Enum.reduce(entities, {new(), [], []}, fn observer, {next, lifecycle, snapshots} ->
      {generation, visible} = Map.get(aoi, observer.identity, {0, %{}})

      retained =
        Map.filter(visible, fn {target, _} ->
          case Map.fetch(by_key, target) do
            {:ok, entity} -> near?(observer, entity, @leave_m)
            :error -> false
          end
        end)

      leaves =
        visible
        |> Map.drop(Map.keys(retained))
        |> Enum.sort()
        |> Enum.map(fn {target, gen} -> leave(observer.identity, target, gen, tick) end)

      entering =
        candidates(grid, observer.state.position)
        |> Enum.filter(fn entity ->
          entity.entity_id != observer.entity_id and
            not Map.has_key?(retained, key(entity)) and near?(observer, entity, @enter_m)
        end)
        |> Enum.sort_by(& &1.entity_id)

      {generation, visible, enters} =
        Enum.reduce(entering, {generation, retained, []}, fn entity, {gen, seen, events} ->
          gen = gen + 1

          event = %Session.EntityEnter{
            identity: observer.identity,
            entity_id: entity.entity_id,
            entity_epoch: entity.entity_epoch,
            interest_generation: gen,
            server_tick: tick,
            state: entity.state
          }

          {gen, Map.put(seen, key(entity), gen), events ++ [event]}
        end)

      records =
        visible
        |> Enum.sort()
        |> Enum.map(fn {target, gen} ->
          entity = Map.fetch!(by_key, target)

          %Movement.SnapshotRecord{
            entity_id: entity.entity_id,
            entity_epoch: entity.entity_epoch,
            interest_generation: gen,
            collision_revision: revision,
            state: entity.state
          }
        end)

      snapshot = %Movement.Snapshot{
        identity: observer.identity,
        server_tick: tick,
        records: records
      }

      {Map.put(next, observer.identity, {generation, visible}), lifecycle ++ leaves ++ enters,
       snapshots ++ [snapshot]}
    end)
  end

  @doc "立即清理断线实体/观察者；只给仍在场的观察者返回本代 Leave。"
  def remove(aoi, identity, entity_id, entity_epoch, tick) do
    target = {entity_id, entity_epoch}

    aoi
    |> Map.delete(identity)
    |> Enum.sort()
    |> Enum.reduce({new(), []}, fn {observer, {generation, visible}}, {next, events} ->
      {old, visible} = Map.pop(visible, target)
      leaves = if old == nil, do: [], else: [leave(observer, target, old, tick)]
      {Map.put(next, observer, {generation, visible}), events ++ leaves}
    end)
  end

  @doc "只读关系/代际值，供 Scene observe 和自动化记录；不包含角色物理状态。"
  def observe(aoi) do
    aoi
    |> Enum.sort()
    |> Enum.map(fn {identity, {generation, visible}} ->
      %{
        identity: identity,
        last_generation: generation,
        visible:
          visible
          |> Enum.sort()
          |> Enum.map(fn {{id, epoch}, gen} ->
            %{entity_id: id, entity_epoch: epoch, interest_generation: gen}
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

  defp candidates(grid, position) do
    {x, y, z} = cell(position)

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
