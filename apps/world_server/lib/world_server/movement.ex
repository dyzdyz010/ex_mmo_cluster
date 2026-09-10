defmodule WorldServer.Movement do
  @moduledoc "Low-frequency routing to the explicitly deployed Scene and canonical World."

  @doc "Resolve one configured scene_id; no process discovery or local singleton inference."
  def route(scene_id) do
    case Map.fetch(Application.fetch_env!(:world_server, :movement_routes), scene_id) do
      {:ok, route} -> {:ok, route}
      :error -> {:error, :scene_unavailable}
    end
  end

  @doc "显式连接两个相邻 Scene 的只读复制；只在控制面执行，输入热路径不调用。"
  def connect_neighbours(a_id, b_id) when a_id != b_id do
    alias SceneServer.Movement.Scene
    with {:ok, a_route} <- route(a_id),
         {:ok, b_route} <- route(b_id),
         {:ok, a} <- Scene.neighbour_endpoint(a_route.scene_ref),
         {:ok, b} <- Scene.neighbour_endpoint(b_route.scene_ref) do
      if a.scene_id == a_id and b.scene_id == b_id and
           a.scene_epoch == a_route.scene_epoch and b.scene_epoch == b_route.scene_epoch and
           a.content_version == b.content_version and a.profile == b.profile do
        :ok = Scene.connect_neighbour(a_route.scene_ref, b.pid, b.origin_us - a.origin_us, b)
        :ok = Scene.connect_neighbour(b_route.scene_ref, a.pid, a.origin_us - b.origin_us, a)
      else
        {:error, :incompatible_neighbours}
      end
    end
  end

  def prepare_transfer(old, next, cut, gate) do
    alias SceneServer.Movement.Scene
    with {:ok, a} <- route(old.scene_id), {:ok, b} <- route(next.scene_id),
         {:ok, ae} <- Scene.neighbour_endpoint(a.scene_ref),
         {:ok, be} <- Scene.neighbour_endpoint(b.scene_ref) do
      if a.world_ref == b.world_ref and ae.origin_us == be.origin_us and
           ae.l0 == be.l0 and ae.profile == be.profile and ae.content_version == be.content_version and
           cut.identity == old and next.session_epoch > old.session_epoch do
        Scene.prepare_transfer(b.scene_ref, next, cut, gate)
      else
        {:error, :incompatible_transfer}
      end
    end
  end

  def commit_transfer(old, next) do
    alias SceneServer.Movement.Scene
    with {:ok, a} <- route(old.scene_id), {:ok, b} <- route(next.scene_id),
         {:ok, observer} <- Scene.detach_transfer(a.scene_ref, old, next) do
      Scene.activate_transfer(b.scene_ref, next, observer)
    end
  end
end
