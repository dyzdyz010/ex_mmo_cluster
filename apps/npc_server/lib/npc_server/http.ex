defmodule NpcServer.Http do
  @moduledoc """
  全局系统功能：NPC 全部出站 HTTP（模型与 Hindsight）的唯一出口，不解释决策、技能或记忆。

  ## 车道

  请求按“此刻有没有人在等”分两条车道（Finch 决策稿 §2、D-2）：

  | 车道 | 谁 | 取连接上限 `pool_timeout` |
  |---|---|---|
  | `:interactive` | 活动选择与对话回合选择、对话回合与说话的写作、交互召回 | 2 s |
  | `:background` | 反思与日计划写作、后台召回、retain / 刷新 / 状态，以及没标车道的调用方 | 30 s |

  车道由调用方给：模型 endpoint 带 `lane`（没带就是 `:background`，没人在等的请求不会占交互车道的连接），
  Hindsight 适配器按请求类别自己给。每条车道有自己的 Finch 实例、自己的连接池，所以同一主机上的慢写作 / retain
  在结构上不可能挡住选择或召回（决策稿 §1 的两次实跑故障：httpc 把交互请求排进正忙的 keep-alive 会话）。

  ## 每条车道两个 Finch 实例（按协议）

  Finch 的池配置只能按 `{scheme, host, port}` 写死或用一份 `:default`，而本应用的主机来自运行环境（模型地址、
  Hindsight 地址、测试替身的随机端口）。所以每条车道按协议起两个实例，各用一份 `:default`：

  - `https` → HTTP/2 实例（`count` 1，一条连接多路复用；模型主机 DeepSeek / TypeSafe / 网关都经 ALPN 协商 h2，
    2026-11-18 实测）。TLS 用 Mint 的缺省：校验对端与主机名，信任根在**建连时**取系统 CA（`:public_key.cacerts_get/0`），
    所以没有系统 CA 的环境只在真要连 https 时显式失败，不影响应用启动。endpoint 带 `cacertfile` 时（Voxim Gameplay
    Demo 的容器没有系统 CA，自带 CA 包）改信这个文件：同车道 HTTP/2 实例里按该路径打标签的池（见下）。
  - `http` → HTTP/1 实例（每主机 `size` 8 条连接；Hindsight 与回环替身）。连接全忙时请求在 Finch 的取连接队列里
    显式排队，超过车道的 `pool_timeout` 返回 `{:error, :pool_timeout}`，那一笔从未发出。

  不在运行中给不同协议的池起配置：HTTP/2 池断线期间会按实例的 `:default` 重新找池，拿到 `:default` 的协议模块
  （finch 0.25.0 `Finch.Pool.Manager`），与动态起的池协议不一致就会问错进程。唯一的动态池是 `cacertfile` 的标签池：
  它与所在实例的 `:default` 同为 HTTP/2，重新找池时协议模块一致；每次请求前 `Finch.start_pool/3` 确保它在（已在即返回）。
  数值（`size` 8、`count` 1、2 s / 30 s）是原创初值，实跑后调。

  ## 超时契约（召回隔离决策稿 D-3a，按 Finch 决策稿 §3 改写）

  一笔请求分三段，各有一个上限、各报各的失败：

  | 段 | 上限 | 谁给 | 超了报 |
  |---|---|---|---|
  | 取连接（HTTP/1 池全忙时排队） | `pool_timeout`：交互 2 s、后台 30 s | 车道 | `:pool_timeout`（那一笔从未发出） |
  | 建连（TCP / TLS 握手） | Mint `transport_opts` 的 `timeout`：交互 2 s、后台 30 s | 车道 | HTTP/1 为传输错误；HTTP/2 池在取连接上限内连不上报 `:connection_unavailable` |
  | 发送与接收 | `timeout_ms`（Finch `request_timeout`），`receive_timeout` 取同值 | endpoint / 适配器 | `:timeout` |

  - `timeout_ms` 是发送与接收这一段的唯一截止。HTTP/1 上 `request_timeout` 只在两次读之间检查，单次读由 `receive_timeout`
    兜住，两者合起来不会挂死；最坏情况是最后一次读在截止前一刻开始，这一段约为 2×`timeout_ms`。
  - 所以调用方看到的最坏总时长约为取连接上限 + 建连上限 + 2×`timeout_ms`；正常情况下前两段是毫秒级（回环或已建好的连接）。
  - Finch 的 HTTP/2 兜底计时（2×`request_timeout` 仍无回执时抛错）也折成 `:timeout`，不让它打崩调用的 worker。
  - 放弃即取消：超时时 Finch 关掉 HTTP/1 连接（HTTP/2 发 RST_STREAM）；调用进程被杀时它持有的 HTTP/1 连接随之关闭。
    调用方不再套第二个计时器（T-3 用替身实测）。

  ## 排队时长

  `with_queue_ms/1` 读 Finch 的 `[:finch, :queue, :stop | :exception]`（“Time taken to check out a pool connection”），
  只有 HTTP/1 池有取连接这一步；HTTP/2 多路复用、没有取连接队列，读数为 nil。`NpcServer.ModelUsage` 把它记进
  `npc_model_request` 的 `queue_ms`。

  ## 密钥

  模型 endpoint 的 `key` 是 `NpcServer.Secret` 闭包，随 profile 流转时不以原文出现在进程状态与崩溃报告里；
  `request/2` 是唯一取出它的地方，取出后只作为局部变量进请求头（见 `request/2` 的说明）。

  头值不合法（Mint HTTP/1 只收 33..126、SP、HTAB）时 Mint 的错误原因带着整条头值；`finch_request/8` 在错误离开本模块前
  把它折成不带值的 `{:invalid_header_value, 头名}`（脱敏，不是兜底，结果仍是失败）。`endpoint.key` 不是 Secret 时
  `NpcServer.Secret.reveal/1` 抛不带值的 ArgumentError。

  残余（取出之后的明文请求头交给 Finch / Mint；不改 Finch。依据为本仓库锁定的 finch 0.25.0、mint 1.11.0、hpax 1.1.0
  与 OTP 29 / Elixir 1.20 源码，均为读源码所得，未实测）：

    * HTTP/1（`http` 主机：Hindsight、回环替身）：请求在发起请求的进程里编码发送，明文头只在它的栈与堆上停留到请求结束。
    * HTTP/2（`https` 模型主机），在途期间：Finch HTTP/2 池进程（`:gen_statem`）把请求存进 `data.requests`，其中
      telemetry 元数据里的 `Finch.Request` 带着请求头（`finch/http2/pool.ex` 的 `send_request/6`），请求结束才删除。
    * HTTP/2，`x-api-key`（Messages 形状的写作 endpoint）还会常驻：Mint 以 `:store_name` 编码请求头
      （`mint/http2.ex` 的 `encode_header_block/4`）；`x-api-key` 不在 HPACK 静态表里，走 `:not_found` 分支，名和值
      一起进连接的动态编码表（`hpax.ex` 的 `encode_headers/3`、`Table.add/3`），留在池进程里，直到连接关闭或被新条目挤出。
      `authorization` 在静态表里（只有名字），走“只存名”的分支，Bearer 的值不进动态表。
    * 池进程崩溃时的报告：Finch 没有实现 `format_status`。OTP 的 gen_statem 终止报告（domain `[otp]`，Elixir 缺省不过滤）
      经 Elixir `Logger.Translator` 打印时，`Queue:`（待处理事件，可能含排队中的 `{:request, …}` 调用及其请求头）在任何
      日志级别都打印，`State:`（池的 `data`，即上面的 `requests` 与编码表）只在 debug 级别打印。
    * VM 崩溃时上述进程的堆会进 `erl_crash.dump`：部署侧应关闭或限制转储（`ERL_CRASH_DUMP_BYTES=0` 不写转储），
      见 `deploy/README.md` 的“NPC 常驻应用”一节。

  ## 生命周期

  本模块是一个监督者（四个 Finch 实例），由 `NpcServer.Application` 放在 NPC 监督树的第一位；测试跑 `--no-start`
  时由 `test_helper` 起同一个。
  """
  use Supervisor
  alias NpcServer.Secret

  # 缺省请求超时（毫秒）；endpoint 的 `timeout_ms` 覆盖它。高推理强度的大上下文请求（如 design_house 后几轮）
  # 常超过 60 s：超时的请求已经计费却拿不到结果（2026-10-08 长跑 run03：gpt-6.1-sol / high 设计会话 6 次败 5 次）。
  @timeout_ms 60_000

  # 车道取连接的上限（毫秒）：交互请求有人在等，排不上就尽早显式失败；后台请求可以等。原创初值（决策稿 D-4）。
  @pool_timeout_ms %{interactive: 2_000, background: 30_000}

  # 车道建连（TCP / TLS 握手）的上限（毫秒），同上取值、原创初值。不配时是 Mint 缺省的 30 s，
  # 一次丢 SYN 的建连会把 10 s 的交互召回拖到 30 s 以上。
  @connect_timeout_ms %{interactive: 2_000, background: 30_000}

  # {车道, 协议} → Finch 实例名。
  @instances %{
    {:interactive, :http1} => NpcServer.Http.InteractiveHttp1,
    {:interactive, :http2} => NpcServer.Http.InteractiveHttp2,
    {:background, :http1} => NpcServer.Http.BackgroundHttp1,
    {:background, :http2} => NpcServer.Http.BackgroundHttp2
  }

  # HTTP/1 池每主机的连接上限、HTTP/2 池的连接数（原创初值，决策稿 D-4）。
  @http1_pool_size 8
  @http2_pool_count 1

  # Finch 在 HTTP/1 取连接超时时不返回错误而是抛出这条消息（finch 0.25.0 `Finch.HTTP1.Pool.request/6`）。
  @pool_timeout_message "Finch was unable to provide a connection within the timeout"
  # Finch 的 HTTP/2 兜底计时到点时抛出这条消息（同版本 `Finch.HTTP2.Pool.response_waiting_loop/6`）。
  @http2_fail_safe_message "no response was received even after waiting"

  # 排队时长在调用进程里的暂存键：Finch 的取连接与 telemetry 都在调用进程里执行（NimblePool 的 checkout 函数）。
  @queue_key {__MODULE__, :queue_ms}

  @doc "起四个 Finch 实例（两条车道 × 两种协议）并挂上排队时长的 telemetry。"
  def start_link(_opts \\ []), do: Supervisor.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(nil) do
    # 处理器挂在 telemetry 的全局表里；监督者重启时已经在，`:already_exists` 视同成功。
    case :telemetry.attach_many(
           @queue_key,
           [[:finch, :queue, :stop], [:finch, :queue, :exception]],
           &__MODULE__.record_queue/4,
           Map.values(@instances)
         ) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end

    children =
      for {{lane, protocol}, name} <- @instances do
        Supervisor.child_spec({Finch, name: name, pools: %{default: pool(lane, protocol)}},
          id: name
        )
      end

    Supervisor.init(children, strategy: :one_for_one)
  end

  defp pool(lane, :http1),
    do: [
      protocols: [:http1],
      size: @http1_pool_size,
      conn_opts: [transport_opts: [timeout: Map.fetch!(@connect_timeout_ms, lane)]]
    ]

  defp pool(lane, :http2), do: http2_pool(lane, [])

  # TLS 的校验与信任根交给 Mint 的缺省（verify_peer、建连时取系统 CA）；只有 `cacertfile` 标签池显式给 CA 文件。
  defp http2_pool(lane, ca),
    do: [
      protocols: [:http2],
      count: @http2_pool_count,
      conn_opts: [transport_opts: [timeout: Map.fetch!(@connect_timeout_ms, lane)] ++ ca]
    ]

  @doc """
  发送一次模型 JSON 请求（POST），返回解码后的 JSON 响应或明确的失败；超时取 endpoint 的 `timeout_ms`（缺省 #{@timeout_ms} ms），
  车道取 endpoint 的 `lane`（缺省 `:background`）。

  `endpoint.key` 是 `NpcServer.Secret`（`NpcServer.Registry` 在读运行环境时包好），本函数是唯一取出它的地方：
  在拼请求头的那一刻按 `auth` 写成鉴权头——缺省 `authorization: Bearer <key>`，`auth: :x_api_key` 时为 `x-api-key: <key>`
  （Anthropic Messages 形状的入口）。endpoint 可带 `headers`（`[{名, 值}]`，都是小写字符串，不放敏感值）附加在鉴权头之后。
  `content-type: application/json` 总由本函数带上，调用方不必写进 `headers`。
  endpoint 带 `cacertfile`（PEM 路径）时 https 请求只信这个 CA 文件（见 moduledoc）。

  结果：`{:ok, map}`（200；响应体不是 JSON 时 `Jason.decode!/1` 抛出，由调用方在自己的边界处理）、
  `{:error, {状态码, 响应体前 300 字}}`、`{:error, :timeout}`、`{:error, :pool_timeout}`、`{:error, :connection_unavailable}`、
  `{:error, {:unsupported_scheme, 协议}}`、`{:error, {:invalid_header_value, 头名}}`（头值不合法，值已去掉，见 moduledoc 的“密钥”）、
  `{:error, 传输错误}`（含义见 moduledoc 的超时契约）。`endpoint.key` 不是 `NpcServer.Secret` 时抛 ArgumentError（不回显值）。
  """
  def request(endpoint, body) do
    headers =
      [
        {"content-type", "application/json"},
        auth_header(endpoint) | Map.get(endpoint, :headers, [])
      ]

    case send_request(
           lane(endpoint),
           :post,
           endpoint.url,
           headers,
           Jason.encode!(body),
           Map.get(endpoint, :timeout_ms, @timeout_ms),
           cacertfile: Map.get(endpoint, :cacertfile)
         ) do
      {:ok, 200, response} -> {:ok, Jason.decode!(response)}
      {:ok, status, response} -> {:error, {status, String.slice(response, 0, 300)}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  经指定车道发一次请求，返回 `{:ok, 状态码, 响应体}` 或
  `{:error, :timeout | :pool_timeout | :connection_unavailable | {:unsupported_scheme, 协议} | {:invalid_header_value, 头名} | 传输错误}`。
  `headers` 是 `[{小写名, 值}]`，`body` 为 nil 或已编码的 binary；`timeout_ms` 是发送与接收这一段的截止（三段上限见 moduledoc）。
  模型请求用 `request/2`；Hindsight 适配器直接用本函数（它有 GET / PUT / PATCH 与自己的状态码规则）。
  `opts` 可给 `cacertfile:`（https 只信这个 CA 文件；nil 或不给用系统 CA）。
  """
  def send_request(lane, method, url, headers, body, timeout_ms, opts \\ []) do
    case URI.parse(url) do
      %URI{scheme: scheme} when scheme in ["http", "https"] ->
        instance = instance(lane, scheme)
        tag = pool_tag(instance, lane, scheme, url, Keyword.get(opts, :cacertfile))
        finch_request(instance, tag, lane, method, url, headers, body, timeout_ms)

      %URI{scheme: scheme} ->
        {:error, {:unsupported_scheme, scheme}}
    end
  end

  # `cacertfile` 只对 https 有意义：在该车道的 HTTP/2 实例里用以路径为标签的池（配置同 `:default`，只多 CA 文件）。
  defp pool_tag(instance, lane, "https", url, path) when is_binary(path) do
    tag = {:cacertfile, path}

    :ok =
      Finch.start_pool(
        instance,
        Finch.Pool.new(url, tag: tag),
        http2_pool(lane, cacertfile: path)
      )

    tag
  end

  defp pool_tag(_instance, _lane, _scheme, _url, _path), do: :default

  defp finch_request(instance, tag, lane, method, url, headers, body, timeout_ms) do
    result =
      try do
        method
        |> Finch.build(url, headers, body, pool_tag: tag)
        |> Finch.request(instance,
          pool_timeout: Map.fetch!(@pool_timeout_ms, lane),
          request_timeout: timeout_ms,
          receive_timeout: timeout_ms
        )
      rescue
        error in RuntimeError ->
          cond do
            String.starts_with?(error.message, @pool_timeout_message) -> {:error, :pool_timeout}
            String.starts_with?(error.message, @http2_fail_safe_message) -> {:error, :timeout}
            true -> reraise(error, __STACKTRACE__)
          end
      end

    case result do
      {:ok, %Finch.Response{status: status, body: response}} ->
        {:ok, status, response}

      {:error, :pool_timeout} ->
        {:error, :pool_timeout}

      # HTTP/2 没有取连接队列：池在 `pool_timeout` 内没连上（DNS、拒绝连接、证书、没协商出 h2，或断线重连中）。
      # 这是“连不上”而不是排队，单列一个原因。
      {:error, %Finch.Error{reason: :pool_not_available}} ->
        {:error, :connection_unavailable}

      {:error, %{reason: reason}} when reason in [:timeout, :request_timeout] ->
        {:error, :timeout}

      # 请求头的值不合法（Mint HTTP/1 只收 33..126、SP、HTAB）：Mint 的原因带着整条头值，鉴权头就是 "Bearer <key>"，
      # Finch 包成 `%Finch.HTTPError{}`（`source` 里还有一份 `%Mint.HTTPError{}`）原样返回，调用方的失败日志会把它打出来，
      # 对话构建器还会把它拼进下一次提示词。错误离开本信任边界前去掉值、只留头名——这是脱敏，不是兜底：
      # 结果仍是显式失败。登记边界（`Registry`）已按同一字符集校验 key，这里接住的是直接拼 endpoint 的调用方。
      {:error, %{reason: {:invalid_header_value, name, _value}}} ->
        {:error, {:invalid_header_value, name}}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc "endpoint 所属的车道：带 `lane` 用它，没带是 `:background`。"
  def lane(endpoint), do: Map.get(endpoint, :lane, :background)

  @doc """
  执行 `fun` 并返回 `{fun 的结果, 排队毫秒或 nil}`：期间本进程最后一次从车道的 HTTP/1 池取连接所等的时长。
  没取过 HTTP/1 连接（HTTP/2、注入的发送函数、在取连接前就失败）时为 nil。
  """
  def with_queue_ms(fun) do
    Process.delete(@queue_key)
    result = fun.()
    {result, Process.delete(@queue_key)}
  end

  @doc false
  # telemetry 处理器：只记本模块的实例。必须不抛错，否则 telemetry 会把它摘掉、之后的读数静默变成 nil。
  def record_queue(_event, %{duration: duration}, %{name: name}, instances) do
    if name in instances,
      do: Process.put(@queue_key, System.convert_time_unit(duration, :native, :millisecond))

    :ok
  end

  def record_queue(_event, _measurements, _metadata, _instances), do: :ok

  defp instance(lane, "https"), do: Map.fetch!(@instances, {lane, :http2})
  defp instance(lane, "http"), do: Map.fetch!(@instances, {lane, :http1})

  # 鉴权头：key 只在这里取出（`NpcServer.Secret`）。缺省 Bearer（OpenAI 形状入口、Jev、LLM 大脑）；
  # Anthropic Messages 形状的写作入口由 `Life.Reflection.Writer` 标 `auth: :x_api_key`。
  defp auth_header(%{auth: :x_api_key, key: key}), do: {"x-api-key", Secret.reveal(key)}
  defp auth_header(%{key: key}), do: {"authorization", "Bearer " <> Secret.reveal(key)}
end
