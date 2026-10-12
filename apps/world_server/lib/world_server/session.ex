defmodule WorldServer.Session do
  @moduledoc """
  全局系统功能：角色会话占用的唯一登记处，不依赖传输。分配 session identity，同一 cid 的新 claim 撤销旧会话，
  跨 Scene 移交在提交前保持旧 owner。QUIC 连接与 NPC Body 都是它的调用者；被监视的是调用者进程。
  """
  use GenServer
  alias MmoContracts.Session.Identity

  @doc "启动唯一会话登记处；生产由 WorldServer 监督，测试可使用独立名字。"
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))

  @doc "以调用进程占用角色并加入权威 Scene，替换同 cid 的旧会话。"
  def claim(server, scene, route, character),
    do: GenServer.call(server, {:claim, scene, route, character})

  @doc "准备跨 Scene 移交；调用者必须仍是该身份的 owner。"
  def prepare_transfer(server, identity, target_scene_id, artifact),
    do: GenServer.call(server, {:prepare_transfer, identity, target_scene_id, artifact})

  @doc "提交已经准备好的移交；提交前旧 Scene 保持 owner。"
  def commit_transfer(server, old, fresh, cid),
    do: GenServer.call(server, {:commit_transfer, old, fresh, cid})

  @impl true
  def init(opts),
    do: {:ok, %{opts: opts, characters: %{}, next_epoch: System.system_time(:microsecond)}}

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    characters =
      Map.reject(state.characters, fn {_, owner} -> owner.pid == pid and owner.monitor == ref end)

    {:noreply, %{state | characters: characters}}
  end

  @impl true
  def handle_call({:claim, scene, route, character}, {pid, _}, state) do
    cid = character.id

    case state.characters[cid] do
      nil ->
        :ok

      previous ->
        :ok = previous.scene.leave(previous.scene_ref, previous.identity, 2)
        send(previous.pid, {:mmo_close, previous.identity, 2})
    end

    identity = %Identity{
      session_epoch: state.next_epoch,
      scene_id: route.scene_id,
      scene_epoch: route.scene_epoch
    }

    # 同一登记处先 leave 后 join，Scene 的邮箱顺序保证旧成员先退出；不等旧连接关闭。
    result = scene.join(route.scene_ref, identity, character, pid)

    owner = %{
      pid: pid,
      identity: identity,
      monitor: Process.monitor(pid),
      scene: scene,
      scene_ref: route.scene_ref
    }

    {:reply, {identity, result},
     %{
       state
       | next_epoch: state.next_epoch + 1,
         characters: Map.put(state.characters, cid, owner)
     }}
  end

  def handle_call({:prepare_transfer, old, target_scene_id, artifact}, {pid, _}, state) do
    case state.characters[artifact.id] do
      %{pid: ^pid, identity: ^old} ->
        router = Keyword.get(state.opts, :route_module, WorldServer.Movement)

        with {:ok, route} <- router.route(target_scene_id) do
          fresh = %Identity{
            session_epoch: state.next_epoch,
            scene_id: target_scene_id,
            scene_epoch: route.scene_epoch
          }

          # 分配只预留 epoch；角色 owner 在目标 Ready 提交前仍指向旧 Scene。
          state = %{state | next_epoch: state.next_epoch + 1}

          case router.prepare_transfer(old, fresh, artifact, pid) do
            {:ok, player} -> {:reply, {:ok, fresh, route, player}, state}
            {:error, reason} -> {:reply, {:error, reason}, state}
          end
        else
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      _ ->
        {:reply, {:error, :stale_owner}, state}
    end
  end

  def handle_call({:commit_transfer, old, fresh, cid}, {pid, _}, state) do
    case state.characters[cid] do
      %{pid: ^pid, identity: ^old} = owner ->
        router = Keyword.get(state.opts, :route_module, WorldServer.Movement)

        with {:ok, route} <- router.route(fresh.scene_id),
             :ok <- router.commit_transfer(old, fresh) do
          owner = %{owner | identity: fresh, scene_ref: route.scene_ref}
          {:reply, :ok, %{state | characters: Map.put(state.characters, cid, owner)}}
        else
          {:error, reason} -> {:reply, {:error, reason}, state}
        end

      _ ->
        {:reply, {:error, :stale_owner}, state}
    end
  end
end
