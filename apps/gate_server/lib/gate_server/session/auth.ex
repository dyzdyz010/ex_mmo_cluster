defmodule GateServer.Session.Auth do
  @moduledoc """
  Gate 会话的**鉴权与身份**边界：token 校验、cid 归属校验、角色档案获取。

  这是 Gate 侧唯一的信任边界入口 —— 客户端送上来的 token / cid / username 在这里
  一次性换成 AuthServer 认可的 claims 与角色档案；之后连接进程与共享业务管线只消费
  已构造好的合法状态，不再重复校验、也不再自己解析原始凭据。

  失败一律显式返回 `{:error, reason}`（`:mismatch` / `:cid_mismatch` /
  `:auth_unavailable` / `:server_error`），由调用方编成对应错误帧，不做静默降级。
  """

  @doc """
  正式 Join 消费一次性票据；开发免密仅在显式 Test-only 部署开放。
  两条路径得到的角色行都在这里附上阵营档案（Voxim Docs/Factions.md §3），随 Scene.join 进入实体值。
  """
  def join(join, hello) do
    with {:ok, character, ref} <- authorize(join, hello),
         do: {:ok, %{character | profile: DataService.Orgs.profile(character)}, ref}
  end

  defp authorize(join, hello) do
    if Application.get_env(:auth_server, :dev_auto_login, false) do
      with {:ok, claims} <- verify_token(join.token),
           :ok <- validate_username(claims, join.username),
           :ok <- authorize_cid(claims, join.cid),
           {:ok, character} <- fetch_authorized_character(claims, join.cid),
           do: {:ok, character, nil}
    else
      owner = Process.whereis(AuthServer.Connections)

      if is_pid(owner) do
        ref = Process.monitor(owner)

        case AuthServer.Identity.consume_ticket(
               join.token,
               join.cid,
               join.username,
               join.scene_id,
               hello,
               self()
             ) do
          {:ok, %{character: character}} ->
            {:ok, character, ref}

          error ->
            Process.demonitor(ref, [:flush])
            error
        end
      else
        {:error, :auth_unavailable}
      end
    end
  end

  @doc """
  校验客户端 token，成功返回 claims；凭据不匹配为 `:mismatch`。

  Gate 与 AuthServer 同在一个节点（Voxim 单节点部署），直接调用 `AuthServer.AuthWorker`。
  """
  @spec verify_token(term()) :: {:ok, map()} | {:error, atom()}
  def verify_token(token) do
    case AuthServer.AuthWorker.verify_token(token) do
      {:ok, claims} when is_map(claims) -> {:ok, claims}
      {:error, :mismatch} -> {:error, :mismatch}
    end
  end

  @doc "校验 claims 是否持有该 cid。"
  @spec authorize_cid(map() | nil, integer()) :: :ok | {:error, atom()}
  def authorize_cid(nil, _cid), do: {:error, :invalid_state}

  def authorize_cid(claims, cid) do
    case AuthServer.AuthWorker.validate_cid(claims, cid) do
      :ok -> :ok
      {:error, :cid_mismatch} -> {:error, :cid_mismatch}
    end
  end

  @doc "取该 claims 授权下的角色记录（含归属校验，由 AuthServer 权威判定）。"
  @spec fetch_authorized_character(map(), integer()) :: {:ok, map()} | {:error, atom()}
  def fetch_authorized_character(claims, cid) do
    case AuthServer.AuthWorker.fetch_authorized_character(claims, cid) do
      {:ok, character} when is_map(character) -> {:ok, character}
      {:error, :account_not_found} -> {:error, :cid_mismatch}
      {:error, :cid_mismatch} -> {:error, :cid_mismatch}
      {:error, :data_service_unavailable} -> {:error, :auth_unavailable}
      _ -> {:error, :server_error}
    end
  end

  @doc "校验 claims 与客户端自报 username 一致。"
  @spec validate_username(map(), String.t()) :: :ok | {:error, term()}
  def validate_username(claims, username) do
    AuthServer.AuthWorker.validate_username(claims, username)
  end
end
