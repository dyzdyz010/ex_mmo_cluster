defmodule GateServer.Npc.Brain.Social do
  @moduledoc """
  纯社交 Brain 包装现有 Tree；心智输入来自 Life canonical，移动仍只有 Body owner。
  社交抢占先 halt 并排空技能、世界事务与停止确认，再发单个 move_to。
  感谢终态按 source_seq 只确认一次；回避/谨慎在来源仍可见时保持站位，来源离开观察后恢复工作。
  权威拒绝保留为失败终态，不假装到达，也不逐帧重投相同目标。
  """
  @behaviour GateServer.Npc.Brain
  alias GateServer.Npc.Brain.Tree
  alias GateServer.Npc.Life.State
  @impl true
  def init(profile),
    do: %{
      tree: Tree.init(profile),
      social: nil,
      moving: nil,
      stops: MapSet.new(),
      thanks: 0,
      next_id: 1,
      last_outcome: nil,
      blocked: false
    }

  @impl true
  def handle_event({:outcome, _} = event, %{social: nil} = s),
    do: Tree.handle_event(event, s.tree) |> tree_result(s)

  def handle_event({:outcome, %{id: id} = outcome} = event, s) do
    {[], tree} = Tree.handle_event(event, s.tree)

    failed_stop =
      (MapSet.member?(s.stops, id) and outcome.status != :done) or
        match?({:stop_failed, _, _}, Map.get(outcome, :reason))

    s = %{s | tree: tree, stops: MapSet.delete(s.stops, id)}

    cond do
      failed_stop ->
        {[], %{s | blocked: true, last_outcome: outcome}}

      id == s.moving ->
        completed = s.social.mode == :thank and outcome.status == :done
        thanks = if completed, do: max(s.thanks, s.social.source_seq), else: s.thanks

        {[],
         %{
           s
           | moving: nil,
             thanks: thanks,
             last_outcome: outcome,
             social: if(completed, do: nil, else: s.social)
         }}

      s.social != nil ->
        {[], s}

      true ->
        {[], s}
    end
  end

  def handle_event({:observation, _}, %{blocked: true} = s), do: {[], s}

  def handle_event({:observation, %{life: %{state: canonical, now_ms: now}} = o} = event, s) do
    s = %{s | thanks: max(s.thanks, Map.get(o.life, :thanks, 0))}
    choice = State.behavior(canonical, o, now)

    s =
      if choice.acknowledge,
        do: %{s | thanks: max(s.thanks, choice.source_seq)},
        else: s

    choice =
      if choice.mode == :thank and choice.source_seq <= s.thanks,
        do: %{choice | mode: :work},
        else: choice

    visible = s.social && Enum.any?(o.entities, &(&1.entity_id == s.social.actor))

    cond do
      s.social && s.social.mode in [:avoid, :cautious] && visible &&
          choice.mode not in [:avoid, :thank] ->
        advance_social(s, o)

      choice.mode == :work && s.social == nil ->
        Tree.handle_event(event, s.tree) |> tree_result(s)

      choice.mode == :work && s.social.mode == :thank && s.moving == nil ->
        release(s, event)

      choice.mode == :work && not visible ->
        release(s, event)

      s.social == nil ->
        begin_social(s, choice, o)

      identity(choice) != identity(s.social) && s.moving == nil ->
        begin_social(s, choice, o)

      true ->
        advance_social(s, o)
    end
  end

  def handle_event(event, %{social: nil} = s),
    do: Tree.handle_event(event, s.tree) |> tree_result(s)

  def handle_event(_, s), do: {[], s}

  defp begin_social(s, choice, o) do
    {commands, tree} = Tree.halt(s.tree)

    # 目标更新不结束已有停止交接；旧动作 superseded 与 stop 终态是独立结果。
    stops = MapSet.union(s.stops, MapSet.new(for %{id: id, verb: :stop} <- commands, do: id))
    s = %{s | tree: tree, social: Map.merge(choice, %{issued: false, target: nil}), stops: stops}
    if commands == [] and drained?(s), do: advance_social(s, o), else: {commands, s}
  end

  defp advance_social(s, o) do
    if s.social.issued or not drained?(s) do
      {[], s}
    else
      case Enum.find(o.entities, &(&1.entity_id == s.social.actor)) do
        nil ->
          {[], s}

        actor ->
          target = target(o.self.position, actor.position, s.social.distance)
          actual = distance(o.self.position, actor.position)

          should_move =
            if s.social.mode == :thank,
              do: actual > s.social.distance + 0.3,
              else: actual < s.social.distance - 0.3

          if should_move do
            id = {:social, s.next_id}
            {x, _y, z} = target

            # 目标的站立层由 Body 查询权威导航；自身中心高度不能充当目的地脚层。
            command = %{id: id, verb: :move_to, position: {x, z}, tolerance: 0.3}

            {[command],
             %{
               s
               | moving: id,
                 next_id: s.next_id + 1,
                 social: %{s.social | issued: true, target: target}
             }}
          else
            if s.social.mode == :thank do
              {[], %{s | thanks: max(s.thanks, s.social.source_seq), social: nil}}
            else
              {[], %{s | social: %{s.social | issued: true, target: target}}}
            end
          end
      end
    end
  end

  defp release(s, event) do
    if s.moving != nil and MapSet.size(s.stops) == 0 do
      id = {:social_stop, s.next_id}
      {[%{id: id, verb: :stop}], %{s | next_id: s.next_id + 1, stops: MapSet.put(s.stops, id)}}
    else
      if drained?(s),
        do: Tree.handle_event(event, s.tree) |> tree_result(%{s | social: nil}),
        else: {[], s}
    end
  end

  defp drained?(s), do: map_size(s.tree.draining) == 0 and MapSet.size(s.stops) == 0
  defp tree_result({commands, tree}, s), do: {commands, %{s | tree: tree}}
  defp identity(choice), do: {choice.mode, choice.actor, choice.source_seq}

  defp target({x, y, z}, {ax, _ay, az}, desired) do
    length = :math.sqrt((x - ax) ** 2 + (z - az) ** 2)
    {dx, dz} = if length < 0.001, do: {1.0, 0.0}, else: {(x - ax) / length, (z - az) / length}
    {ax + dx * desired, y, az + dz * desired}
  end

  defp distance({x, y, z}, {ax, ay, az}),
    do: :math.sqrt((x - ax) ** 2 + (y - ay) ** 2 + (z - az) ** 2)
end
