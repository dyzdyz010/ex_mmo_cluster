defmodule GateServer.Session.Auth do
  @moduledoc """
  Gate 会话的**鉴权与身份**边界：token 校验、cid 归属校验、角色档案获取。

  这是 Gate 侧唯一的信任边界入口 —— 客户端送上来的 token / cid / username 在这里
  一次性换成 AuthServer 认可的 claims 与角色档案；之后连接进程与共享业务管线只消费
  已构造好的合法状态，不再重复校验、也不再自己解析原始凭据。

  失败一律显式返回 `{:error, reason}`（`:mismatch` / `:cid_mismatch` /
  `:auth_unavailable` / `:server_error`），由调用方编成对应错误帧，不做静默降级。
  """

  alias GateServer.Session.Call

  @doc """
  校验客户端 token，成功返回 claims。

  AuthServer 不可达（无节点 / badrpc）与凭据不匹配是**不同**的失败：前者
  `:auth_unavailable`（可重试），后者 `:mismatch`（业务拒绝）。
  """
  @spec verify_token(term()) :: {:ok, map()} | {:error, atom()}
  def verify_token(token) do
    case auth_node() do
      {:error, _reason} = error ->
        error

      {:ok, auth_node} ->
        case :rpc.call(auth_node, AuthServer.AuthWorker, :verify_token, [token]) do
          {:ok, claims} when is_map(claims) -> {:ok, claims}
          {:error, :mismatch} -> {:error, :mismatch}
          {:badrpc, _reason} -> {:error, :auth_unavailable}
          _ -> {:error, :server_error}
        end
    end
  end

  @doc "从 `GateServer.Interface` 取当前 auth 节点。"
  @spec auth_node() :: {:ok, node()} | {:error, :auth_unavailable}
  def auth_node do
    case Call.safe(GateServer.Interface, :auth_server) do
      {:ok, nil} -> {:error, :auth_unavailable}
      {:ok, auth_node} -> {:ok, auth_node}
      {:error, _reason} -> {:error, :auth_unavailable}
    end
  end

  @doc "校验 claims 是否持有该 cid。"
  @spec authorize_cid(map() | nil, integer()) :: :ok | {:error, atom()}
  def authorize_cid(nil, _cid), do: {:error, :invalid_state}

  def authorize_cid(claims, cid) do
    case apply(AuthServer.AuthWorker, :validate_cid, [claims, cid]) do
      :ok -> :ok
      {:error, :cid_mismatch} -> {:error, :cid_mismatch}
      {:error, _reason} -> {:error, :server_error}
    end
  end

  @doc "取该 claims 授权下的角色记录（含归属校验，由 AuthServer 权威判定）。"
  @spec fetch_authorized_character(map(), integer()) :: {:ok, map()} | {:error, atom()}
  def fetch_authorized_character(claims, cid) do
    with {:ok, auth_node} <- auth_node() do
      case :rpc.call(auth_node, AuthServer.AuthWorker, :fetch_authorized_character, [claims, cid]) do
        {:ok, character} when is_map(character) -> {:ok, character}
        {:error, :account_not_found} -> {:error, :cid_mismatch}
        {:error, :cid_mismatch} -> {:error, :cid_mismatch}
        {:error, :data_service_unavailable} -> {:error, :auth_unavailable}
        {:badrpc, _reason} -> {:error, :auth_unavailable}
        _ -> {:error, :server_error}
      end
    end
  end

  @doc "校验 claims 与客户端自报 username 一致。"
  @spec validate_username(map(), String.t()) :: :ok | {:error, term()}
  def validate_username(claims, username) do
    apply(AuthServer.AuthWorker, :validate_username, [claims, username])
  end

  @doc "构造下游（Scene / Interface）使用的鉴权上下文。字符串键为既有跨 app 契约。"
  @spec build_context(String.t(), term(), map()) :: map()
  def build_context(username, token, claims) do
    %{
      "username" => username,
      "token" => token,
      "session_id" => Map.get(claims, "session_id") || Map.get(claims, :session_id),
      "source" => Map.get(claims, "source") || Map.get(claims, :source),
      "claims" => claims
    }
  end

  @doc "在鉴权上下文里标记当前激活角色。"
  @spec with_active_cid(map() | term(), integer()) :: map() | term()
  def with_active_cid(auth_context, cid) when is_map(auth_context) do
    Map.put(auth_context, "active_cid", cid)
  end

  def with_active_cid(auth_context, _cid), do: auth_context

  @doc """
  把 DataService 的角色记录归一成 Scene 需要的角色档案。

  出生点默认落在 DevSeed 于 chunk (0,0,0) 铺的 16×16 石台上方：移动世界坐标以服务端
  Z 为竖直轴，浏览器渲染侧映射为 x=750, y=100, z=750。
  """
  @spec character_profile(map() | term()) :: map()
  def character_profile(character) when is_map(character) do
    %{
      cid: Map.get(character, :id) || Map.get(character, "id"),
      name:
        Map.get(character, :name) || Map.get(character, "name") ||
          "character-#{Map.get(character, :id) || Map.get(character, "id")}",
      position:
        normalize_position(Map.get(character, :position) || Map.get(character, "position"))
    }
  end

  def character_profile(_character),
    do: %{name: "unknown", position: {750.0, 750.0, 185.0}}

  defp normalize_position(%{} = position) do
    x = map_float(position, ["x", :x], 750.0)
    y = map_float(position, ["y", :y], 750.0)
    z = map_float(position, ["z", :z], 185.0)
    {x, y, z}
  end

  defp normalize_position(_position), do: {750.0, 750.0, 185.0}

  defp map_float(map, keys, default) do
    keys
    |> Enum.find_value(fn key -> Map.get(map, key) end)
    |> case do
      value when is_integer(value) ->
        value * 1.0

      value when is_float(value) ->
        value

      value when is_binary(value) ->
        case Float.parse(value) do
          {parsed, ""} -> parsed
          _ -> default
        end

      _ ->
        default
    end
  end
end
