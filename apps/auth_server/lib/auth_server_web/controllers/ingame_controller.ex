defmodule AuthServerWeb.IngameController do
  @moduledoc """
  Voxim 客户端的 HTTP 入口：登录签发令牌、批量 region 载荷与已发布 prefab 列表。

  ## Route map

  - `POST /ingame/auto_login` -> `auto_login/2`（`dev_auto_login` 开启时）
  - `POST /ingame/voxel/regions` -> `voxel_regions/2`（Voxim R6，二进制批量 region 载荷）
  - `POST /ingame/voxel/prefabs` -> `voxel_prefabs/2`（Voxim D3-2，运行时发布的 prefab 列表）
  - `POST /playtest/{login,regions,prefabs}` -> 邀请码身份的同一组入口
  """

  use AuthServerWeb, :controller
  require Logger

  @doc "账号访问凭据已由 AccountAccess 校验，资源仍来自同一世界 owner。"
  def game_regions(%{assigns: %{account_context: _}}=conn,_), do: do_voxel_regions(conn)
  @doc "已认证账号读取同一正式 prefab 列表。"
  def game_prefabs(%{assigns: %{account_context: _}}=conn,_), do: do_voxel_prefabs(conn)

  @doc """
  Demo JSON auto-login. Upserts account+character then returns a signed token.

  Gated by `config :auth_server, :dev_auto_login`. Responds 403 when disabled.
  """
  def auto_login(conn, params) do
    if Application.get_env(:auth_server, :dev_auto_login, false) do
      do_auto_login(conn, params)
    else
      conn
      |> put_status(:forbidden)
      |> json(%{error: "dev_auto_login_disabled"})
    end
  end

  @doc "使用接纳边界确认的邀请码身份登录，忽略请求中的自报昵称。"
  def playtest_login(%{assigns: %{playtest_username: username}} = conn, _params),
    do: do_auto_login(conn, %{"username" => username})

  @doc "已确认的受邀客户端读取权威 region；不依赖开发免密入口开关。"
  def playtest_regions(%{assigns: %{playtest_username: _}} = conn, _params),
    do: do_voxel_regions(conn)

  @doc "已确认的受邀客户端读取运行时发布的 prefab 列表。"
  def playtest_prefabs(%{assigns: %{playtest_username: _}} = conn, _params),
    do: do_voxel_prefabs(conn)

  @doc """
  Voxim R6：批量 region 载荷拉取（`application/octet-stream` 进出；线格式见 `MmoContracts.Voxel.Codec`）。

  后端是 `VoxelRegion.World`（烘焙文件 ⊕ overlay 日志，`VOXEL_REGION_ROOT`）；与其它 `/voxel/*` 一样只在 `dev_auto_login` 下开放。
  """
  def voxel_regions(conn, _params) do
    if Application.get_env(:auth_server, :dev_auto_login, false) do
      do_voxel_regions(conn)
    else
      conn
      |> put_status(:forbidden)
      |> json(%{error: "dev_auto_login_disabled"})
    end
  end

  defp do_auto_login(conn, params) do
    username = params["username"] |> normalize_username()

    cond do
      username == nil ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "invalid_username"})

      true ->
        case AuthServer.Accounts.upsert_dev(username) do
          {:ok, %{account: account, character: character}} ->
            token =
              username
              |> AuthServer.AuthWorker.build_session_claims(
                source: "ingame_auto_login",
                account_id: account.id,
                cid: character.id
              )
              |> AuthServer.AuthWorker.issue_token()

            json(conn, %{token: token, cid: character.id, username: username})

          {:error, reason} ->
            Logger.warning("auto_login failed for #{username}: #{inspect(reason)}")

            conn
            |> put_status(:service_unavailable)
            |> json(%{error: "auto_login_failed"})
        end
    end
  end

  def voxel_prefabs(conn, _params) do
    if Application.get_env(:auth_server, :dev_auto_login, false) do
      do_voxel_prefabs(conn)
    else
      conn
      |> put_status(:forbidden)
      |> json(%{error: "dev_auto_login_disabled"})
    end
  end

  defp do_voxel_prefabs(conn) do
    {:ok, %{world_ref: world_ref}} =
      WorldServer.Movement.route(Application.fetch_env!(:auth_server, :voxel_scene_id))

    conn
    |> put_resp_content_type("application/octet-stream")
    |> send_resp(
      200,
      MmoContracts.Voxel.Codec.encode_prefab_list(VoxelRegion.World.published_prefabs(world_ref))
    )
  end

  defp do_voxel_regions(conn) do
    {:ok, body, conn} = Plug.Conn.read_body(conn, length: 16_000_000, read_length: 1_000_000)

    result =
      with {:ok, %{world_ref: world_ref}} <-
             WorldServer.Movement.route(Application.fetch_env!(:auth_server, :voxel_scene_id)) do
        VoxelRegion.World.serve(world_ref, body)
      end

    case result do
      {:ok, reply} ->
        conn
        |> put_resp_content_type("application/octet-stream")
        |> send_resp(200, reply)

      {:error, :invalid_request} ->
        send_resp(conn, 400, "invalid_request")

      _ ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: "voxel_region_root_unavailable"})
    end
  end

  defp normalize_username(value) when is_binary(value) do
    trimmed = String.trim(value)

    cond do
      trimmed == "" -> nil
      String.length(trimmed) > 32 -> nil
      true -> trimmed
    end
  end

  defp normalize_username(_), do: nil
end
