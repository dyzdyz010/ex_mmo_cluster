defmodule NpcServer.Life.Sight do
  @moduledoc """
  “看到的”：NPC 的所见作为独立一类经历（内容规范 `docs/10-active/cross-cutting/2026-11-13-npc-mind-content-spec.md` §9，
  用户 2026-11-13 定只做 A 相遇与 B 附近的建造 / 拆除）。纯函数：不查询世界、不持久化、不打日志；Life 持有本模块的
  **进行中的账**（一个普通 map，只在 Life 进程内存里，不落库：Life 重启就丢，不补写——没有真值），在两处喂它：

      see/3      每收到一帧观察（约每 50 毫秒）：相遇账按这一帧更新，并做一次到点检查
      witness/4  每秒读到一批 World 事件：附近的建造 / 拆除进分组账，并做一次到点检查
      due/3      只做到点检查（合上超时的组、结束离开或观察中断的相遇）；上面两个入口也各做一次同样的检查

  三个入口都返回 `{新账, 该写出的经历条目, 被上限挡下的 [%{actor:, kind: :encounter | :construction}]}`。
  经历条目与其它经历同形 `%{"id", "at_ms", "text", "tags"}`，`"text"` 不带时刻（Life 的 `dated/1` 统一加前缀）；
  tags 是 `kind:sight`、做事的人 `actor:<cid>`，涉及有名字的建筑再加 `place:<名>`。被挡下的由 Life 打 `npc_sight_capped` 日志，
  账里的 `capped` 按类计数（`Life.observe/1` 的 `sight_capped`）。

  只写看到的：不写意图、不写评价，不动情绪与信任（数值规则仍只对“动我的建筑”生效，见 `Life.State`）。人按
  `Life.State.person/2` 写 `名字 (actor <cid>)`；谁算人、距离、最近距离账都复用 `Life.State`（`others/1`、`distance/2`、
  `approach/2`、`near_m/0`）。

  ## A 相遇：某人在我附近待过

  观察里有此人 = 在视野里（AOI 30 米进 / 34 米出；隔墙也算，所以句子写 `was around`，不写“看见”）。最近距离按
  `Life.State.approach/2` 逐帧记。时长从第一次出现算到最后一次出现，按游戏钟写（见“时长”）。

      离开（离开视野满 10 秒）且进过 6 米：
        `<人> was around for about <时长>; came within <N> m of me, then left.`
      离开且没进过 6 米（在视野里累计满 50 秒才记）：
        `<人> was around for about <时长>; stayed at least <N> m away, then left.`
      满 5 分钟还没走（这次相遇只写一次；此后只在结束时再写一条上面两种之一）：
        `<人> has been around for about <时长> and is still here; has come within <N> m of me.`
        `<人> has been around for about <时长> and is still here; has stayed at least <N> m away.`
      观察中断超过 5 秒（会话丢失）：进行中的相遇按最后见到时结束，不说离开：
        `<人> was around for about <时长>; came within <N> m of me.`
        `<人> was around for about <时长>; stayed at least <N> m away.`

  `came within <N> m` 的 N 是最近距离向上取整（最小 1，与活动句 `During it:` 同一写法）；`stayed at least <N> m away` 的 N
  向下取整——“至少”用向上取整会说多（最近 7.2 米写成“至少 8 米”是假话）。条目 `"at_ms"`：结束的两种取最后见到的时刻，
  “还在”取写出的时刻。id：`sight:encounter:<cid>:<第一次出现的 at_ms>`，“还在”那条再加 `:still`。

  ## B 附近的建造 / 拆除：某人在我附近放了 / 拆了东西

  算所见的 World 事件：不是我做的；没有被“动我的建筑”那条规则写成经历（Life 用 `unwritten/2` 按 seq 排除
  `Life.State.advance/6` 返回的经历）；事件格中心到我此刻位置不超过 30 米；事件时刻距现在不超过 5 秒（落后太多时我未必在场）。
  还没有观察（不知道我在哪）就一件都不算。同一 seq 只算一次（Life 写失败后 World 游标没前进、同一批事件会再来）。
  按（谁、放 / 拆、哪座建筑或散格）分组：`:build` 是放，`:damage` / `:destroy` 是拆；“哪座建筑”是事件的根实例 `instance`，
  没有所属实例的（散格、地形）同属一组“散格”。组内 30 秒没有新事件、或开组满 5 分钟时合成一条：

      放，散格：            `<人> placed <N> block(s) about <M> m from me.`
      放，有名字的建筑：    `<人> placed the building "<名>" about <M> m from me.`
      放，没有名字的建筑：  `<人> placed an unnamed building about <M> m from me.`
      拆，散格：            `<人> removed <N> block(s)[ that <原放置者> placed,] about <M> m from me.`（组里有 `:destroy`，N = 毁掉的格数）
                           `<人> damaged <N> block(s)[ that <原放置者> placed,] about <M> m from me.`（只有 `:damage`，N = 打过的格数）
      拆，建筑（<B> = `building "<名>"` 或 `unnamed building`）：
                           `<人> removed the entire <B>[ that <原放置者> placed,] about <M> m from me.`（组里有事件的 `instance_removed`）
                           `<人> broke off part of the <B>[ that <原放置者> placed,] about <M> m from me.`（有 `:destroy`，根实例还在）
                           `<人> damaged part of the <B>[ that <原放置者> placed,] about <M> m from me.`（只有 `:damage`）

  格数按不同的格算（同一格打几下算一格）。`<M>` 是组内各事件格中心到我（喂入那一刻的位置）的最近距离，向上取整、最小 1。
  `[ that <原放置者> placed,]` 只在组内各事件的 `placed_by` 是同一个人时写（按 `Life.State.person/2`，名字取不到写 `actor <cid>`；
  原放置者是我自己时写 ` that I placed,`）；没有放置记录（作者放置、地形）或几个人放的混在一起时不写，不替它猜。
  我放的东西被动、但没有被“动我的建筑”写成经历的（同一次毁坏过程里第一下之后的各下：`Life.State` 一次过程只评价首个）
  照样算所见，于是说得出第一下之后还拆了多少。条目 `"at_ms"` 取组内最后一个事件的时刻；
  id：`sight:place:<cid>:<组内第一个 seq>` / `sight:remove:<cid>:<组内第一个 seq>`。

  ## 时长

  句子里的时长按游戏钟写（`MmoContracts.WorldTime` 的 `rate`：现实 150 秒 = 游戏 1 小时；2026-11-15 起 ×24，此前 ×72），门槛都是现实时间。
  游戏分钟 = 现实毫秒 × rate ÷ 60000 四舍五入；不足 60 写 `about <N> minute(s)`（最小 1），否则游戏小时 = 游戏分钟 ÷ 60
  四舍五入，写 `about <N> hour(s)`。

  ## 门槛（全部是原创取值，用户 2026-11-13 同意先按此做，实跑导出后再调）

      @gone_ms                10 秒    离开视野满这么久，这次相遇才结束（期间再出现算同一次）
      @linger_ms              50 秒    没进过 6 米的人，在视野里累计满这么久才记
      Life.State.near_m/0     6 米     进过这个距离即记（与活动句 `During it:` 同一半径）
      @still_ms               5 分钟   一直不走的，满这么久先写一条“还在”
      @blackout_ms            5 秒     两帧观察间隔超过这么久算观察中断
      @construction_radius_m  30 米    事件格到我的距离上限
      @construction_fresh_ms  5 秒     事件时刻到现在的落后上限
      @group_quiet_ms         30 秒    组内这么久没有新事件就合上
      @group_span_ms          5 分钟   开组满这么久就合上
      @cap_entries / @cap_window_ms  4 条 / 20 分钟  同一人每类（相遇、建造拆除各自计）在这段时间里至多写几条；
                                                     挡下的不写，Life 打 `npc_sight_capped` 日志

  ## 明确不做的（§9.4）

  别人此刻的动作 / 技能 / 施法、受伤、所持物、生命值（没有下发）；视线遮挡（视野就是 AOI）；别人之间的对话（只有对我说的话
  会到我这里，归“听到的”）；速度、朝向、逐笔体素流、工具 / 投射物回执；所见不触发重新选择、不打断进行中的活动。
  C 倒下 / 死亡本次不做（要改 Body，且 NPC-only 实跑里的产生方式未查清）。与活动句 `During it:` 的重复先两者都留，实跑后再定。
  """
  alias MmoContracts.WorldTime
  alias NpcServer.Life.State

  @gone_ms 10_000
  @linger_ms 50_000
  @still_ms 300_000
  @blackout_ms 5_000
  @construction_radius_m 30.0
  @construction_fresh_ms 5_000
  @group_quiet_ms 30_000
  @group_span_ms 300_000
  @cap_entries 4
  @cap_window_ms 20 * 60_000

  @doc """
  空账。`encounters` 是 `%{cid => %{first_ms:, last_seen_ms:, in_sight_ms:, still_written:}}`（进行中的相遇），
  `closest` 是这些人的最近距离账（`Life.State.approach/2` 的形状），`last_frame_ms` 是上一帧观察的时刻；
  `groups` 是 `%{{actor, :place | :remove, instance | :loose} => 组}`（还没合上的建造 / 拆除），`witnessed_through`
  是已经算过的最大 World seq；`written` 是 `%{{类, cid} => [写出的时刻]}`（频率上限），`capped` 是按类挡下的条数。
  """
  def new,
    do: %{
      last_frame_ms: nil,
      encounters: %{},
      closest: %{},
      groups: %{},
      witnessed_through: nil,
      written: %{},
      capped: %{encounter: 0, construction: 0}
    }

  @doc "喂一帧观察（`now_ms` 是收到它的毫秒墙钟）：更新相遇账并做到点检查。返回值见 moduledoc。"
  def see(ledger, observation, now_ms) do
    {ledger, lost} = blackout(ledger, now_ms)
    present = observation |> State.others() |> Enum.map(& &1.entity_id) |> Enum.sort()

    encounters =
      Enum.reduce(present, ledger.encounters, &track(&2, &1, ledger.last_frame_ms, now_ms))

    ledger = %{
      ledger
      | encounters: encounters,
        closest: State.approach(ledger.closest, observation),
        last_frame_ms: now_ms
    }

    {ledger, still} = still_here(ledger, present, now_ms)
    {ledger, ended} = close_encounters(ledger, now_ms)
    {ledger, built} = close_groups(ledger, names(observation), now_ms)
    admit(ledger, lost ++ still ++ ended ++ built, now_ms)
  end

  @doc """
  喂一批 World 事件（Life 先用 `unwritten/2` 去掉已写成经历的）：`observation` 是 Life 此刻持有的观察（我的位置、
  我是谁、人名），为 nil 时不知道我在哪，事件一件都不算，只做到点检查。返回值见 moduledoc。
  """
  def witness(ledger, _events, nil, now_ms), do: due(ledger, nil, now_ms)

  def witness(ledger, events, %{self: me} = observation, now_ms) do
    names = names(observation)
    through = ledger.witnessed_through || 0

    groups =
      for event <- events,
          event.seq > through,
          event.actor != me.entity_id,
          now_ms - event.at_ms <= @construction_fresh_ms,
          metres = State.distance(me.position, centre(event.cell)),
          metres <= @construction_radius_m,
          reduce: ledger.groups do
        groups -> join(groups, event, metres, me.entity_id, names, now_ms)
      end

    through = Enum.reduce(events, ledger.witnessed_through, &max(&1.seq, &2 || 0))
    due(%{ledger | groups: groups, witnessed_through: through}, observation, now_ms)
  end

  @doc """
  到点检查：观察中断超过 5 秒时结束全部进行中的相遇（不说离开），离开视野满 10 秒的相遇结束，到点的组合上。
  `observation` 只用来取人名（可为 nil）。返回值见 moduledoc。
  """
  def due(ledger, observation, now_ms) do
    {ledger, lost} = blackout(ledger, now_ms)
    {ledger, ended} = close_encounters(ledger, now_ms)
    {ledger, built} = close_groups(ledger, names(observation), now_ms)
    admit(ledger, lost ++ ended ++ built, now_ms)
  end

  @doc """
  一批 World 事件里没有被 `Life.State.advance/6` 写成经历的那些（按 seq 排除它返回的经历）：同一件事已经作为
  “动我的建筑”写过一条，就不再作为所见写第二条。
  """
  def unwritten(events, episodes) do
    written = MapSet.new(episodes, & &1["seq"])
    Enum.reject(events, &MapSet.member?(written, &1.seq))
  end

  @doc "现实时长（毫秒）按游戏钟写成 `about <N> minute(s)` / `about <N> hour(s)`；取整规则见 moduledoc。"
  def duration(real_ms) do
    minutes = div(real_ms * WorldTime.params().rate + 30_000, 60_000)

    if minutes < 60,
      do: "about " <> count(max(1, minutes), "minute"),
      else: "about " <> count(div(minutes + 30, 60), "hour")
  end

  # —— A 相遇 ——

  # 两帧间隔超过 @blackout_ms：观察中断（会话丢失），进行中的相遇按最后见到时结束，不说离开；账清空，之后再出现算新的一次。
  defp blackout(%{last_frame_ms: last} = ledger, now_ms)
       when is_integer(last) and now_ms - last > @blackout_ms do
    lost =
      for {cid, encounter} <- Enum.sort(ledger.encounters),
          seen = ledger.closest[cid],
          qualifies?(encounter, seen),
          do: encounter_entry(cid, encounter, seen, :lost, encounter.last_seen_ms)

    {%{ledger | encounters: %{}, closest: %{}}, lost}
  end

  defp blackout(ledger, _now_ms), do: {ledger, []}

  defp track(encounters, cid, last_frame_ms, now_ms) do
    case encounters do
      %{^cid => encounter} ->
        # 上一帧也在：两帧之间这段算在视野里；中途离开过（不满 10 秒又回来）的那段不算。
        gained = if encounter.last_seen_ms == last_frame_ms, do: now_ms - last_frame_ms, else: 0

        Map.put(encounters, cid, %{
          encounter
          | last_seen_ms: now_ms,
            in_sight_ms: encounter.in_sight_ms + gained
        })

      _ ->
        Map.put(encounters, cid, %{
          first_ms: now_ms,
          last_seen_ms: now_ms,
          in_sight_ms: 0,
          still_written: false
        })
    end
  end

  # 此刻在场、已满 @still_ms、够得上记的人：写一条“还在”，这次相遇不再写第二条（被上限挡下也算写过，不逐帧重试）。
  defp still_here(ledger, present, now_ms) do
    Enum.reduce(present, {ledger, []}, fn cid, {ledger, entries} ->
      encounter = ledger.encounters[cid]
      seen = ledger.closest[cid]

      if not encounter.still_written and now_ms - encounter.first_ms >= @still_ms and
           qualifies?(encounter, seen) do
        ledger = put_in(ledger, [:encounters, cid, :still_written], true)
        {ledger, entries ++ [encounter_entry(cid, encounter, seen, :still, now_ms)]}
      else
        {ledger, entries}
      end
    end)
  end

  # 离开视野满 @gone_ms 的相遇结束；够得上记的写一条“离开”，够不上的只是从账里去掉。
  defp close_encounters(ledger, now_ms) do
    {gone, staying} =
      Enum.split_with(ledger.encounters, fn {_cid, encounter} ->
        now_ms - encounter.last_seen_ms >= @gone_ms
      end)

    left =
      for {cid, encounter} <- Enum.sort(gone),
          seen = ledger.closest[cid],
          qualifies?(encounter, seen),
          do: encounter_entry(cid, encounter, seen, :left, encounter.last_seen_ms)

    gone_ids = Enum.map(gone, &elem(&1, 0))

    {%{ledger | encounters: Map.new(staying), closest: Map.drop(ledger.closest, gone_ids)}, left}
  end

  # 够得上记：进过 6 米，或在视野里累计满 @linger_ms（用户 2026-11-13 定：任一即记）。
  defp qualifies?(encounter, %{metres: metres}),
    do: metres <= State.near_m() or encounter.in_sight_ms >= @linger_ms

  # ending：:left 离开、:lost 观察中断、:still 还在。seen 是这个人在最近距离账里的那一项。
  defp encounter_entry(cid, encounter, %{metres: metres, name: name}, ending, at_ms) do
    who = State.person(cid, %{cid => name})
    base = "sight:encounter:#{cid}:#{encounter.first_ms}"
    lasted = duration(encounter.last_seen_ms - encounter.first_ms)

    {id, text} =
      case ending do
        :left ->
          {base, "#{who} was around for #{lasted}; #{reach(metres)}, then left."}

        :lost ->
          {base, "#{who} was around for #{lasted}; #{reach(metres)}."}

        :still ->
          so_far = duration(at_ms - encounter.first_ms)

          {base <> ":still",
           "#{who} has been around for #{so_far} and is still here; has #{reach_so_far(metres)}."}
      end

    {:encounter, cid, entry(id, at_ms, text, ["kind:sight", "actor:#{cid}"])}
  end

  defp reach(metres) do
    if metres <= State.near_m(),
      do: "came within #{max(1, ceil(metres))} m of me",
      else: "stayed at least #{floor(metres)} m away"
  end

  defp reach_so_far(metres) do
    if metres <= State.near_m(),
      do: "come within #{max(1, ceil(metres))} m of me",
      else: "stayed at least #{floor(metres)} m away"
  end

  # —— B 附近的建造 / 拆除 ——

  # 事件的 `cell` 是 1 米的宏格下标；距离量到格中心。
  defp centre({x, y, z}), do: {x + 0.5, y + 0.5, z + 0.5}

  # me：我的 cid。原放置者是我时记成 :me（句子写 `that I placed`；人名表里没有我自己）。
  defp join(groups, event, metres, me, names, now_ms) do
    verb = if event.kind == :build, do: :place, else: :remove
    key = {event.actor, verb, event[:instance] || :loose}
    group = Map.get(groups, key) || open_group(event, verb, metres, now_ms)
    placer = if event.placed_by == me, do: :me, else: event.placed_by

    destroyed =
      if event.kind == :destroy,
        do: MapSet.put(group.destroyed, event.cell),
        else: group.destroyed

    Map.put(groups, key, %{
      group
      | cells: MapSet.put(group.cells, event.cell),
        destroyed: destroyed,
        removed: group.removed or event[:instance_removed] == true,
        placers: MapSet.put(group.placers, placer),
        closest_m: min(group.closest_m, metres),
        building: event[:building] || group.building,
        names: Map.merge(group.names, names),
        last_ms: now_ms,
        last_at_ms: event.at_ms
    })
  end

  # opened_ms / last_ms 用 Life 的时钟（到点检查拿同一个钟比较）；last_at_ms 是事件的权威时刻（写进条目）。
  defp open_group(event, verb, metres, now_ms),
    do: %{
      actor: event.actor,
      verb: verb,
      instance: event[:instance],
      building: nil,
      first_seq: event.seq,
      opened_ms: now_ms,
      last_ms: now_ms,
      last_at_ms: event.at_ms,
      cells: MapSet.new(),
      destroyed: MapSet.new(),
      removed: false,
      placers: MapSet.new(),
      closest_m: metres,
      names: %{}
    }

  # 组内 @group_quiet_ms 没有新事件，或开组满 @group_span_ms：合成一条（按组内第一个 seq 的次序）。
  defp close_groups(ledger, names, now_ms) do
    {closing, open} =
      Enum.split_with(ledger.groups, fn {_key, group} ->
        now_ms - group.last_ms >= @group_quiet_ms or now_ms - group.opened_ms >= @group_span_ms
      end)

    entries =
      closing
      |> Enum.map(&elem(&1, 1))
      |> Enum.sort_by(& &1.first_seq)
      |> Enum.map(&construction_entry(&1, names))

    {%{ledger | groups: Map.new(open)}, entries}
  end

  # 人名：喂事件时的观察里的名字，被合上那一刻观察里的名字优先（与其它经历一样取 Life 此刻持有的观察）。
  defp construction_entry(group, names) do
    names = Map.merge(group.names, names)
    who = State.person(group.actor, names)
    where = "about #{max(1, ceil(group.closest_m))} m from me"
    text = account(group, who, placer(group, names), where)
    place = if group.building, do: ["place:#{group.building}"], else: []

    {:construction, group.actor,
     entry(
       "sight:#{group.verb}:#{group.actor}:#{group.first_seq}",
       group.last_at_ms,
       text,
       ["kind:sight", "actor:#{group.actor}"] ++ place
     )}
  end

  defp account(%{verb: :place, instance: nil} = group, who, _placer, where),
    do: "#{who} placed #{count(MapSet.size(group.cells), "block")} #{where}."

  defp account(%{verb: :place, building: nil}, who, _placer, where),
    do: "#{who} placed an unnamed building #{where}."

  defp account(%{verb: :place, building: name}, who, _placer, where),
    do: ~s|#{who} placed the building "#{name}" #{where}.|

  defp account(%{verb: :remove, instance: nil} = group, who, placer, where) do
    destroyed = MapSet.size(group.destroyed)

    deed =
      if destroyed > 0,
        do: "removed " <> count(destroyed, "block"),
        else: "damaged " <> count(MapSet.size(group.cells), "block")

    "#{who} #{deed}#{placer} #{where}."
  end

  defp account(%{verb: :remove} = group, who, placer, where) do
    building =
      if group.building, do: ~s|building "#{group.building}"|, else: "unnamed building"

    deed =
      cond do
        group.removed -> "removed the entire #{building}"
        MapSet.size(group.destroyed) > 0 -> "broke off part of the #{building}"
        true -> "damaged part of the #{building}"
      end

    "#{who} #{deed}#{placer} #{where}."
  end

  # 原放置者：组内各事件的 placed_by 是同一个人才写；没有放置记录（nil）或几个人混在一起时不写。
  defp placer(group, names) do
    case MapSet.to_list(group.placers) do
      [:me] -> " that I placed,"
      [cid] when cid != nil -> " that #{State.person(cid, names)} placed,"
      _ -> ""
    end
  end

  # —— 共用 ——

  # 每人每类频率上限：近 @cap_window_ms 里写过 @cap_entries 条就挡下（不写、计数、交给 Life 打日志）。
  # 顺带丢掉窗口外的时刻，账不随见过的人数无限变长。
  defp admit(ledger, [], _now_ms), do: {ledger, [], []}

  defp admit(ledger, candidates, now_ms) do
    written =
      for {key, times} <- ledger.written,
          recent = Enum.filter(times, &(now_ms - &1 < @cap_window_ms)),
          recent != [],
          into: %{},
          do: {key, recent}

    {ledger, entries, capped} =
      Enum.reduce(candidates, {%{ledger | written: written}, [], []}, fn
        {kind, actor, entry}, {ledger, entries, capped} ->
          times = Map.get(ledger.written, {kind, actor}, [])

          if length(times) < @cap_entries do
            ledger = put_in(ledger, [:written, {kind, actor}], [now_ms | times])
            {ledger, [entry | entries], capped}
          else
            ledger = update_in(ledger, [:capped, kind], &(&1 + 1))
            {ledger, entries, [%{actor: actor, kind: kind} | capped]}
          end
      end)

    {ledger, Enum.reverse(entries), Enum.reverse(capped)}
  end

  defp entry(id, at_ms, text, tags),
    do: %{"id" => id, "at_ms" => at_ms, "text" => text, "tags" => tags}

  defp names(nil), do: %{}
  defp names(observation), do: Map.new(State.others(observation), &{&1.entity_id, &1.name})

  defp count(1, noun), do: "1 #{noun}"
  defp count(n, noun), do: "#{n} #{noun}s"
end
