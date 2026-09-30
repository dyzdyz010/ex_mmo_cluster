defmodule GateServer.Session.Dispatch do
  @moduledoc """
  Voxim QUIC 会话的体素意图分发：`GateServer.Session.QuicConnection` 的编辑 worker 串行调用 `handle/2`，
  每条意图转给权威 `VoxelRegion.World`，回执与余额经 `:sink` 下发。

  ## state 契约

  调用方传入的上下文 map 含 `:sink`、`:status`、`:cid`、`:voxim_overlay`、`:world_ref`、`:player`、`:identity`，
  以及工具／施法所需的 `:received_us`、`:clock_node`。本模块不碰传输私有字段。
  """

  require Logger

  alias GateServer.Session.Sink
  alias GateServer.Voxel.ResultFrame

  @doc "Canonical macro targets used both by M1 admission and the existing R6 edit path."
  def voxim_edit_coords({:voxel_edit_intent, request}) do
    {x, y, z} = request.target_world_micro
    [{Integer.floor_div(x, 8), Integer.floor_div(y, 8), Integer.floor_div(z, 8)}]
  end

  def voxim_edit_coords({:voxel_batch_edit_intent, request}),
    do: Enum.map(request.edits, &elem(&1, 0))

  @doc """
  Prefab 请求涉及的 macro 格是否都在部署的编辑盒内；玩家连接与 NPC Body 共用。
  算不出格（未知定义 / 实例）时放行，由 World 给出原因。
  """
  def prefab_within?(world_ref, kind, request, {{a, b, c}, {d, e, f}}) do
    cells =
      case kind do
        :voxel_prefab_place_v1 ->
          with {:ok, cells} <-
                 VoxelRegion.World.prefab_cells(
                   world_ref,
                   request.definition_id,
                   request.anchor,
                   request.orientation
                 ),
               do:
                 {:ok,
                  Enum.map(cells, fn {micro, _} ->
                    elem(VoxelRegion.Prefab.macro_slot(micro), 0)
                  end)}

        :voxel_prefab_remove_v1 ->
          VoxelRegion.World.instance_cells(world_ref, request.instance_id)

        :voxel_prefab_replace_v1 ->
          VoxelRegion.World.replacement_cells(
            world_ref,
            request.instance_id,
            request.definition_id
          )
      end

    case cells do
      {:ok, cells} ->
        Enum.all?(cells, fn {x, y, z} ->
          x >= a and y >= b and z >= c and x < d and y < e and z < f
        end)

      {:error, _} ->
        true
    end
  end

  @type state :: map()

  @doc """
  处理一条已解码的上行消息，返回更新后的 state。

  未知消息回通用 `:unknown_message` 错误帧并记日志——协议层只追加不破坏，收到不认识的
  消息说明对端版本更新或编解码漂移，必须可诊断。
  """
  @spec handle(term(), state()) :: {:ok, state()}
  def handle(message, state)

  # 只读余额取已鉴权的角色身份，不依赖移动 Ready 握手。
  def handle(
        {:voxel_production_intent, %{action: 0} = request},
        %{status: :in_scene, voxim_overlay: true, cid: cid} = state
      ) do
    send_material_balances(state, cid, request.request_id)
    {:ok, state}
  end

  def handle({kind, request}, %{status: :in_scene, voxim_overlay: true} = state)
      when kind in [:voxel_production_intent, :voxel_attachment_intent] do
    with {:ok, actor} <- SceneServer.Movement.Player.tool_context(state.player, state.identity) do
      actor = Map.merge(actor, Map.take(state, [:received_us, :clock_node]))

      result =
        if kind == :voxel_attachment_intent,
          do: VoxelRegion.World.attachment_intent(state.world_ref, actor, request),
          else: VoxelRegion.World.production_intent(state.world_ref, actor, request)

      # 回执先发：余额是另一次 World 查询，按 BalanceSeq 独立生效，不必挡在回执前面。
      case result do
        {:ok, seq} ->
          send_encoded(state, ResultFrame.accepted(request, seq))

        {:error, reason} ->
          send_encoded(state, ResultFrame.error(request, reason))
      end

      send_material_balances(state, actor.cid, request.request_id)
    else
      {:error, reason} -> send_encoded(state, ResultFrame.error(request, reason))
    end

    {:ok, state}
  end

  def handle({kind, request}, state)
      when kind in [:voxel_production_intent, :voxel_attachment_intent] do
    send_encoded(state, ResultFrame.error(request, :invalid_state))
    {:ok, state}
  end

  def handle({:voxel_tool_intent, request}, %{status: :in_scene, voxim_overlay: true} = state) do
    started = System.monotonic_time(:microsecond)

    result =
      SceneServer.Movement.ToolAction.run(
        state.player,
        state.identity,
        state.world_ref,
        request,
        Map.take(state, [:received_us, :clock_node])
      )

    case result do
      {:body, receipt} ->
        {gate, _edit_ref} = state.sink.ref

        Sink.reliable(
          gate,
          state.identity,
          :control,
          SceneServer.Movement.ToolAction.message(receipt, state.identity, request.request_id)
        )

      {:ok, %{} = target} ->
        send_encoded(state, {:voxel_property_state, target})

      {:ok, seq} ->
        send_encoded(state, ResultFrame.accepted(request, seq))

      {:error, reason} ->
        send_encoded(state, ResultFrame.error(request, reason))
    end

    # 回执先发，余额随后（同生产意图）。
    if request.action in [1, 2] and request.granularity != 5,
      do: send_material_balances(state, state.cid, request.request_id)

    Logger.info(
      "voxel_tool_dispatch request_id=#{request.request_id} elapsed_us=#{System.monotonic_time(:microsecond) - started}"
    )

    {:ok, state}
  end

  def handle({:voxel_tool_intent, request}, state) do
    send_encoded(state, ResultFrame.error(request, :invalid_state))
    {:ok, state}
  end

  # 魔法增量 1：施法意图 0x82。先回施法者状态 0x83（同 request_id，带报价、实际支出与施放后能量）；
  # 施放与走火都是已提交事务，再回 0x68 accepted（result_ref = seq，reason "ok" / "misfire_energy" /
  # "misfire_coherence"）；报价只回 0x83；拒绝只回 0x68 rejected（reason 同工具意图的 inspect 形式）。
  # 施放前摇（Voxim Docs/Magic.md §13.6）：施放的回执在前摇结束后才有，在独立进程里等，编辑 worker 不被占住
  # （前摇中的再次施放要立即拿到 cast_too_soon，其他编辑意图照常）；报价同步回复。
  def handle(
        {:voxel_spell_intent, %{action: 1} = request},
        %{status: :in_scene, voxim_overlay: true} = state
      ) do
    ref = make_ref()

    waiter =
      spawn(fn ->
        monitor = Process.monitor(state.player)

        receive do
          {^ref, result} ->
            Process.demonitor(monitor, [:flush])
            reply_spell_result(result, request, state)

          {:DOWN, ^monitor, :process, _, _} ->
            reply_spell_result({:error, :invalid_session}, request, state)
        end
      end)

    GenServer.cast(
      state.player,
      {:spell, state.identity, request, Map.take(state, [:received_us, :clock_node]),
       {waiter, ref}}
    )

    {:ok, state}
  end

  def handle({:voxel_spell_intent, request}, %{status: :in_scene, voxim_overlay: true} = state) do
    reply_spell(request, state)
    {:ok, state}
  end

  def handle({:voxel_spell_intent, request}, state) do
    send_encoded(state, ResultFrame.error(request, :invalid_state))
    {:ok, state}
  end

  # 魔法增量 1：QUIC 连接接纳 0x76 后经编辑 worker 下发一次施法者状态（与后续施法回执同一 FIFO）。
  def handle(
        {:voxel_caster_state_request, request},
        %{status: :in_scene, voxim_overlay: true} = state
      ) do
    send_caster_state(state, request.request_id)
    {:ok, state}
  end

  def handle({kind, request}, %{status: :in_scene, voxim_overlay: true} = state)
      when kind in [:voxel_prefab_place_v1, :voxel_prefab_remove_v1, :voxel_prefab_replace_v1] do
    case SceneServer.Movement.Player.tool_context(state.player, state.identity) do
      {:ok, actor} ->
        case VoxelRegion.World.prefab_intent(state.world_ref, actor, kind, request) do
          {:ok, seq} -> send_encoded(state, ResultFrame.accepted(request, seq))
          {:error, reason} -> send_encoded(state, ResultFrame.error(request, reason))
        end

        # 回执先发，余额随后（同生产意图）。
        send_material_balances(state, actor.cid, request.request_id)

      {:error, reason} ->
        send_encoded(state, ResultFrame.error(request, reason))
    end

    {:ok, state}
  end

  # D3：玩家发布自制定义。发布不扣料、不产生体素事务；id 即字节 sha256，客户端自行计算。
  def handle(
        {:voxel_prefab_publish_v1, request},
        %{status: :in_scene, voxim_overlay: true} = state
      ) do
    result =
      with {:ok, actor} <- SceneServer.Movement.Player.tool_context(state.player, state.identity),
           do:
             VoxelRegion.World.publish_prefab(
               state.world_ref,
               actor,
               request.definition,
               request.name
             )

    case result do
      {:ok, _id} ->
        send_encoded(state, ResultFrame.accepted(request, 0))

      {:error, reason} ->
        send_encoded(state, ResultFrame.error(request, reason))
    end

    {:ok, state}
  end

  def handle({:voxel_prefab_publish_v1, _}, state) do
    result_error(state, :invalid_state, 0)
    {:ok, state}
  end

  def handle({kind, _}, state)
      when kind in [:voxel_prefab_place_v1, :voxel_prefab_remove_v1, :voxel_prefab_replace_v1] do
    result_error(state, :invalid_state, 0)
    {:ok, state}
  end

  def handle(
        {:voxel_batch_edit_intent, request},
        %{status: :in_scene, voxim_overlay: true} = state
      ) do
    case VoxelRegion.World.apply_edits(state.world_ref, request.edits) do
      {:ok, seq} ->
        send_encoded(state, ResultFrame.accepted(request, seq))

      {:error, reason} ->
        send_encoded(state, ResultFrame.error(request, reason))
    end

    {:ok, state}
  end

  def handle({:voxel_batch_edit_intent, _request}, state) do
    result_error(state, :invalid_state, 0)
    {:ok, state}
  end

  def handle({:voxel_edit_intent, request}, %{status: :in_scene, voxim_overlay: true} = state) do
    [coord] = voxim_edit_coords({:voxel_edit_intent, request})

    case MmoContracts.VoxelMaterialCatalog.valid_id?(request.material_id) &&
           VoxelRegion.World.apply_edit(state.world_ref, coord, request.material_id) do
      {:ok, seq} ->
        send_encoded(state, ResultFrame.accepted(request, seq))

      {:error, reason} ->
        send_encoded(state, ResultFrame.error(request, reason))

      false ->
        send_encoded(state, ResultFrame.error(request, :invalid_material))
    end

    {:ok, state}
  end

  def handle(message, state) do
    Logger.warning("Unhandled message: #{inspect(elem(message, 0))}")
    result_error(state, :unknown_message, 0)
    {:ok, state}
  end

  # ── 内部辅助 ──

  defp send_encoded(state, message), do: Sink.send_encoded(state.sink, message)

  defp reply_spell(request, state) do
    result =
      SceneServer.Movement.Player.spell(
        state.player,
        state.identity,
        request,
        Map.take(state, [:received_us, :clock_node])
      )

    reply_spell_result(result, request, state)
  end

  defp reply_spell_result(result, request, state) do
    case result do
      {:ok, :controlled} ->
        :ok

      {:ok, reply} ->
        send_encoded(
          state,
          {:voxel_caster_state, Map.put(reply.caster, :request_id, request.request_id)}
        )

        if request.action == 1 do
          send_encoded(
            state,
            ResultFrame.accepted(request, reply.seq, Atom.to_string(reply.outcome || :ok))
          )
        end

      {:error, reason} ->
        send_encoded(state, ResultFrame.error(request, reason))
    end
  end

  defp emit(state, event, fields), do: Sink.emit(state.sink, event, fields)

  @doc """
  通用 `Result(error)` 回执。

  除 dispatch 自身外，连接进程在**进入状态机之前**的失败点（如 codec 解码拒绝）也用它，
  保证任何被拒的上行都有一帧可诊断回执，不让客户端悬等。
  """
  @spec result_error(state(), term(), non_neg_integer()) :: :ok
  def result_error(state, reason, request_id) do
    Logger.debug("Sending generic result error: #{inspect(reason)}")

    emit(state, "send_result_error", %{
      connection_pid: self(),
      request_id: request_id,
      reason: reason
    })

    send_encoded(state, {:result, :error, request_id})
  end

  defp send_caster_state(state, request_id) do
    with {:ok, caster} <- VoxelRegion.World.caster_state(state.world_ref, state.cid),
         do: send_encoded(state, {:voxel_caster_state, Map.put(caster, :request_id, request_id)})
  end

  defp send_material_balances(state, cid, request_id) do
    for balance <- VoxelRegion.World.material_balances(state.world_ref, cid) do
      send_encoded(state, {:voxel_material_balance, Map.put(balance, :request_id, request_id)})
    end
  end
end
