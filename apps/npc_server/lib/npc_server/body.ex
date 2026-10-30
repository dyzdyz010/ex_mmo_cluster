defmodule NpcServer.Body do
  @moduledoc """
  全局系统功能：NPC 的无 socket 会话 owner。以 NPC cid 走 `WorldServer.Session` 的完整 claim，作为常驻控制器；
  权威状态只在 `Movement.Player`，本进程的位置与邻近实体是下行消息的派生缓存。决策在 `NpcServer.Brain`，
  本进程只执行它的语义命令并回报结果。

  输入由 OwnerAck 闭环驱动：`due_seq = server_tick - origin_tick + 1`，把已送序号连续补到 `due_seq + 8`；
  已过期未送的序号填零输入，移动命令只写未来槽。

  世界事务与玩家同一条裁决：`NpcServer.WorldRequest` 把命令拼成与线解码同形的 `{kind, request}`，交给
  Gate 为玩家调用的同一个入口 `SceneServer.Movement.Intent.run/3`——工具经 `ToolAction.run/5`（`authorize_tool`：
  死亡、施法互斥、重放、同 key 结果、人物目标 g5），生产 / 附件 / prefab 经 `Player.tool_context/2`，再到 World 公共 API。
  Body 不复刻任何权威门；它自己的信任边界只有命令的模式匹配与类型守卫（`WorldRequest.build/2` 返回 nil →
  `:invalid_command`）。只读感知（look / survey / inspect）走 `material_snapshot/3` 与 `simulation_snapshot/3`，余额读 `material_balances/2`。
  所有角色都可放置 prefab，与玩家过同一道部署门：涉及的格在编辑盒（`:voxel_region, :edit_bounds`）内，
  与玩家连接共用 `EditBounds.prefab_within?/4`，越界回 `:out_of_bounds`。`say` 经同一执行进程调用 Scene.say；台词只认权威 Speech 回声。
  目录读取（`read_catalog`）经 `NpcServer.Perception.read/3` 读 World 的公共只读目录。
  创世编辑（`genesis_edit`，能力组 `:genesis`，见 `NpcServer.Genesis`）只在启动选项 `genesis: true` 时受理，否则
  `:not_permitted`；`Genesis.prepare/3` 校验后由执行进程以主体 `{:genesis, cid}` 交给 `World.apply_edits/3`（授权与保护区见 `VoxelRegion.Access`）。

  正式生成入口是 `start/2`：名字即 NPC 的永久身份（同名永远同一 cid，同 cid 最后完成 claim 的 Body 留下），阵营档案取
  `DataService.Orgs.profile/1`（与玩家登录同一函数），claim 时作为 `profile` 交给 Scene，别人看到的名牌与关系由它算出。
  经 `start/2` 起的 Body 以 cid 登记在 `NpcServer.Names`（重复键 Registry，崩溃重启后在 init 里重新登记），
  注册表 `NpcServer.Registry` 据此找到在跑的 Body。
  调用可能长时间阻塞，由本进程旁的 FIFO 执行进程承担，Body 继续送帧；意图的到达时刻（`received_us`）在受理命令时冻结。
  执行进程对世界调用的退出只判一件事：会话的 Player 已退出 → `:session_lost`；否则照常退出，由监督者重启 Body。
  余额的真值在 World，这里按 Intent 的补发规则（与 Gate 给玩家补发余额同一条）在世界事务之后重取一份。

  施法（`cast_spell` / `cancel_cast`）与玩家同一个角色 owner 入口 `Player.cast_spell/5`，不经 Intent（前摇是 Player 的
  异步协议）：执行进程读 `World.magic_digest/1` 填入请求后投递，回复目标是 `{本进程, {:npc_cast, id}}`。施法登记在在途
  世界事务表里（id → `:cast_spell`），`{{:npc_cast, id}, 结果}`（结算、立即拒绝、取消、World 侧会话结束）是它唯一的
  Outcome 来源；`{:mmo_spell_reply, …}` 只更新 Observation 的 `self.caster`。取消要用的请求按 id 记在 `casts`，
  `cancel_cast` 取最早提交、还没有终态的那次（执行进程按提交顺序投递，后提交的在它前摇时只会被 `cast_too_soon` 拒绝）。
  投给已退出 Player 的施放没有回复，由本进程收尾：会话丢失时在途施法以 `session_lost` 结束；跨 Scene 移交后仍监视旧 Player，
  它退出时移交前提交、仍无终态的施法同样以 `session_lost` 结束。之后迟到的回复因表中无 id 被忽略：每次施法恰好一个终态。

  `move_to` 带寻路：起步时经 `World.material_snapshot/3` 取一盒地形（与 `look` 同一个只读入口），交给
  `SceneServer.Movement.Path` 算出路点后即丢弃，不留体素副本；台阶高度与角色高度取自权威随 SessionStart 下发的
  移动 profile（玩家客户端收到的同一份）。哪些格能踩、能穿过只用 `NpcServer.Perception.walk_kind/1`（细化格与液体
  既不能踩也不能穿过）；起点是身体的权威位置（`Path.find/7` 的 `trusted_start`）。Body 不重试：走不通回报 `:no_path`，
  路上被堵回报 `:stuck`，由 Brain 决定。
  会话由本进程自己维护：积压、Scene 结束会话、Player 结束、移交失败或 claim 失败时不退出，稍后重新 claim，
  Brain / Runtime 与在途技能不受影响；被同一 cid 的新 claim 顶替时正常结束。契约见本目录 README。
  设计见 docs/10-active/cross-cutting/2026-09-21-npc-unified-interface-design.md；世界意图入口见
  docs/10-active/cross-cutting/2026-10-07-character-capability-library.md §7。
  """
  # transient：会话丢失由 Body 自己重新 claim，不经监督者；只有崩溃才重启，被同 cid 顶替（{:shutdown, :replaced}）不重启。
  use GenServer, restart: :transient
  require Logger
  alias MmoContracts.{Movement, Session}
  alias VoxelRegion.EditBounds
  alias SceneServer.Movement.{Intent, Path, Player, ToolAction}
  alias VoxelRegion.World
  alias NpcServer.{Attention, Context, Genesis, Perception, Sight, WorldRequest}
  @attention_verbs Attention.verbs()
  # 世界写意图的动词（经 WorldRequest 拼成线同形请求：施法 0x82 交给 Player.cast_spell/5，其余进 Intent.run/3）；
  # 余额（生产 action 0）与 Gate 一样直接读 material_balances，不进事务。
  @world_verbs WorldRequest.verbs()
  @prefab_kinds [:voxel_prefab_place_v1, :voxel_prefab_remove_v1, :voxel_prefab_replace_v1]

  @lead 8
  @backlog 120
  # 会话丢失或 claim 失败后多久再 claim（毫秒）。
  @reclaim_ms 1_000
  @outcomes 32
  # look 的上限：Brain 是外部输入，而快照在 World 进程内逐格求值、冷区域还会触发生成。
  @look_reach NpcServer.Perception.reach()
  # 寻路取盒：起终点包围盒水平外扩 @path_margin 格、上下各 @path_margin 格；单程水平不超过 @look_reach。
  @path_margin 6
  # 这么多 tick 里挪动不到 @stall_m 米 = 被堵住（60 Hz，3 秒）。
  @stall_ticks 180
  @stall_m 0.5
  # 中途点走到这么近（或已越过）就换下一个。
  @waypoint_m 0.25
  # 拐弯、换层与到达前的限速（m/s）：输入没有模拟量（权威把方向归一化），已送出的 @lead 帧也改不了，
  # 全速 8 m/s 下一次转向要滞后 1 米多，会绕着路点打转。限速靠夹零输入帧实现，与玩家点按方向键同理。
  @corner_speed 2.0
  # 移动完成要等身体停稳：权威速度（m/s）不超过这个值；零输入帧处理后最多再等这么多 tick（60 Hz，1 秒）。
  @settled_speed 0.05
  @settle_ticks 60

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @doc """
  正式生成入口：在 `NpcServer.BodySupervisor` 下起一个 NPC。`name` 即永久身份：`DataService.CharacterStore.ensure_npc/1`
  对同名永远返回同一 cid；名字已属于玩家角色时崩溃。名字唯一由调用方（作者 / 部署脚本）保证。
  同 cid 最后完成 claim 的 Body 留下：先起的 Body 持有会话时被顶替、以 `{:shutdown, :replaced}` 结束；它若正处于
  重新 claim（会话丢失后约 1 秒内，或 Scene 未就绪时的重试中），收不到顶替，稍后自己的 claim 反过来顶掉后起的。
  要换掉同名 NPC，先停旧 Body 再 start（`NpcServer.Registry.put/2` 就这样做）。阵营档案 = `DataService.Orgs.profile/1`。
  `opts` 同 `start_link/1`（`scene_id`、`spawn`、`brain`、`genesis` 等），`cid`、`faction` 与在 `NpcServer.Names` 的登记由这里填。
  """
  def start(name, opts) do
    with {:ok, character} <- DataService.CharacterStore.ensure_npc(name) do
      faction = DataService.Orgs.profile(character)

      DynamicSupervisor.start_child(
        NpcServer.BodySupervisor,
        {__MODULE__,
         Keyword.merge(opts, cid: character.id, faction: faction, names: NpcServer.Names)}
      )
    end
  end

  @doc "进程外 / 慢 Brain 异步投回命令；形状见 `NpcServer.Brain`。"
  def command(body, command), do: GenServer.cast(body, {:command, command})

  @doc "派生缓存、在途命令与最近的 Outcome（新在前）；不是世界真值。"
  def observe(body), do: GenServer.call(body, :observe)

  @doc "通过既有 Runtime 受理一次手动 LLM 决策；结果异步发送给 observer，Body 不等待模型请求。"
  def step(body, observer, tag, context \\ %{}) when is_pid(observer) and is_map(context),
    do: GenServer.call(body, {:step, observer, tag, context})

  @doc "慢技能取得当前正式会话上下文；不暴露 Body 或 World 的可变状态。"
  def skill_context(body), do: GenServer.call(body, :skill_context)

  @doc "寻路取盒在起终点包围盒外扩的格数（水平与竖直）；不给 `y` 时竖直只覆盖脚所在格上下这么多格。"
  def path_margin, do: @path_margin

  @doc """
  脚所在的格：`position` 是胶囊中心，中心下移半高；+0.5 容忍贴地的 skin / snap。寻路的起点、travel 选段终点站立层都用它。
  """
  def foot({px, py, pz}, half_height), do: {floor(px), floor(py - half_height + 0.5), floor(pz)}

  @doc "canonical X/Z 世界轴上的量化输入与朝向；yaw 不驱动移动，0 朝 +X、16384 朝 +Z。"
  def steer({x, _, z}, {tx, tz}) do
    {dx, dz} = {tx - x, tz - z}
    length = :math.sqrt(dx * dx + dz * dz)
    yaw = rem(round(:math.atan2(dz, dx) * 65536 / (2 * :math.pi())) + 65536, 65536)
    {round(dx / length * 32767), round(dz / length * 32767), yaw}
  end

  @doc "sent 之后到 due+lead 的连续帧：seq ≤ due 已过期填零输入，其余用 steering。"
  def frames(sent, due, yaw, {axis_x, axis_z, target_yaw}) do
    for seq <- (sent + 1)..(due + @lead)//1 do
      if seq <= due,
        do: %Movement.InputFrame{input_seq: seq, axis_x: 0, axis_z: 0, yaw: yaw, jump_pressed: 0},
        else: %Movement.InputFrame{
          input_seq: seq,
          axis_x: axis_x,
          axis_z: axis_z,
          yaw: target_yaw,
          jump_pressed: 0
        }
    end
  end

  @impl true
  def init(opts) do
    {brain, profile} = Keyword.fetch!(opts, :brain)

    # 正式入口（start/2）起的 Body 按 cid 登记，供注册表查找；重复键：同 cid 的新旧 Body 交接时可以短暂并存。
    if names = Keyword.get(opts, :names),
      do: {:ok, _} = Registry.register(names, Keyword.fetch!(opts, :cid), nil)

    {:ok,
     %{
       # cid 来自 characters 表的 NPC 行（DataService.CharacterStore.ensure_npc/1），永久且不复用。
       cid: Keyword.fetch!(opts, :cid),
       # 显式出生点：不占玩家 probe 名额。
       spawn: Keyword.fetch!(opts, :spawn),
       # 阵营档案（`MmoContracts.Relation` 形状，见 start/2）；nil = 无组织、无名字，Scene 按空档案处理。
       faction: Keyword.get(opts, :faction),
       claims: Keyword.get(opts, :claims, WorldServer.Session),
       scene: Keyword.get(opts, :scene_module, SceneServer.Movement.Scene),
       router: Keyword.get(opts, :route_module, WorldServer.Movement),
       scene_id: Keyword.fetch!(opts, :scene_id),
       # 与玩家 QUIC 连接同一份部署编辑盒。
       bounds: Keyword.get(opts, :bounds, Application.get_env(:voxel_region, :edit_bounds)),
       # 创世授予（NpcServer.Genesis）：唯一来源是注册表行，与 Brain 的 profile.genesis 同源。
       genesis: Keyword.get(opts, :genesis, false) == true,
       mind:
         NpcServer.Runtime.init({brain, profile}, %{
           cid: Keyword.fetch!(opts, :cid),
           scene_id: Keyword.fetch!(opts, :scene_id),
           router: Keyword.get(opts, :route_module, WorldServer.Movement)
         }),
       # 世界调用的 FIFO 执行进程跨会话保留：在途调用总会有结果，不因重新 claim 丢失。
       worker: spawn_link(&world_calls/0),
       identity: nil,
       # 权威下发的移动 profile（SessionStart）；寻路的台阶高度与角色高度取自它。
       profile: nil,
       player: nil,
       player_monitor: nil,
       world_ref: nil,
       origin: nil,
       sent: 0,
       yaw: 0,
       position: nil,
       velocity: {0.0, 0.0, 0.0},
       # 已送出、权威还没处理的帧：[{seq, 是否带方向}]；限速用它推算这些帧生效后的速度。
       inflight: [],
       tick: 0,
       processed: 0,
       # 本人身体的推导视图（Session.BodyState 原样，转成普通 map）；nil = 本会话还没收到。
       body_state: nil,
       entities: %{},
       attention: Attention.new(),
       # 在途移动命令：%{id, verb, target, tolerance, zero_from, path, from, mark}；zero_from = 首个零输入帧的序号，
       # path = :planning | 剩余要走到的水平点（末项恒为 target），from = 当前这一段的起点，
       # mark = {position, tick}：上次挪动超过 @stall_m 时的位置与 tick。
       move: nil,
       # 在途世界事务：id => verb（施法同样登记在这里，终态只按这张表收尾）。
       world: %{},
       # 在途施放的请求：id => request（world 里同一 id 是 :cast_spell）；取消用其中最早提交的那次（同一 client_intent_seq，
       # 见 WorldRequest.cancel/2）。
       casts: %{},
       # 移交后仍在监视的旧 Player：monitor ref => 移交时在途的施法 id；旧 Player 退出时其中仍无终态的以 session_lost 结束。
       retired: %{},
       # 最近一次施法回复里的施法者状态 %{energy_j, capacity_j, coherence}；nil = 还没施过法。派生缓存，真值在 World。
       caster: nil,
       request_seq: 0,
       # 对话请求号独立于 Brain 的任意 term 命令 id；不自动重发。
       speech_seq: 0,
       # World 返回的余额表原样；nil = 还没取过（`query_balances` 或任一次世界事务之后才有）。
       balances: nil,
       outcomes: []
     }, {:continue, :claim}}
  end

  @impl true
  def handle_continue(:claim, state), do: claim(state)

  # 与玩家客户端断线重连同理：会话是 Body 自己维护的不变量。claim 失败（Scene 未就绪、正在重启）稍后再试，
  # 不靠退出让监督者重启——一次 Scene 重启会让所有 NPC 同时退出，超出监督者重启强度后整组永久消失。
  defp claim(state) do
    with {:ok, route} <- state.router.route(state.scene_id),
         {identity, {:ok, player}} <-
           WorldServer.Session.claim(
             state.claims,
             state.scene,
             Map.put(route, :scene_id, state.scene_id),
             %{id: state.cid, spawn: state.spawn, kind: "npc", profile: state.faction}
           ) do
      # 只用于置 clock_ready；送帧不依赖本地时钟映射。
      Player.time_probe(player, identity, %Session.TimeProbe{request_id: 1, client_send_us: 0})

      {:noreply,
       %{
         state
         | identity: identity,
           player: player,
           player_monitor: Process.monitor(player),
           world_ref: Map.get(route, :world_ref)
       }}
    else
      failure ->
        Logger.warning(
          "npc_claim_failed cid=#{state.cid} scene_id=#{state.scene_id} result=#{inspect(failure)}"
        )

        Process.send_after(self(), :claim, @reclaim_ms)
        {:noreply, state}
    end
  end

  # 会话没了：移动命令随会话作废（权威不再处理这些输入），在途世界调用保留、各自回结果；稍后重新 claim。
  # Body 与 Brain / Runtime 不重启，记忆、在途技能与 Outcome 历史都还在。
  defp lose_session(state, reason) do
    Logger.warning("npc_session_lost cid=#{state.cid} reason=#{inspect(reason)}")
    if state.player_monitor, do: Process.demonitor(state.player_monitor, [:flush])
    Process.send_after(self(), :claim, @reclaim_ms)

    # 施法的回复只按 reply_to 来、执行进程不再兜底：会话没了，在途施法在这里以 session_lost 结束（见 lose_casts/2）。
    # 其余世界调用照常各回结果。
    casts = for {id, :cast_spell} <- state.world, do: id

    state = %{
      state
      | identity: nil,
        player: nil,
        player_monitor: nil,
        profile: nil,
        origin: nil,
        sent: 0,
        yaw: 0,
        position: nil,
        velocity: {0.0, 0.0, 0.0},
        inflight: [],
        processed: 0,
        # 新会话的 Player 入场时会再发一份。
        body_state: nil,
        # 重新入场后实体代次可能已变：关注随已同步实体一起清空，与换场景相同。
        entities: %{},
        attention: Attention.new()
    }

    state = lose_casts(state, casts)

    case state.move do
      nil ->
        state

      move ->
        emit(%{state | move: nil}, %{
          id: move.id,
          verb: move.verb,
          status: :rejected,
          reason: :session_lost,
          data: nil
        })
    end
  end

  @impl true
  def handle_call({:step, observer, tag, context}, from, state) do
    send(state.mind, {:step_body, from, observer, tag, context})
    {:noreply, state}
  end

  def handle_call(:observe, from, state) do
    snapshot =
      Map.take(state, [
        :position,
        :tick,
        :move,
        :world,
        :entities,
        :attention,
        :balances,
        :outcomes
      ])

    # Runtime 补自己的对话尾部后直接回复调用者，Body 不等待心智/记忆处理。
    send(state.mind, {:observe_body, from, snapshot})
    {:noreply, state}
  end

  def handle_call(
        :skill_context,
        _,
        %{player: player, identity: identity, profile: profile} = state
      )
      when player != nil and profile != nil do
    result =
      with {:ok, actor} <- tool_context(player, identity),
           {:ok, route} <- state.router.route(state.scene_id),
           do:
             {:ok,
              %{
                actor: actor,
                world: state.world_ref,
                scene: route.scene_ref,
                movement_profile: profile
              }}

    {:reply, result, state}
  end

  def handle_call(:skill_context, _, state), do: {:reply, {:error, :invalid_session}, state}

  @impl true
  def handle_cast({:command, command}, state), do: {:noreply, apply_commands(state, [command])}

  @impl true
  def handle_info(
        {:mmo_reliable, identity, 1, %Session.SessionStart{} = start},
        %{identity: identity} = state
      ) do
    # 内部会话就绪：无头 Body 不建体素镜像，只回 baseline。
    Player.ready(
      state.player,
      identity,
      start.baseline_transaction_seq,
      start.collision_revision
    )

    {:noreply, %{state | profile: start.profile}}
  end

  def handle_info(
        {:mmo_reliable, identity, 1, %Session.InputStart{first_input_seq: 1} = start},
        %{identity: identity} = state
      ),
      do:
        {:noreply, feed(%{state | origin: start.origin_tick}, start.state, start.anchor_tick, 0)}

  def handle_info(
        {:mmo_datagram, identity, %Movement.OwnerAck{} = ack},
        %{identity: identity, origin: origin} = state
      )
      when origin != nil do
    due = ack.server_tick - origin + 1

    if due - ack.processed_input_seq > @backlog,
      do: {:noreply, lose_session(state, {:input_backlog, due, ack.processed_input_seq})},
      else: {:noreply, feed(state, ack.state, ack.server_tick, ack.processed_input_seq)}
  end

  # 本人身体的推导视图（与玩家 HUD 同一条下行）：字段原样，结构体转成普通 map 进 Observation。
  def handle_info(
        {:mmo_reliable, identity, 1, %Session.BodyState{} = s},
        %{identity: identity} = state
      ) do
    body_state =
      Map.take(s, [:life, :recoverable, :status, :core_k, :skin_k, :protein_g])
      |> Map.put(:injuries, Enum.map(s.injuries, &Map.from_struct/1))

    {:noreply, %{state | body_state: body_state}}
  end

  # 台词自带权威发言人身份，不依赖 EntityEnter 的到达顺序；本人回声不作为外界唤醒。
  def handle_info(
        {:mmo_reliable, identity, 1, %Session.Speech{} = speech},
        %{identity: identity} = state
      ) do
    message = speech |> Map.from_struct() |> Map.delete(:identity)
    event = if speech.speaker_id == state.cid, do: :said, else: :heard

    Logger.info(
      "dialogue.speech receiver=#{state.cid} conversation_id=#{speech.conversation_id} turn=#{speech.turn} speaker=#{speech.speaker_id} target=#{speech.target_id}"
    )

    {:noreply, think(state, {event, message})}
  end

  # 名字与关系（按本角色这个观察者算）只随 EntityEnter 来，保留到 Leave 或换代；Snapshot 只更新位置。
  def handle_info(
        {:mmo_reliable, identity, 1, %Session.EntityEnter{} = e},
        %{identity: identity} = state
      ) do
    entity = %{
      entity_epoch: e.entity_epoch,
      kind: e.kind,
      name: e.name,
      relation: e.relation,
      relation_source: e.relation_source,
      tick: e.server_tick,
      position: e.state.position
    }

    attention =
      case state.entities[e.entity_id] do
        %{entity_epoch: epoch} when epoch != e.entity_epoch ->
          Attention.forget(state.attention, e.entity_id)

        _ ->
          state.attention
      end

    {:noreply,
     %{state | entities: Map.put(state.entities, e.entity_id, entity), attention: attention}}
  end

  def handle_info(
        {:mmo_reliable, identity, 1, %Session.EntityLeave{} = e},
        %{identity: identity} = state
      ) do
    case state.entities[e.entity_id] do
      %{entity_epoch: epoch} when epoch == e.entity_epoch ->
        {:noreply,
         %{
           state
           | entities: Map.delete(state.entities, e.entity_id),
             attention: Attention.forget(state.attention, e.entity_id)
         }}

      _ ->
        {:noreply, state}
    end
  end

  def handle_info(
        {:mmo_datagram, identity, %Movement.Snapshot{} = snapshot},
        %{identity: identity} = state
      ) do
    # 只更新仍是同一 entity_epoch 的已知实体；每个实体保留自己的 tick。
    entities =
      Enum.reduce(snapshot.records, state.entities, fn r, entities ->
        case Map.get(entities, r.entity_id) do
          %{entity_epoch: epoch} = known when epoch == r.entity_epoch ->
            Map.put(entities, r.entity_id, %{
              known
              | tick: snapshot.server_tick,
                position: r.state.position
            })

          _ ->
            entities
        end
      end)

    {:noreply, %{state | entities: entities}}
  end

  def handle_info({:npc_world_result, id, result, balances}, state)
      when is_map_key(state.world, id) do
    {verb, world} = Map.pop(state.world, id)

    outcome =
      case result do
        {:ok, %{} = data} -> %{id: id, verb: verb, status: :done, reason: nil, data: data}
        {:ok, seq} -> %{id: id, verb: verb, status: :done, reason: nil, data: %{seq: seq}}
        {:error, reason} -> %{id: id, verb: verb, status: :rejected, reason: reason, data: nil}
      end

    {:noreply,
     emit(
       %{
         state
         | world: world,
           casts: Map.delete(state.casts, id),
           balances: balances || state.balances
       },
       outcome
     )}
  end

  # 施法的唯一 Outcome 来源：Player / World 以 GenServer.reply 发往 reply_to 的回复（结算 `{:ok, %{seq, outcome, caster}}`、
  # 立即拒绝、取消 `cast_cancelled`、World 侧会话结束 `invalid_session`），与世界事务结果同一映射；id 已不在表中时忽略。
  def handle_info({{:npc_cast, id}, result}, state),
    do: handle_info({:npc_world_result, id, result, nil}, state)

  # 成功报价 / 结算时 World 先发给 caster_recipient 的施法者状态：只更新 Observation 的 self.caster，不产生 Outcome。
  def handle_info({:mmo_spell_reply, {:npc_cast, _}, _request, %{caster: caster}}, state),
    do: {:noreply, %{state | caster: Map.take(caster, [:energy_j, :capacity_j, :coherence])}}

  def handle_info({:npc_path, id, result}, %{move: %{id: id, path: :planning} = move} = state) do
    case result do
      {:ok, path} ->
        {:noreply,
         %{
           state
           | move: %{
               move
               | path: path,
                 from: flat(state.position),
                 mark: {state.position, state.tick}
             }
         }}

      {:no_path, diagnostic} ->
        {:noreply, reject_move(state, :no_path, diagnostic)}

      # 取盒时会话的 Player 已退出（执行进程的退出规则）。
      {:error, reason} ->
        {:noreply, reject_move(state, reason)}
    end
  end

  # 2 = 同一 cid 被新的 claim 顶替：另一个 Body 已接管，本进程正常结束，避免两个 Body 互相顶替。
  def handle_info({:mmo_close, identity, 2}, %{identity: identity} = state),
    do: {:stop, {:shutdown, :replaced}, state}

  def handle_info({:mmo_close, identity, reason}, %{identity: identity} = state),
    do: {:noreply, lose_session(state, {:session_closed, reason})}

  def handle_info(:claim, %{player: nil} = state), do: claim(state)

  # 跨 Scene 移交，与玩家连接同一条路：seal 源 → Claims 预留并在目标 Scene 准备 → 提交。玩家要等客户端换好世界再回
  # Ready 才提交；无头 Body 没有要换的东西，准备好就提交。输入序号与 origin 随切点延续，在途的移动命令照常继续。
  # 任一步失败按会话丢失处理：Body 自己重新 claim（玩家连接在同样情形下是断开重连）。
  def handle_info(
        {:mmo_transfer_request, identity, player, target},
        %{identity: identity, player: player} = state
      ) do
    with {:ok, artifact} <- Player.seal(player, identity),
         {:ok, fresh, route, next} <-
           WorldServer.Session.prepare_transfer(state.claims, identity, target, artifact),
         :ok <- WorldServer.Session.commit_transfer(state.claims, identity, fresh, state.cid) do
      # 旧 Player 已 seal：它处理过的施放都已回复（前摇中的被 seal 撤销，World 回 cast_cancelled），之后投给它的回
      # invalid_state；执行进程投递时它已退出的，没有任何回复。所以有在途施法时留着对旧 Player 的监视（见 retired）。
      # 旧会话的施法不能再取消（取消按新会话身份匹配），从 casts 里去掉。
      casts = for {id, :cast_spell} <- state.world, do: id

      retired =
        if casts == [] do
          Process.demonitor(state.player_monitor, [:flush])
          state.retired
        else
          Map.put(state.retired, state.player_monitor, casts)
        end

      Logger.info(
        "npc_transfer cid=#{state.cid} old_scene=#{identity.scene_id} new_scene=#{target} cut=#{artifact.simulation_tick}"
      )

      {:noreply,
       %{
         state
         | identity: fresh,
           player: next,
           player_monitor: Process.monitor(next),
           casts: %{},
           retired: retired,
           scene_id: target,
           world_ref: Map.get(route, :world_ref),
           entities: %{},
           attention: Attention.new()
       }}
    else
      {:error, reason} -> {:noreply, lose_session(state, {:transfer_failed, target, reason})}
    end
  end

  def handle_info({:DOWN, _, :process, player, reason}, %{player: player} = state),
    do: {:noreply, lose_session(state, {:player_down, reason})}

  # 移交前的旧 Player 退出：移交时在途、至今仍无终态的施法再也不会有回复。
  def handle_info({:DOWN, ref, :process, _, _}, state) when is_map_key(state.retired, ref) do
    {casts, retired} = Map.pop(state.retired, ref)
    {:noreply, lose_casts(%{state | retired: retired}, casts)}
  end

  def handle_info({:npc_runtime_outcome, outcome}, state),
    do: {:noreply, %{state | outcomes: Enum.take([outcome | state.outcomes], @outcomes)}}

  def handle_info(_, state), do: {:noreply, state}

  defp feed(state, %Session.State{} = session, server_tick, processed) do
    due = max(0, server_tick - state.origin + 1)

    state =
      %{
        state
        | position: session.position,
          velocity: session.velocity,
          tick: server_tick,
          processed: processed,
          inflight: Enum.drop_while(state.inflight, fn {seq, _} -> seq <= processed end)
      }
      |> finish_move()

    state = think(state, {:observation, observation(state, session)})
    {state, {_, _, yaw} = steering, limit} = steering(state, due)
    {frames, inflight} = govern(state, frames(state.sent, due, state.yaw, steering), limit)
    state = %{state | inflight: inflight}

    # 与玩家解码器同一批约束：每批 1..6 帧、序号严格递增；相邻差 1 由 frames/4 保证。
    for batch <- Enum.chunk_every(frames, 6),
        do:
          Player.input(state.player, state.identity, %Movement.InputBatch{
            identity: state.identity,
            frames: batch
          })

    case frames do
      [] -> state
      _ -> %{state | sent: List.last(frames).input_seq, yaw: yaw}
    end
  end

  defp observation(state, session) do
    %{
      self: %{
        entity_id: state.cid,
        scene_id: state.scene_id,
        body: NpcServer.Context.body(state.profile),
        tick: state.tick,
        position: session.position,
        yaw: session.yaw,
        grounded: session.grounded,
        processed_input_seq: state.processed,
        body_state: state.body_state,
        caster: state.caster
      },
      entities: for({id, e} <- state.entities, do: Map.put(e, :entity_id, id)),
      view: Attention.view(state.attention, Player.eye_position(state.position)),
      targets: Map.take(state.attention, [:enemy, :friendly, :mark]),
      balances: state.balances,
      pending:
        if(state.move, do: [Map.take(state.move, [:id, :verb])], else: []) ++
          for({id, verb} <- state.world, do: %{id: id, verb: verb})
    }
  end

  # 首个零输入帧已被权威处理、且身体停稳（权威速度 ≤ @settled_speed）→ 移动命令完成；position、within_tolerance
  # 与 settled 取自同一份 ACK。零输入后身体还会按刹车 / 摩擦滑行一段：在那之前报完成，紧接着按 done 位置瞄准的
  # 探测 / 工具会从已经挪开的眼点出发打到别的格（2026-10-08 Demo 实跑 gather 首轮 stale_target）。
  # 最多再等 @settle_ticks：坡上 / 被推着时可能停不稳，此时照样完成，settled 为 false。
  # 带 settle 的 stop（取消技能）还要等该技能已投递的世界调用全部有了结果，之后不会再有它引起的世界变化。
  defp finish_move(%{move: %{zero_from: zero} = move, processed: processed} = state)
       when zero != nil and processed >= zero do
    move = Map.put_new(move, :zero_tick, state.tick)
    call = Map.get(move, :settle)
    settled = speed(state.velocity) <= @settled_speed

    cond do
      call != nil and Enum.any?(Map.keys(state.world), &match?({:skill, ^call, _}, &1)) ->
        %{state | move: move}

      settled or state.tick - move.zero_tick >= @settle_ticks ->
        finish_settled_move(state, move, settled)

      true ->
        %{state | move: move}
    end
  end

  defp finish_move(state), do: state

  defp finish_settled_move(state, move, settled) do
    within = move.target == nil or distance(state.position, move.target) <= move.tolerance

    emit(%{state | move: nil}, %{
      id: move.id,
      verb: move.verb,
      status: :done,
      reason: nil,
      data: %{position: state.position, within_tolerance: within, settled: settled}
    })
  end

  defp speed({vx, vy, vz}), do: :math.sqrt(vx * vx + vy * vy + vz * vz)

  defp steering(%{move: %{zero_from: nil, path: :planning}} = state, _due),
    do: {state, {0, 0, state.yaw}, 0.0}

  # 移动命令只写未来槽：零输入从下一个未送且未过期的序号开始。
  defp steering(%{move: %{zero_from: nil, verb: :stop} = move} = state, due),
    do: {%{state | move: %{move | zero_from: max(state.sent, due) + 1}}, {0, 0, state.yaw}, 0.0}

  defp steering(%{move: %{zero_from: nil} = move} = state, due) do
    move = advance(move, state.position)
    [target | rest] = move.path
    {marked, since} = move.mark

    move =
      if distance(state.position, flat(marked)) > @stall_m,
        do: %{move | mark: {state.position, state.tick}},
        else: move

    cond do
      rest == [] and distance(state.position, target) <= move.tolerance ->
        {%{state | move: %{move | zero_from: max(state.sent, due) + 1}}, {0, 0, state.yaw}, 0.0}

      state.tick - since > @stall_ticks ->
        {reject_move(%{state | move: move}, :stuck), {0, 0, state.yaw}, 0.0}

      true ->
        # 从“已送帧生效时”的预计位置瞄准，抵消送帧提前量带来的转向滞后。
        {px, _, pz} = state.position
        {vx, _, vz} = state.velocity
        ahead = @lead / state.profile.fixed_hz

        aim =
          Enum.find(
            [{px + vx * ahead, 0.0, pz + vz * ahead}, state.position],
            &(distance(&1, target) > 0.05)
          )

        # 每个路点都是拐点、换层点或终点：离它还有多远就允许多快（v² = 2·braking·d），不低于拐弯速度。
        limit =
          max(
            @corner_speed,
            :math.sqrt(2 * state.profile.braking * distance(state.position, target))
          )

        {%{state | move: move}, if(aim, do: steer(aim, target), else: {0, 0, state.yaw}), limit}
    end
  end

  defp steering(state, _due), do: {state, {0, 0, state.yaw}, 0.0}

  # 中途点：走近了、或沿这一段的方向已经越过它，就换下一个；末项（target）由 tolerance 判定，不在这里丢。
  defp advance(
         %{path: [{wx, wz} = point, _ | _] = path, from: {fx, fz}} = move,
         {px, _, pz} = position
       ) do
    passed = (px - wx) * (wx - fx) + (pz - wz) * (wz - fz) >= 0

    if passed or distance(position, point) <= @waypoint_m,
      do: advance(%{move | path: tl(path), from: point}, position),
      else: move
  end

  defp advance(move, _position), do: move

  defp flat({x, _, z}), do: {x, z}

  # 逐帧限速：按已送未处理的帧推算生效时的水平速度（带方向帧 +acceleration/hz，零输入帧按 braking 与摩擦减速），
  # 超过 limit 的帧改成零输入。模型只用来决定夹不夹帧；位置真值始终是权威的 ACK。
  defp govern(state, frames, limit) do
    profile = state.profile
    {vx, _, vz} = state.velocity

    advance = fn speed, on ->
      if on,
        do: min(profile.speed, speed + profile.acceleration / profile.fixed_hz),
        else:
          max(
            0.0,
            speed -
              (profile.braking + profile.friction * profile.braking_friction_factor * speed) /
                profile.fixed_hz
          )
    end

    speed =
      Enum.reduce(state.inflight, :math.sqrt(vx * vx + vz * vz), fn {_, on}, speed ->
        advance.(speed, on)
      end)

    {frames, {_, sent}} =
      Enum.map_reduce(frames, {speed, []}, fn frame, {speed, sent} ->
        on = (frame.axis_x != 0 or frame.axis_z != 0) and speed < limit
        frame = if on, do: frame, else: %{frame | axis_x: 0, axis_z: 0}
        {frame, {advance.(speed, on), [{frame.input_seq, on} | sent]}}
      end)

    {frames, state.inflight ++ Enum.reverse(sent)}
  end

  defp distance({x, _, z}, {tx, tz}), do: :math.sqrt((tx - x) * (tx - x) + (tz - z) * (tz - z))

  defp think(state, event) do
    {commands, mind} = NpcServer.Runtime.handle_event(event, state.mind)
    apply_commands(%{state | mind: mind}, commands)
  end

  defp emit(state, outcome) do
    state = %{state | outcomes: Enum.take([outcome | state.outcomes], @outcomes)}
    think(state, {:outcome, outcome})
  end

  defp apply_commands(state, commands), do: Enum.reduce(commands, state, &apply_command(&2, &1))

  defp apply_command(%{position: nil} = state, %{id: _, verb: verb} = command)
       when verb in @attention_verbs,
       do: attention_result(state, command, {:error, :invalid_session})

  defp apply_command(state, %{id: _, verb: verb} = command)
       when verb in [:get_aim, :get_visible_entities, :get_target_status] do
    entities = for {id, e} <- Enum.sort(state.entities), do: Map.put(e, :entity_id, id)

    selected =
      if verb == :get_target_status,
        do: Attention.resolve(state.entities, Map.get(command, :target)),
        else: {:ok, entities}

    case selected do
      {:error, :stale_target} ->
        attention_result(
          state,
          command,
          {:ok, state.attention, %{valid: false, reason: :stale_target, target: command.target}}
        )

      {:error, reason} ->
        attention_result(state, command, {:error, reason})

      {:ok, selected} ->
        query = %{
          verb: verb,
          view: Attention.view(state.attention, Player.eye_position(state.position)),
          tick: state.tick,
          scene_id: state.scene_id,
          session_epoch: state.identity.session_epoch,
          entities: List.wrap(selected),
          profile: state.profile
        }

        submit(state, command.id, {:sight, query})
        %{state | world: Map.put(state.world, command.id, verb)}
    end
  end

  defp apply_command(state, %{id: _, verb: verb} = command) when verb in @attention_verbs,
    do:
      attention_result(
        state,
        command,
        Attention.apply(
          state.attention,
          command,
          state.entities,
          Player.eye_position(state.position)
        )
      )

  defp apply_command(state, %{verb: verb} = command)
       when verb in [:skill, :cancel_skill, :remember, :recall, :search_memory, :set_plan] do
    command(state.mind, command)
    state
  end

  # 创世编辑只给启动选项 genesis: true 的 Body（与会话无关，先判）。
  defp apply_command(%{genesis: false} = state, %{id: id, verb: :genesis_edit}),
    do: reject_genesis(state, id, :not_permitted)

  # 没有会话（还没 claim 上或正在重新 claim）：身体与世界动作都无从执行。
  defp apply_command(%{player: nil} = state, %{id: id, verb: verb}),
    do: emit(state, %{id: id, verb: verb, status: :rejected, reason: :invalid_session, data: nil})

  defp apply_command(
         %{position: {px, py, pz}, profile: %{} = profile} = state,
         %{id: id, verb: :move_to, position: {x, z}, tolerance: tolerance} = command
       )
       when is_number(x) and is_number(z) and is_number(tolerance) and tolerance > 0 do
    goal_y = Map.get(command, :y)

    move = %{
      id: id,
      verb: :move_to,
      target: {x, z},
      tolerance: tolerance,
      zero_from: nil,
      path: :planning,
      from: nil,
      mark: nil
    }

    {_, foot_y, _} = start = foot({px, py, pz}, profile.half_height)

    cond do
      not (goal_y == nil or is_integer(goal_y)) ->
        invalid(state, command)

      # 取盒按起终点包围盒整批交 World：水平与竖直（y 相对脚格）都限在感知距离内，超出不访问 World。
      abs(x - px) > @look_reach or abs(z - pz) > @look_reach or
          (goal_y != nil and abs(goal_y - foot_y) > @look_reach) ->
        emit(state, %{id: id, verb: :move_to, status: :rejected, reason: :too_far, data: nil})

      true ->
        plan = %{
          start: start,
          from: {px, pz},
          target: {x, z},
          goal_y: goal_y,
          step: floor(profile.step_height),
          height: Context.clearance(profile),
          radius: profile.radius
        }

        send(
          state.worker,
          {:plan, self(), id, Map.take(state, [:player, :world_ref, :cid]), plan}
        )

        move(state, move)
    end
  end

  # settle = 技能调用号：Runtime 取消技能时用，见 finish_move/1。
  defp apply_command(state, %{id: id, verb: :stop} = command),
    do:
      move(state, %{
        id: id,
        verb: :stop,
        target: nil,
        tolerance: nil,
        zero_from: nil,
        path: [],
        from: nil,
        mark: nil,
        settle: Map.get(command, :settle)
      })

  # 世界写意图：拼成线解码同形的 {kind, request}；需按眼点补方向而位置还不知道（claim 后、首个 ACK 前）时回 invalid_session。
  defp apply_command(state, %{id: id, verb: verb} = command) when verb in @world_verbs do
    eye = state.position && Player.eye_position(state.position)
    context = %{seq: state.request_seq + 1, scene_id: state.scene_id, eye: eye}

    cond do
      eye == nil and WorldRequest.aims?(command) ->
        log_rejected(state.cid, id, "verb=#{verb}", :invalid_session)
        emit(state, %{id: id, verb: verb, status: :rejected, reason: :invalid_session, data: nil})

      intent = WorldRequest.build(command, context) ->
        submit(state, id, intent)

        %{
          state
          | request_seq: state.request_seq + 1,
            world: Map.put(state.world, id, verb),
            casts: remember_cast(state.casts, id, intent)
        }

      true ->
        log_rejected(state.cid, id, "verb=#{verb}", :invalid_command)
        invalid(state, command)
    end
  end

  # 取消前摇：同一 client_intent_seq 的 0x82 action 2（WorldRequest.cancel/2），执行进程同步交给 Player.spell/4；
  # cancel 自己 done（data 为空），原施法由 World 回 cast_cancelled。没有在途施放时没有可取消的请求。
  defp apply_command(%{casts: casts} = state, %{id: id, verb: :cancel_cast})
       when map_size(casts) == 0,
       do:
         emit(state, %{
           id: id,
           verb: :cancel_cast,
           status: :rejected,
           reason: :no_active_cast,
           data: nil
         })

  # 取最早提交、还没有终态的那次：执行进程按提交顺序投递，它在前摇时后提交的只会被 cast_too_soon 拒绝；
  # 它结算后才投递的后一次才会进入前摇，那时它已不在 casts 里。
  defp apply_command(state, %{id: id, verb: :cancel_cast}) do
    request = state.casts |> Map.values() |> Enum.min_by(& &1.client_intent_seq)
    submit(state, id, WorldRequest.cancel(request, %{seq: state.request_seq + 1}))
    %{state | request_seq: state.request_seq + 1, world: Map.put(state.world, id, :cancel_cast)}
  end

  defp apply_command(state, %{id: id, verb: verb} = command)
       when verb in [:query_balances, :look, :survey, :inspect, :read_catalog] do
    case read_call(state, command) do
      nil ->
        invalid(state, command)

      call ->
        submit(state, id, call)
        %{state | request_seq: state.request_seq + 1, world: Map.put(state.world, id, verb)}
    end
  end

  # 创世编辑：Genesis.prepare/3 是受理前的唯一校验（格数、各轴距离、编辑盒），之后交执行进程写 World。
  defp apply_command(state, %{id: id, verb: :genesis_edit} = command) do
    case Genesis.prepare(state.position, state.bounds, Map.get(command, :edits)) do
      :ok ->
        submit(state, id, {:genesis, command.edits})
        %{state | world: Map.put(state.world, id, :genesis_edit)}

      {:error, reason} ->
        reject_genesis(state, id, reason)
    end
  end

  # 只译形状与分配请求号；文本、范围、频率、会话及听众只由 Scene 接纳。
  defp apply_command(state, %{id: id, verb: :say, text: text} = command) when is_binary(text) do
    target = Map.get(command, :target_id, 0)
    conversation = Map.get(command, :conversation_id, 0)

    if is_integer(target) and is_integer(conversation) do
      seq = state.speech_seq + 1
      request = %{request_id: seq, target_id: target, conversation_id: conversation, text: text}
      submit(state, id, {:say, request})
      %{state | speech_seq: seq, world: Map.put(state.world, id, :say)}
    else
      invalid(state, command)
    end
  end

  # Brain 是可插拔的外部输入（含 LLM）：不合法的命令回报为拒绝，不让 Body 崩溃。
  defp apply_command(state, command), do: invalid(state, command)

  # 关注命令的结果带本角色的采样版本（自身 tick、场景、会话代次）。
  defp attention_result(state, command, {:ok, attention, data}) do
    data =
      Map.merge(data, %{
        self_tick: state.tick,
        scene_id: state.scene_id,
        session_epoch: state.identity.session_epoch
      })

    emit(%{state | attention: attention}, %{
      id: command.id,
      verb: command.verb,
      status: :done,
      reason: nil,
      data: data
    })
  end

  defp attention_result(state, command, {:error, reason}),
    do:
      emit(state, %{
        id: command.id,
        verb: command.verb,
        status: :rejected,
        reason: reason,
        data: nil
      })

  # 只读请求：余额与 Gate 一样直接读 material_balances；look / survey / inspect 的 macro 格限制在自己周围
  # （玩家也只看得到流送到身边的世界）；read_catalog 读目录，与位置无关。nil = 命令不合法。
  # survey 判“站得下”要身高格数，取自权威下发的移动 profile。
  defp read_call(_state, %{verb: :query_balances}), do: :balances

  defp read_call(%{position: position, profile: %{} = profile}, %{verb: :survey} = command),
    do: Perception.prepare(position, command, Context.clearance(profile))

  defp read_call(%{position: position}, command),
    do: Perception.prepare(position, command)

  # 意图到达角色入口的时刻在受理时冻结一次，随调用交给执行进程（与玩家连接入队时取值同一语义）；GCRA 按它判频。
  defp submit(state, id, call),
    do:
      send(
        state.worker,
        {:call, self(), id,
         Map.take(state, [
           :player,
           :identity,
           :world_ref,
           :cid,
           :bounds,
           :scene,
           :scene_id,
           :router
         ]), call, %{received_us: System.monotonic_time(:microsecond), clock_node: node()}}
      )

  defp reject_genesis(state, id, reason) do
    log_rejected(state.cid, id, "verb=genesis_edit", reason)
    emit(state, %{id: id, verb: :genesis_edit, status: :rejected, reason: reason, data: nil})
  end

  defp invalid(state, command) when is_map(command) do
    emit(state, %{
      id: Map.get(command, :id),
      verb: Map.get(command, :verb),
      status: :rejected,
      reason: :invalid_command,
      data: nil
    })
  end

  defp remember_cast(casts, id, {:voxel_spell_intent, request}), do: Map.put(casts, id, request)
  defp remember_cast(casts, _id, _intent), do: casts

  # 投给已退出 Player 的施放不会再有回复：这些施法若仍在途，各以 session_lost 结束（已授权的可能已结算，Brain 以
  # look / inspect 现算）；之后迟到的 {{:npc_cast, id}, _} 因表中无 id 被忽略。
  defp lose_casts(state, ids) do
    Enum.reduce(ids, state, fn id, state ->
      case Map.pop(state.world, id) do
        {:cast_spell, world} ->
          emit(%{state | world: world, casts: Map.delete(state.casts, id)}, %{
            id: id,
            verb: :cast_spell,
            status: :rejected,
            reason: :session_lost,
            data: nil
          })

        _ ->
          state
      end
    end)
  end

  defp reject_move(%{move: move} = state, reason, data \\ nil) do
    Logger.warning(
      "npc_move_rejected cid=#{state.cid} reason=#{reason} position=#{inspect(state.position)} target=#{inspect(move.target)} path=#{inspect(move.path)}"
    )

    emit(%{state | move: nil}, %{
      id: move.id,
      verb: move.verb,
      status: :rejected,
      reason: reason,
      data: data
    })
  end

  defp move(%{move: nil} = state, move), do: %{state | move: move}

  defp move(%{move: old} = state, move) do
    emit(%{state | move: move}, %{
      id: old.id,
      verb: old.verb,
      status: :superseded,
      reason: nil,
      data: nil
    })
  end

  defp world_calls do
    receive do
      # 施放：读目录 digest 填入请求，交给角色 owner 后不等（前摇由 Player 推进）；结果按 reply_to 直接回 Body。
      # 只有投递前会话已丢失时由这里回 session_lost（同下面的退出规则）。
      {:call, body, id, session, {:voxel_spell_intent, %{action: 1} = request}, ingress} ->
        case session_call(session, :lost, fn -> World.magic_digest(session.world_ref) end) do
          :lost ->
            send(body, {:npc_world_result, id, {:error, :session_lost}, nil})

          digest ->
            reply_to = {body, {:npc_cast, id}}

            Player.cast_spell(
              session.player,
              session.identity,
              %{request | catalog_digest: digest},
              Map.put(ingress, :caster_recipient, reply_to),
              reply_to
            )
        end

        world_calls()

      {:call, body, id, session, call, ingress} ->
        {result, balances} =
          session_call(session, {{:error, :session_lost}, nil}, fn ->
            execute(session, call, ingress)
          end)

        send(body, {:npc_world_result, id, result, balances})
        world_calls()

      {:plan, body, id, session, plan} ->
        result =
          session_call(session, {:error, :session_lost}, fn -> plan_path(session, plan) end)

        send(body, {:npc_path, id, result})
        world_calls()
    end
  end

  # 世界调用（Intent、读口、寻路取盒）的退出只判一件事：会话的 Player 已退出（Scene 重启、会话被关闭、重新 claim）
  # → 回 lost，如实报会话丢失（写意图可能尚未进 World，也可能已提交：Brain 以 look / inspect 现算）；
  # 否则照常退出，执行进程与 Body 同死，由监督者按 transient 重启。异常不捕获，代码缺陷照样崩溃。
  # Scene 可在 peer 节点：判活用节点安全的 `Player.running?/1`（远端 pid 不能交给 Process.alive?/1）。
  defp session_call(session, lost, fun) do
    fun.()
  catch
    :exit, reason -> if Player.running?(session.player), do: exit(reason), else: lost
  end

  defp plan_path(
         session,
         %{start: {sx, sy, sz} = start, target: {tx, tz} = target, goal_y: goal_y} = plan
       ) do
    {gx, gz} = goal = {floor(tx), floor(tz)}
    [y0, y1] = Enum.sort([sy, goal_y || sy])

    cells =
      for x <- (min(sx, gx) - @path_margin)..(max(sx, gx) + @path_margin),
          y <- (y0 - @path_margin)..(y1 + @path_margin),
          z <- (min(sz, gz) - @path_margin)..(max(sz, gz) + @path_margin),
          do: {x, y, z}

    # 能踩（:solid）、能穿过（:open）只用 Perception.walk_kind/1 一个判据（与碰撞同源）；既不能踩也不能穿过的格（液体、
    # 细化格）不进表。原先只有空气算 :open，站进草 / 蕨格的 NPC 起点就是实心（2026-10-08 run03）；细化格原先当作占满、
    # 可踩：建设者被规划去踩 1/8 米的面板顶，落进面板格里（2026-10-08 run06）。
    snapshot = World.material_snapshot(session.world_ref, [session.cid], cells)

    grid =
      for row <- snapshot.probe_occupancy,
          kind <- [Perception.walk_kind(row)],
          kind != nil,
          into: %{},
          do: {List.to_tuple(row.cell), kind}

    # 起点是身体的权威位置：落不到站立格（站在细化格空着的部分或它上面）也从这里出发，不因网格保守而判成哪儿都去不了
    # （run06：起点是自己放的面板格，对任何目标 no_path，建设者两次永久卡死）。
    case Path.find(grid, start, goal, goal_y, plan.step, plan.height, trusted_start: true) do
      {:ok, cells} ->
        {:ok, Path.smooth(grid, plan.from, sy, cells, target, plan.radius, plan.height)}

      :no_path ->
        # 只用本次寻路快照解释拒绝，不重查世界、不另算一条替代路径。
        {:no_path,
         %{
           seq: snapshot.seq,
           start: start,
           goal: {gx, goal_y, gz},
           goal_position:
             if(goal_y != nil, do: Path.position(grid, {gx, goal_y, gz}, plan.height))
         }}

      error ->
        error
    end
  end

  # 返回 {结果, 余额}；余额 nil = 这次不重取。
  defp execute(session, {:say, request}, _ingress) do
    Logger.info(
      "dialogue.request speaker=#{session.cid} request_id=#{request.request_id} conversation_id=#{request.conversation_id} target=#{request.target_id}"
    )

    result =
      with {:ok, route} <- session.router.route(session.scene_id) do
        # 调用退出不能证明 Scene 未接纳；只处理公共调用的退出，代码异常仍按原监督语义暴露。
        try do
          session.scene.say(route.scene_ref, session.identity, request)
        catch
          :exit, {reason, {GenServer, :call, _}} ->
            Logger.warning(
              "dialogue.delivery_unknown speaker=#{session.cid} request_id=#{request.request_id} reason=#{inspect(reason)}"
            )

            {:error, :delivery_unknown}
        end
      end

    reason =
      case result do
        {:ok, _} -> :ok
        {:error, reason} -> reason
      end

    Logger.info(
      "dialogue.result speaker=#{session.cid} request_id=#{request.request_id} reason=#{inspect(reason)}"
    )

    {result, nil}
  end

  defp execute(session, :balances, _ingress) do
    balances = World.material_balances(session.world_ref, session.cid)
    {{:ok, %{balances: balances}}, balances}
  end

  defp execute(session, {:sight, query}, _ingress),
    do: {Sight.read(session.world_ref, query), nil}

  # 创世编辑：以创世主体做原始格编辑（不扣料、不记 placed_by，受保护区约束），余额不变、不重取。
  defp execute(session, {:genesis, edits}, _ingress) do
    result = World.apply_edits(session.world_ref, {:genesis, session.cid}, edits)

    Logger.info(
      "npc_genesis_edit cid=#{session.cid} cells=#{length(edits)} result=#{inspect(result)}"
    )

    {result, nil}
  end

  defp execute(session, call, _ingress)
       when elem(call, 0) in [:look, :survey, :inspect, :catalog],
       do: {Perception.read(session.world_ref, session.cid, call), nil}

  # 取消前摇（0x82 action 2）：与玩家同一个同步入口 Player.spell/4，角色 owner 撤销后回 :controlled。
  defp execute(session, {:voxel_spell_intent, request}, ingress) do
    case Player.spell(session.player, session.identity, request, ingress) do
      {:ok, :controlled} -> {{:ok, %{}}, nil}
      {:error, _} = error -> {error, nil}
    end
  end

  # 世界写意图：与玩家同一入口；补余额按 Intent 的唯一规则（回执先、余额后，同 Gate）。
  defp execute(session, {kind, request} = intent, ingress) do
    case prefab_gate(session, intent) do
      :ok ->
        {result, refresh} = Intent.run(session, intent, ingress)

        {outcome(intent, result),
         if(refresh, do: World.material_balances(session.world_ref, session.cid))}

      {:error, reason} = error ->
        log_rejected(session.cid, request.request_id, "kind=#{kind}", reason)
        {error, nil}
    end
  end

  # 探测命中补上本次方向，done data 原样就是下一次 use_tool 的目标句柄；人物回执取公开投影
  # （`ToolAction.public_receipt/1`，与玩家下行 ToolState 同一份），g5 探测的回执同时构成人物句柄。
  defp outcome({:voxel_tool_intent, %{action: 0} = request}, {:ok, %{} = hit}),
    do: {:ok, Map.put(hit, :direction, request.direction)}

  defp outcome({:voxel_tool_intent, %{action: 0} = request}, {:body, receipt}),
    do:
      {:ok,
       Map.merge(ToolAction.public_receipt(receipt), %{
         granularity: 5,
         owner: {receipt.target_id, 0},
         incarnation: receipt.target_life,
         micro: {0, 0, 0},
         material: 0,
         direction: request.direction
       })}

  defp outcome(_intent, {:body, receipt}), do: {:ok, ToolAction.public_receipt(receipt)}
  defp outcome(_intent, result), do: result

  # 技能取上下文用：会话的 Player 已结束时如实回 session_lost。
  defp tool_context(player, identity) do
    Player.tool_context(player, identity)
  catch
    :exit, _ -> {:error, :session_lost}
  end

  # 进 Intent 之前被 Body 拒绝的世界命令（类型守卫、位置未知、编辑盒越界；创世编辑的授予与 Genesis.prepare/3 拒绝）：
  # 这些不产生 `character_intent` 行，各记一行供 CLI 按 reason 归类。id 在受理侧是命令 id，在执行进程里是请求号（request_id）。
  defp log_rejected(cid, id, what, reason),
    do:
      Logger.warning(
        "npc_intent_rejected cid=#{cid} id=#{inspect(id)} #{what} reason=#{inspect(reason)}"
      )

  # 部署编辑盒：与玩家连接在进 World 之前做的同一道门（共用 EditBounds.prefab_within?/4）。
  defp prefab_gate(session, {kind, request}) when kind in @prefab_kinds do
    if EditBounds.prefab_within?(session.world_ref, kind, request, session.bounds),
      do: :ok,
      else: {:error, :out_of_bounds}
  end

  defp prefab_gate(_session, _intent), do: :ok
end
