defmodule GateServer.Npc.Sight do
  @moduledoc "全局系统功能：将 NPC 不可变观察请求投影到 World 的只读射线，不缓存世界或裁决攻击。"
  alias GateServer.Npc.Attention
  alias SceneServer.Movement.ToolHit
  alias VoxelRegion.World

  @doc "角色视野／状态和当前瞄准。角色中心用于可见性采样，瞄准复用本场景 profile 的胶囊。"
  def read(world, %{verb: :get_aim, view: view, entities: entities, profile: profile} = query) do
    hit =
      entities
      |> Enum.flat_map(fn e ->
        case ToolHit.ray(view.origin, view.direction, e.position, profile, view.range_m) do
          {:ok, distance, part} ->
            [
              %{
                kind: :entity,
                target: Map.take(e, [:entity_id, :entity_epoch]),
                entity_tick: e.tick,
                distance_m: distance,
                part: part
              }
            ]

          :miss ->
            []
        end
      end)
      |> Enum.min_by(&{&1.distance_m, &1.target.entity_id}, fn -> nil end)

    sample = World.sight_snapshot(world, view.origin, [{view.direction, view.range_m}])
    [block] = sample.hits

    hit =
      cond do
        block && (hit == nil || block.distance_m <= hit.distance_m) ->
          Map.put(block, :kind, :world)

        true ->
          hit
      end

    hit =
      if hit,
        do: Map.put(hit, :point, point(view.origin, view.direction, hit.distance_m)),
        else: nil

    {:ok,
     %{
       view: view,
       self_tick: query.tick,
       scene_id: query.scene_id,
       session_epoch: query.session_epoch,
       world_seq: sample.seq,
       hit: hit,
       attachments: sample.attachments
     }}
  end

  def read(world, %{view: view, entities: entities} = query) do
    candidates =
      Enum.filter(
        entities,
        &Attention.in_view?(%{direction: view.direction}, view.origin, &1.position)
      )

    rays =
      Enum.map(candidates, fn e ->
        distance = Attention.distance(view.origin, e.position)

        direction =
          if distance == 0,
            do: view.direction,
            else: elem(Attention.toward(view.origin, e.position), 1)

        {direction, distance}
      end)

    sample = World.sight_snapshot(world, view.origin, rays)

    visible =
      for {e, nil} <- Enum.zip(candidates, sample.hits),
          do: Map.put(e, :distance_m, Attention.distance(view.origin, e.position))

    data = %{
      view: view,
      self_tick: query.tick,
      scene_id: query.scene_id,
      session_epoch: query.session_epoch,
      world_seq: sample.seq,
      entities: visible,
      sampling: :entity_center,
      source: :replicated_entities,
      attachments: sample.attachments,
      terrain: :not_enumerated
    }

    if query.verb == :get_target_status do
      [e] = entities

      {:ok,
       Map.merge(Map.drop(data, [:entities]), %{
         valid: true,
         target: Map.take(e, [:entity_id, :entity_epoch]),
         entity_tick: e.tick,
         position: e.position,
         distance_m: Attention.distance(view.origin, e.position),
         in_view: candidates != [],
         visible: visible != []
       })}
    else
      {:ok, data}
    end
  end

  defp point({x, y, z}, {dx, dy, dz}, d), do: {x + dx * d, y + dy * d, z + dz * d}
end
