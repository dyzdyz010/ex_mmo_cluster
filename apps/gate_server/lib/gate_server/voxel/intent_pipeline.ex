defmodule GateServer.Voxel.IntentPipeline do
  @moduledoc """
  Gate 侧四条体素上行意图的共享执行管线 —— TCP / WS 共用的唯一实现。

  | 意图 | opcode | 落地路径 |
  | --- | --- | --- |
  | 撞击 | `0x64 VoxelImpactIntent` | 技能/工具触发，经 lease 路由后 `ChunkDirectory.apply_intent` |
  | 编辑 | `0x70 VoxelEditIntent` | 客户端定型编辑通道，同上并带幂等 command_id |
  | 表面元件 | `0x66 VoxelSurfaceElementIntent` | 同路由，走专用 `:apply_surface_element` |
  | 场域导通 | `0x75 VoxelFieldConductIntent` | 同路由解析 source 宏格，RPC 至 `FieldRuntime` |

  四条共享同一个骨架：**校验发起者 → 解析目标格 → World 路由拿 lease → 定位 Scene
  节点 → 带 lease 下发**。Gate 在这里只做协议侧校验与路由，不持有任何体素权威态；
  写入与广播都由 Scene 的 ChunkProcess 完成。

  ```mermaid
  flowchart LR
      A[intent] --> B[authorize cid]
      B --> C[解析 chunk_coord + local_macro]
      C --> D[Routing.route_chunk 拿 lease]
      D --> E[Routing.scene_node_for_route]
      E --> F[ChunkDirectory / FieldRuntime]
  ```

  所有函数都必须在连接进程内调用：observe 事件以 `self()` 作为连接标识。
  """

  alias GateServer.Session.Sink
  alias GateServer.Voxel.Routing
  alias SceneServer.Combat.Skill
  alias SceneServer.Voxel.Field.FieldRuntime
  alias SceneServer.Voxel.{NormalBlockData, Types}

  @scene_call_timeout 15_000

  @type ctx :: %{cid: integer(), sink: Sink.t()}

  # ---------------------------------------------------------------------------
  # 0x64 VoxelImpactIntent
  # ---------------------------------------------------------------------------

  @doc """
  执行撞击意图。

  DEPRECATED 作为客户端直接编辑通道（协议 §13.6 / §13.6.1），客户端定型编辑请走
  `apply_edit/2`（0x70）；本入口保留给技能 / 工具系统流程。
  """
  @spec apply_impact(map(), ctx()) :: {:ok, map()} | {:error, term()}
  def apply_impact(request, ctx) do
    with :ok <- authorize_impact(request, ctx),
         {:ok, target} <- impact_target(request),
         {:ok, route} <- Routing.route_chunk(request.logical_scene_id, target.chunk_coord),
         {:ok, scene_node} <- Routing.scene_node_for_route(route) do
      lease = Map.fetch!(route, :lease)

      # 历史契约:本事件在 tcp / ws 下同名(无传输前缀),CLI 与既有测试都按该名匹配。
      GateServer.CliObserve.emit("voxel_impact_intent_routed", %{
        connection_pid: self(),
        cid: ctx.cid,
        request_id: request.request_id,
        logical_scene_id: request.logical_scene_id,
        chunk_coord: target.chunk_coord,
        region_id: lease.region_id,
        lease_id: lease.lease_id,
        owner_scene_instance_ref: lease.owner_scene_instance_ref,
        owner_epoch: lease.owner_epoch,
        scene_node: scene_node
      })

      attrs =
        %{
          request_id: request.request_id,
          logical_scene_id: request.logical_scene_id,
          chunk_coord: target.chunk_coord,
          lease: lease,
          macro: target.local_macro
        }
        |> Map.merge(impact_op_attrs(request))

      case apply_intent(scene_node, attrs) do
        {:ok, reply} -> {:ok, Map.merge(reply, %{macro: target.local_macro})}
        {:error, _reason} = error -> error
      end
    end
  end

  defp authorize_impact(request, ctx) do
    with :ok <- authorize_cid(ctx) do
      case Skill.fetch(request.source_skill_id) do
        {:ok, _skill} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp impact_target(%{target_world_micro: {wx, wy, wz}}) do
    micro_resolution = Types.micro_resolution()

    world_macro = {
      Types.floor_div(wx, micro_resolution),
      Types.floor_div(wy, micro_resolution),
      Types.floor_div(wz, micro_resolution)
    }

    {chunk_coord, local_macro} = Types.chunk_and_local_macro!(world_macro)
    {:ok, %{chunk_coord: chunk_coord, local_macro: local_macro}}
  rescue
    _exception in [ArgumentError, FunctionClauseError] -> {:error, :invalid_target_world_micro}
  end

  # Wire convention: `impact_kind == 0` is the break sentinel — the cell
  # gets cleared back to empty mode (delta_kind 0 CellEmpty on the wire).
  defp impact_op_attrs(%{impact_kind: 0}), do: %{operation: :break_block}

  defp impact_op_attrs(request) do
    # Any non-zero `impact_kind` is treated as a `material_id` for a put-solid
    # write (delta_kind 1 CellSolid).
    block =
      NormalBlockData.new(request.impact_kind,
        health: 100,
        state_flags: request.source_skill_id
      )

    %{operation: :put_solid_block, block: block}
  end

  # ---------------------------------------------------------------------------
  # 0x70 VoxelEditIntent
  # ---------------------------------------------------------------------------

  @doc "把 `0x70` 定型编辑落到 Scene，并带上幂等 command_id。"
  @spec apply_edit(map(), ctx()) :: {:ok, map()} | {:error, term()}
  def apply_edit(request, ctx) do
    with :ok <- authorize_cid(ctx),
         {:ok, op} <- edit_op(request),
         {:ok, target} <- edit_target(request, op),
         {:ok, route} <- Routing.route_chunk(request.logical_scene_id, target.chunk_coord),
         {:ok, scene_node} <- Routing.scene_node_for_route(route) do
      lease = Map.fetch!(route, :lease)

      # 历史契约:本事件在 tcp / ws 下同名(无传输前缀)。
      GateServer.CliObserve.emit("voxel_edit_intent_routed", %{
        connection_pid: self(),
        cid: ctx.cid,
        request_id: request.request_id,
        logical_scene_id: request.logical_scene_id,
        action: request.action,
        target_granularity: request.target_granularity,
        operation: op.operation,
        chunk_coord: target.chunk_coord,
        local_macro: target.local_macro,
        adjusted_world_micro: target.adjusted_world_micro,
        region_id: lease.region_id,
        lease_id: lease.lease_id,
        owner_scene_instance_ref: lease.owner_scene_instance_ref,
        owner_epoch: lease.owner_epoch,
        scene_node: scene_node
      })

      command_id =
        GateServer.VoxelCommandId.edit(
          request.logical_scene_id,
          ctx.cid,
          request.client_intent_seq
        )

      attrs = build_edit_attrs(request, op, target, lease, command_id)

      case apply_intent(scene_node, attrs) do
        {:ok, reply} ->
          {:ok, Map.merge(reply, %{macro: target.local_macro, operation: op.operation})}

        {:error, _reason} = error ->
          error
      end
    end
  end

  @doc "发一条编辑意图受理的结构化 observe（带传输前缀）。"
  @spec emit_edit_received(map(), ctx()) :: :ok
  def emit_edit_received(request, ctx) do
    Sink.emit(ctx.sink, "voxel_edit_intent_received", %{
      connection_pid: self(),
      cid: ctx.cid,
      request_id: request.request_id,
      client_intent_seq: request.client_intent_seq,
      logical_scene_id: request.logical_scene_id,
      action: request.action,
      target_granularity: request.target_granularity,
      target_world_micro: request.target_world_micro,
      face_normal: request.face_normal,
      material_id: request.material_id,
      blueprint_ref: request.blueprint_ref,
      object_ref: request.object_ref,
      part_ref: request.part_ref,
      attribute_patch_ref: request.attribute_patch_ref,
      expected_chunk_version: request.expected_chunk_version,
      expected_cell_hash: request.expected_cell_hash,
      client_hint_hash: request.client_hint_hash
    })
  end

  # Decision 3 / Phase 1c: action × target_granularity → Scene operation.
  # ObjectPart granularity is rejected for the supported actions; Damage /
  # Replace / AttributePatch are rejected wholesale until the Phase 5 attribute
  # catalog work lands.
  defp edit_op(%{action: action}) when action in [2, 3, 4] do
    {:error, :action_not_implemented}
  end

  defp edit_op(%{action: action, target_granularity: 2}) when action in [0, 1] do
    {:error, :granularity_object_part_not_implemented}
  end

  defp edit_op(%{action: 0, target_granularity: 0} = request) do
    block =
      NormalBlockData.new(request.material_id,
        attribute_set_ref: request.attribute_patch_ref,
        state_flags: orientation_state_flags(request.material_id, request.face_normal)
      )

    {:ok, %{operation: :put_solid_block, block: block}}
  end

  defp edit_op(%{action: 0, target_granularity: 1} = request) do
    with {:ok, owner_object_id} <- edit_owner_object_id(request.object_ref) do
      micro_layer = %{
        material_id: request.material_id,
        attribute_set_ref: request.attribute_patch_ref,
        owner_object_id: owner_object_id,
        owner_part_id: request.part_ref
      }

      {:ok, %{operation: :put_micro_block, micro_layer: micro_layer}}
    end
  end

  defp edit_op(%{action: 1, target_granularity: 0}), do: {:ok, %{operation: :break_block}}
  defp edit_op(%{action: 1, target_granularity: 1}), do: {:ok, %{operation: :clear_micro_block}}
  defp edit_op(_request), do: {:error, :invalid_voxel_edit_intent}

  # C4b:二极管/三极管放置时由玩家瞄准的 face_normal 推出 per-cell 导通轴写进 state_flags
  # bits[0..2](二极管=anode→cathode 轴;三极管=collector-emitter 主轴,base 面默认取首个非主轴面)。
  # 其它材料 → 0(无朝向)。MVP:无 0x70 wire 变体,服务端由 face_normal 推断(决策 ④)。
  defp orientation_state_flags(material_id, face_normal) do
    if SceneServer.Voxel.MaterialCatalog.diode_material?(material_id) or
         SceneServer.Voxel.MaterialCatalog.transistor_material?(material_id) do
      axis_code_from_face_normal(face_normal)
    else
      0
    end
  end

  defp axis_code_from_face_normal({fnx, fny, fnz}) do
    cond do
      fnx > 0 -> 1
      fnx < 0 -> 2
      fny > 0 -> 3
      fny < 0 -> 4
      fnz > 0 -> 5
      fnz < 0 -> 6
      # 退化法向 → +x 默认(惰性安全)。
      true -> 1
    end
  end

  # owner_object_id is a u63 (`MicroLayer.@type`); the wire field is u64. The
  # high bit is reserved for future use, so reject values that don't fit.
  defp edit_owner_object_id(value)
       when is_integer(value) and value >= 0 and value <= 0x7FFF_FFFF_FFFF_FFFF,
       do: {:ok, value}

  defp edit_owner_object_id(_value), do: {:error, :invalid_object_ref}

  # Decision 6 / Phase 1c: Place actions consume `face_normal` here at the Gate
  # by offsetting `target_world_micro` by one micro slot in the direction of
  # the hit face. Break actions ignore `face_normal` — the resolved cell is
  # the one the client clicked.
  defp edit_target(request, %{operation: operation}) do
    {wx, wy, wz} = request.target_world_micro
    {fnx, fny, fnz} = request.face_normal

    {ax, ay, az} =
      case operation do
        :put_solid_block -> {wx + fnx, wy + fny, wz + fnz}
        :put_micro_block -> {wx + fnx, wy + fny, wz + fnz}
        _other -> {wx, wy, wz}
      end

    micro_resolution = Types.micro_resolution()

    world_macro = {
      Types.floor_div(ax, micro_resolution),
      Types.floor_div(ay, micro_resolution),
      Types.floor_div(az, micro_resolution)
    }

    {chunk_coord, local_macro} = Types.chunk_and_local_macro!(world_macro)

    local_micro = {
      Types.floor_mod(ax, micro_resolution),
      Types.floor_mod(ay, micro_resolution),
      Types.floor_mod(az, micro_resolution)
    }

    {:ok,
     %{
       chunk_coord: chunk_coord,
       local_macro: local_macro,
       local_micro: local_micro,
       adjusted_world_micro: {ax, ay, az}
     }}
  rescue
    _exception in [ArgumentError, FunctionClauseError] -> {:error, :invalid_target_world_micro}
  end

  defp build_edit_attrs(request, op, target, lease, command_id) do
    base = %{
      request_id: request.request_id,
      logical_scene_id: request.logical_scene_id,
      chunk_coord: target.chunk_coord,
      lease: lease,
      operation: op.operation,
      macro: target.local_macro,
      expected_chunk_version: request.expected_chunk_version,
      expected_cell_hash: request.expected_cell_hash,
      # AUTH-4(step1.5b-1):客户端命令幂等键,scene/store 同事务 record_once。
      command_id: command_id
    }

    base
    |> maybe_put(:block, Map.get(op, :block))
    |> maybe_put(:micro_layer, Map.get(op, :micro_layer))
    |> maybe_put_micro_slot(op, target)
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_micro_slot(map, %{operation: op}, target)
       when op in [:put_micro_block, :clear_micro_block] do
    Map.put(map, :micro_slot, Types.micro_index!(target.local_micro))
  end

  defp maybe_put_micro_slot(map, _op, _target), do: map

  # ---------------------------------------------------------------------------
  # 0x66 VoxelSurfaceElementIntent
  # ---------------------------------------------------------------------------

  @doc """
  放置 / 清除表面元件（火炬、拉杆等，形态轨 C5.2）。

  路由与 `apply_edit/2` 相同（lease + ChunkDirectory），但走专用
  `:apply_surface_element` 路径（`ChunkProcess.put/clear_surface_element`，零
  occupancy、全快照下行）。face ordinal 与 surface_type 在 Gate 校验通过后才下发，
  `owner_actor_id` 用发起者 cid 注入。
  """
  @spec apply_surface_element(map(), ctx()) :: {:ok, map()} | {:error, term()}
  def apply_surface_element(request, ctx) do
    with :ok <- authorize_cid(ctx),
         {:ok, action} <- surface_element_action(request.action),
         {:ok, face} <- surface_element_face(request.face),
         :ok <- surface_element_known_type(request.surface_type_id),
         {:ok, target} <- surface_element_target(request),
         {:ok, route} <- Routing.route_chunk(request.logical_scene_id, target.chunk_coord),
         {:ok, scene_node} <- Routing.scene_node_for_route(route) do
      lease = Map.fetch!(route, :lease)

      Sink.emit(ctx.sink, "voxel_surface_element_intent_routed", %{
        connection_pid: self(),
        cid: ctx.cid,
        request_id: request.request_id,
        logical_scene_id: request.logical_scene_id,
        action: action,
        chunk_coord: target.chunk_coord,
        local_macro: target.local_macro,
        face: face,
        surface_type_id: request.surface_type_id,
        region_id: lease.region_id,
        lease_id: lease.lease_id,
        owner_epoch: lease.owner_epoch,
        scene_node: scene_node
      })

      attrs = %{
        request_id: request.request_id,
        logical_scene_id: request.logical_scene_id,
        chunk_coord: target.chunk_coord,
        lease: lease,
        action: action,
        macro_index: target.macro_index,
        face: face,
        surface_type_id: request.surface_type_id,
        attribute_set_ref: request.attribute_set_ref,
        tag_set_ref: request.tag_set_ref,
        owner_actor_id: ctx.cid
      }

      case scene_call(scene_node, {:apply_surface_element, attrs}) do
        {:ok, reply} -> {:ok, Map.merge(reply, %{macro: target.local_macro})}
        {:error, _reason} = error -> error
      end
    end
  end

  defp surface_element_action(0), do: {:ok, :place}
  defp surface_element_action(1), do: {:ok, :clear}
  defp surface_element_action(_other), do: {:error, :invalid_surface_element_action}

  defp surface_element_face(ordinal) when is_integer(ordinal) do
    case SceneServer.Voxel.SurfaceCatalog.face_from_ordinal(ordinal) do
      nil -> {:error, :invalid_surface_element_face}
      face -> {:ok, face}
    end
  end

  defp surface_element_face(_other), do: {:error, :invalid_surface_element_face}

  defp surface_element_known_type(surface_type_id) do
    if SceneServer.Voxel.SurfaceCatalog.known_surface_type?(surface_type_id) do
      :ok
    else
      {:error, :unknown_surface_type}
    end
  end

  # 表面元件绑到 world_micro 落入的宿主宏格那一面 —— 无 face_normal 偏移(放火炬选的是
  # 实心块本身 + 它的某个面)。解析出 chunk_coord + local_macro + macro_index(0..4095)。
  defp surface_element_target(request) do
    {wx, wy, wz} = request.target_world_micro
    micro_resolution = Types.micro_resolution()

    world_macro = {
      Types.floor_div(wx, micro_resolution),
      Types.floor_div(wy, micro_resolution),
      Types.floor_div(wz, micro_resolution)
    }

    {chunk_coord, local_macro} = Types.chunk_and_local_macro!(world_macro)

    {:ok,
     %{
       chunk_coord: chunk_coord,
       local_macro: local_macro,
       macro_index: Types.macro_index!(local_macro)
     }}
  rescue
    _exception in [ArgumentError, FunctionClauseError] ->
      {:error, :invalid_target_world_micro}
  end

  # ---------------------------------------------------------------------------
  # 0x75 VoxelFieldConductIntent
  # ---------------------------------------------------------------------------

  @doc """
  建立电 / 热导通路径。

  解析 source 宏格 → 路由 → 定位 Scene 节点，再 RPC 至
  `SceneServer.Voxel.Field.FieldRuntime.ensure_conduction_path/1`。
  """
  @spec apply_field_conduct(map(), ctx()) :: {:ok, map()} | {:error, term()}
  def apply_field_conduct(request, ctx) do
    with :ok <- authorize_cid(ctx),
         {:ok, source_chunk_coord} <- field_conduct_source_chunk(request),
         {:ok, route} <- Routing.route_chunk(request.logical_scene_id, source_chunk_coord),
         {:ok, scene_node} <- Routing.scene_node_for_route(route) do
      attrs =
        request
        |> Map.take([
          :logical_scene_id,
          :source_world_macro,
          :target_world_macro,
          :source_potential,
          :max_ticks,
          :conduction_mode,
          :output_mode,
          :voltage,
          :current_limit_amps,
          :frequency_hz,
          :load_current_amps,
          :energy_budget_joules
        ])
        |> Map.put(
          :owner_ref,
          {field_conduct_owner_tag(ctx), ctx.cid, request.client_intent_seq}
        )

      case :rpc.call(
             scene_node,
             FieldRuntime,
             :ensure_conduction_path,
             [attrs],
             @scene_call_timeout
           ) do
        {:ok, summary} -> {:ok, summary}
        {:error, reason} -> {:error, reason}
        {:badrpc, reason} -> {:error, {:scene_unavailable, reason}}
        other -> {:error, {:unexpected_field_conduct_result, other}}
      end
    end
  end

  # owner_ref 的传输标签是 FieldRuntime 侧既有的 owner 归属契约,按链路区分
  # (`:tcp_field_conduct` / `:ws_field_conduct`),保持与拆分前一致。
  defp field_conduct_owner_tag(%{sink: %Sink{transport: :tcp}}), do: :tcp_field_conduct
  defp field_conduct_owner_tag(%{sink: %Sink{transport: :ws}}), do: :ws_field_conduct

  defp field_conduct_source_chunk(%{source_world_macro: world_macro}) do
    {chunk_coord, _local_macro} = Types.chunk_and_local_macro!(world_macro)
    {:ok, chunk_coord}
  rescue
    _exception in [ArgumentError, FunctionClauseError] -> {:error, :invalid_source_world_macro}
  end

  # ---------------------------------------------------------------------------
  # 共享底座
  # ---------------------------------------------------------------------------

  @doc "校验发起者已进入场景并持有合法 cid。"
  @spec authorize_cid(ctx()) :: :ok | {:error, :cid_mismatch}
  def authorize_cid(%{cid: cid}) when is_integer(cid) and cid > 0, do: :ok
  def authorize_cid(_ctx), do: {:error, :cid_mismatch}

  defp apply_intent(scene_node, attrs), do: scene_call(scene_node, {:apply_intent, attrs})

  defp scene_call(scene_node, message) do
    case Routing.safe_call(
           {SceneServer.Voxel.ChunkDirectory, scene_node},
           message,
           @scene_call_timeout
         ) do
      {:ok, {:ok, reply}} -> {:ok, reply}
      {:ok, {:error, reason}} -> {:error, reason}
      {:ok, _other} -> {:error, :scene_unavailable}
      {:error, _reason} -> {:error, :scene_unavailable}
    end
  end
end
