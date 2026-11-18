defmodule NpcServer.Http do
  @moduledoc """
  全局系统功能：NPC 模型适配器共用的 JSON HTTP 发送器，不解释决策或技能。

  ## httpc profile

  `:httpc` 缺省 profile 有新请求时优先排进同一主机上正忙的 keep-alive 会话，而不是另开连接
  （OTP `httpc_manager:select_session/4`）。有人在等的交互请求若与没人在等的慢请求共用一个 profile，
  就会排在慢请求后面、超时时从队列取消而从未发出（召回隔离决策稿 E1、D-1）。所以 endpoint 可带
  `profile`（atom）选一个命名 profile：活动选择走 `NpcServer.Jev.selection_profile/0`，写作留在缺省 profile。

  命名 profile 由 `start_profile/1` / `stop_profile/1` 起停（`NpcServer.Application` 在监督树之前起），
  全部用 httpc 缺省参数；profile 不在时请求返回 `{:error, {:profile_not_started, 名}}`，不退回缺省 profile。
  """
  # 缺省请求超时（毫秒）；endpoint 的 `timeout_ms` 覆盖它。高推理强度的大上下文请求（如 design_house 后几轮）
  # 常超过 60 s：超时的请求已经计费却拿不到结果（2026-10-08 长跑 run03：gpt-6.1-sol / high 设计会话 6 次败 5 次）。
  @timeout_ms 60_000

  @doc """
  发送一次请求，返回 JSON 响应或明确的传输错误；超时取 endpoint 的 `timeout_ms`（缺省 #{@timeout_ms} ms）。

  请求头缺省只有 `authorization: Bearer <endpoint.key>`；endpoint 带 `headers`（`[{名, 值}]`，都是字符串）时
  改用这一组、不再加 `authorization`（例如 Anthropic Messages 形状的入口用 `x-api-key`）。
  `content-type: application/json` 总由本函数带上，调用方不必写进 `headers`。

  endpoint 带 `profile`（atom）时走该命名 httpc profile，它不在时返回 `{:error, {:profile_not_started, 名}}`；
  不带就走缺省 profile。
  """
  def request(endpoint, body) do
    ssl =
      [
        verify: :verify_peer,
        customize_hostname_check: [match_fun: :public_key.pkix_verify_hostname_match_fun(:https)]
      ] ++
        case endpoint do
          %{cacertfile: path} -> [cacertfile: String.to_charlist(path)]
          _ -> [cacerts: :public_key.cacerts_get()]
        end

    headers =
      for {name, value} <- Map.get_lazy(endpoint, :headers, fn -> bearer(endpoint) end),
          do: {String.to_charlist(name), String.to_charlist(value)}

    request =
      {String.to_charlist(endpoint.url), headers, ~c"application/json", Jason.encode!(body)}

    timeout = Map.get(endpoint, :timeout_ms, @timeout_ms)
    profile = Map.get(endpoint, :profile)

    result =
      try do
        :httpc.request(
          :post,
          request,
          [ssl: ssl, timeout: timeout],
          [body_format: :binary],
          profile || :default
        )
      catch
        # 只把"命名 profile 不在"折成显式失败；缺省 profile 不在（inets 没起）与其它退出照旧上抛。
        :exit, reason ->
          if profile != nil and profile_absent?(reason),
            do: {:error, {:profile_not_started, profile}},
            else: exit(reason)
      end

    case result do
      {:ok, {{_, 200, _}, _, response}} -> {:ok, Jason.decode!(response)}
      {:ok, {{_, status, _}, _, response}} -> {:error, {status, String.slice(response, 0, 300)}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  以 httpc 缺省参数起一个命名 profile，幂等：新起返回 `{:ok, :started}`，已经在返回 `{:ok, :already_started}`，
  其它错误原样返回给调用方（应用启动边界）。运行期由 inets 监督，manager 重启后仍是缺省参数。
  """
  def start_profile(profile) do
    case :inets.start(:httpc, profile: profile) do
      {:ok, _pid} -> {:ok, :started}
      {:error, {:already_started, _pid}} -> {:ok, :already_started}
      other -> other
    end
  end

  @doc "停一个命名 httpc profile；不在视同已停。"
  def stop_profile(profile) do
    case :inets.stop(:httpc, profile) do
      :ok -> :ok
      # 实测（OTP 29.1.2）：profile 不在时 `inets:stop/2` 回 `{:error, :not_found}`。
      {:error, :not_found} -> :ok
      other -> other
    end
  end

  @doc """
  `:httpc.request/5` 的退出原因是否表示所用 profile 不在（没起、被停、inets 停了）：httpc 调它的 manager 时以
  `GenServer.call` 到点 / 对端不在的形状退出。用于把这一类折成 `{:profile_not_started, 名}`，其它退出不吞。
  """
  def profile_absent?(:noproc), do: true
  def profile_absent?(:shutdown), do: true
  def profile_absent?(:normal), do: true
  def profile_absent?({reason, _detail}), do: profile_absent?(reason)
  def profile_absent?(_), do: false

  # 缺省鉴权头（现有的 OpenAI 形状入口与 Jev 都用它）。
  defp bearer(endpoint), do: [{"authorization", "Bearer " <> endpoint.key}]
end
