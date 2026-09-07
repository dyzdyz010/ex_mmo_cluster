defmodule GateServer.Session.Scene do
  @moduledoc """
  Gate 会话与 Scene 侧的**接入契约**：场景节点发现、玩家进场、移动输入投递。

  连接进程本身不知道 Scene 的内部结构，只通过本模块的稳定入口协作；所有跨进程调用
  都经 `GateServer.Session.Call.safe/3`，把 Scene 崩溃 / 不可达显式回成
  `{:error, :scene_unavailable}` 而不是拖垮连接。
  """

  alias GateServer.Session.Call
  alias SceneServer.Movement.{InputFrame, RemoteSnapshot}

  @doc "从 `GateServer.Interface` 取当前 scene 节点。"
  @spec scene_node() :: {:ok, node()} | {:error, :scene_unavailable}
  def scene_node do
    case Call.safe(GateServer.Interface, :scene_server) do
      {:ok, nil} -> {:error, :scene_unavailable}
      {:ok, scene_node} -> {:ok, scene_node}
      {:error, _reason} -> {:error, :scene_unavailable}
    end
  end

  @doc """
  在目标场景节点上拉起玩家角色进程，返回其 pid。

  `connection_pid` 是 Scene 侧回推快照 / 事件的目标；显式传入而不是取 `self()`，
  让「谁是这条会话的出口」成为契约的一部分。
  """
  @spec add_player(node(), integer(), pid(), integer(), map()) ::
          {:ok, pid()} | {:error, :scene_unavailable}
  def add_player(scene_node, cid, connection_pid, timestamp, character_profile) do
    case Call.safe(
           {SceneServer.PlayerManager, scene_node},
           {:add_player, cid, connection_pid, timestamp, character_profile}
         ) do
      {:ok, {:ok, ppid}} -> {:ok, ppid}
      {:ok, _other} -> {:error, :scene_unavailable}
      {:error, _reason} -> {:error, :scene_unavailable}
    end
  end

  @doc "取玩家当前权威位置。"
  @spec player_location(pid()) ::
          {:ok, {float(), float(), float()}} | {:error, :scene_unavailable}
  def player_location(player_pid) do
    case Call.safe(player_pid, :get_location) do
      {:ok, {:ok, location}} -> {:ok, location}
      {:ok, _other} -> {:error, :scene_unavailable}
      {:error, _reason} -> {:error, :scene_unavailable}
    end
  end

  @doc """
  取刚拉起的玩家角色的下一个期望输入序号。

  Audit B-S1 / B-SRV1：该序号经 EnterSceneResult 下发给客户端，客户端据此对齐预测
  序列，避免进场首帧就被判 stale（帧布局见 `MmoContracts.Session.Codec`）。
  """
  @spec next_input_seq(pid()) :: {:ok, non_neg_integer()} | {:error, :scene_unavailable}
  def next_input_seq(player_pid) do
    case Call.safe(player_pid, :get_next_input_seq) do
      {:ok, {:ok, seq}} -> {:ok, seq}
      {:ok, _other} -> {:error, :scene_unavailable}
      {:error, _reason} -> {:error, :scene_unavailable}
    end
  end

  @doc "会话结束时通知玩家角色退出；未进场（`nil`）是合法状态。"
  @spec cleanup(pid() | nil) :: :ok
  def cleanup(nil), do: :ok

  def cleanup(scene_ref) do
    _ = Call.safe(scene_ref, :exit)
    :ok
  end

  @doc """
  投递一帧移动输入。

  `:accepted` 表示 Scene 收下但本帧不回 ack（批量 tick 后再统一回推）；
  `{:ok, ack}` 表示同步拿到权威 ack。
  """
  @spec accept_movement_input(pid(), InputFrame.t()) ::
          :accepted | {:ok, term()} | {:error, term()}
  def accept_movement_input(spid, frame) do
    case Call.safe(spid, {:movement_input, frame}) do
      {:ok, {:ok, :accepted}} -> :accepted
      {:ok, {:ok, ack}} -> {:ok, ack}
      {:ok, {:error, reason}} -> {:error, reason}
      {:error, reason} -> {:error, reason}
      {:ok, _other} -> {:error, :scene_unavailable}
    end
  end

  @doc "把 codec 解出的输入帧 map 归一成 `InputFrame` 结构（已是结构则原样返回）。"
  @spec build_input_frame(map()) :: InputFrame.t()
  def build_input_frame(%{} = frame) do
    if Map.get(frame, :__struct__) == InputFrame do
      frame
    else
      struct(InputFrame, %{
        seq: Map.fetch!(frame, :seq),
        client_tick: Map.fetch!(frame, :client_tick),
        dt_ms: Map.fetch!(frame, :dt_ms),
        input_dir: Map.fetch!(frame, :input_dir),
        speed_scale: Map.fetch!(frame, :speed_scale),
        movement_flags: Map.fetch!(frame, :movement_flags)
      })
    end
  end

  @doc """
  校验回推的远端快照确实是 `RemoteSnapshot`。

  这是进程边界上的一次性契约校验：形状不对说明 Scene 侧发了未知消息，属于编程错误，
  直接 raise 让连接崩掉并留下现场，不静默丢弃。
  """
  @spec normalize_remote_snapshot(map()) :: RemoteSnapshot.t()
  def normalize_remote_snapshot(%{} = snapshot) do
    if Map.get(snapshot, :__struct__) == RemoteSnapshot do
      snapshot
    else
      raise ArgumentError, "expected remote snapshot map, got: #{inspect(snapshot)}"
    end
  end

  @doc """
  把远端快照编成 `player_move` 下行消息。

  优先级字段（band / score / distance / interval）齐备时用带优先级的扩展形，
  全空时退回基础形 —— 两种 arity 都是既有 wire 契约，不能合并。
  """
  @spec player_move_message(RemoteSnapshot.t()) :: tuple()
  def player_move_message(
        %RemoteSnapshot{
          priority_band: nil,
          priority_score: nil,
          observer_distance: nil,
          delivery_interval: nil
        } = snapshot
      ) do
    {:player_move, snapshot.cid, snapshot.server_tick, snapshot.position, snapshot.velocity,
     snapshot.acceleration, snapshot.movement_mode}
  end

  def player_move_message(%RemoteSnapshot{} = snapshot) do
    {:player_move, snapshot.cid, snapshot.server_tick, snapshot.position, snapshot.velocity,
     snapshot.acceleration, snapshot.movement_mode, snapshot.priority_band,
     snapshot.priority_score, snapshot.observer_distance, snapshot.delivery_interval}
  end
end
