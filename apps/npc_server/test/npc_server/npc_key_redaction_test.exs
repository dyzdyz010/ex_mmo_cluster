Code.require_file("../support/http_stub.exs", __DIR__)

defmodule NpcServer.NpcKeyRedactionTest do
  @moduledoc """
  只测试：模型 API key 不随 profile 进日志（`NpcServer.Secret`，依据见其 moduledoc）。

  契约：
    * 正式登记入口（`NpcServer.Registry.brain/2`）解析出的 profile 被 `inspect` 时不含任何一个 key 的原文
      （`NPC_LLM_KEY`、`NPC_REFLECT_KEY`、`TYPESAFE_API_KEY`、`NPC_JEV_KEY` 四处各放一个可识别的假 key）；
    * 持有 profile 的真实进程崩溃时，Logger 打出的崩溃报告不含 key：选技能 worker（`NpcServer.Skills.start/5`
      起的进程，它的 context 里装着整份 profile）。经 `NpcServer.Runtime` 的正式命令入口投一个合法的 travel 命令，
      充当 Body 的测试进程交回缺 `movement_profile` 的会话上下文，worker 读它时 KeyError；Elixir 的 KeyError 消息
      会把整个 context 打印进 ERTS 的崩溃报告——与出错函数参数进堆栈（ERLEF《Protecting sensitive data》的
      “Prune arguments from stack traces”）同一类泄露：持有敏感值的项被整段格式化进日志；
    * key 不是合法的 HTTP 头值（含 CR / LF 等控制字符，或首尾有空格 / 制表符；RFC 9110 §5.5）时登记被拒：
      `Registry.brain/2` 抛 ArgumentError，消息只报变量名与原因，消息与捕获的日志都不含原值；中间的空白照常接受；
    * 出站请求头里仍是正确的 key：Bearer（LLM 的 endpoint，`NpcServer.Http.request/2`）与 `x-api-key`
      （写作 endpoint 的 Messages 形状，`NpcServer.Life.Reflection.Writer.write/4`），对端是本机回环替身。

  层次与依赖：真实 Registry / Runtime / Brain.Llm / Skills / Http（Finch）照常运行；Body 由测试进程充当
  （Runtime 把 `init/2` 的调用进程当作 Body），对端是 `test/support/http_stub.exs`。不起 World / Scene / Postgres，
  不发真实模型请求。不覆盖：Finch 池进程里在途请求的请求头（残余，见 `NpcServer.Http` moduledoc）、erl_crash.dump。
  """
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  @moduletag :key_redaction
  @moduletag :capture_log

  alias NpcServer.{Http, HttpStub, Runtime, Secret}
  alias NpcServer.Life.Reflection.Writer
  alias NpcServer.Registry, as: NpcRegistry

  # 只测试：可识别的假 key，每个环境变量一个，断言按原文查找。
  @llm_key "fake-npc-llm-key-5c1e"
  @reflect_key "fake-npc-reflect-key-9a42"
  @typesafe_key "fake-typesafe-key-3d7b"
  @jev_key "fake-npc-jev-key-e810"
  @keys [@llm_key, @reflect_key, @typesafe_key, @jev_key]

  @npc %{
    "who" => "Lin, a builder",
    "persona" => %{"traits" => %{"thrifty" => 8}, "personal" => "Dislikes crowds."},
    "tools" => %{"1" => "镐"},
    "activities" => [
      %{
        "name" => "rest_at_home",
        "criterion" => "Go home and rest.",
        "place" => [2, -3.5],
        "stay_ticks" => 600
      }
    ]
  }

  # 手动节奏：Brain.Llm 只在 `step/4` 许可下发请求，本文件不给许可，所以不会向 NPC_LLM_URL 发任何请求。
  @llm %{"goal" => "Rest.", "tools" => %{}, "skills" => ["travel"], "cadence" => "manual"}

  setup do
    # 端口 9（discard）本机不监听；只有显式指向替身的用例才会真的发请求。
    put_env(%{
      "NPC_LLM_URL" => "http://127.0.0.1:9/responses",
      "NPC_LLM_KEY" => @llm_key,
      "NPC_LLM_MODEL" => "llm-test",
      "NPC_LLM_EFFORT" => nil,
      "NPC_LLM_CACERTFILE" => nil,
      "NPC_LLM_TIMEOUT_MS" => nil,
      "TYPESAFE_API_URL" => "http://127.0.0.1:9/jev",
      "TYPESAFE_API_KEY" => @typesafe_key,
      "TYPESAFE_MODEL" => "jev-test",
      "NPC_JEV_API" => nil,
      "NPC_JEV_URL" => "http://127.0.0.1:9/chat/completions",
      "NPC_JEV_KEY" => @jev_key,
      "NPC_JEV_MODEL" => "jev-openai-test",
      "NPC_JEV_EFFORT" => nil,
      "NPC_JEV_MAX_TOKENS" => nil,
      "NPC_JEV_THINKING" => nil,
      "NPC_REFLECT_URL" => "http://127.0.0.1:9/v1/messages",
      "NPC_REFLECT_KEY" => @reflect_key,
      "NPC_REFLECT_MODEL" => "reflect-test",
      "NPC_REFLECT_API" => nil,
      "NPC_REFLECT_EFFORT" => nil,
      "NPC_LIFE_HINDSIGHT_URL" => "http://life.test.invalid"
    })
  end

  test "inspect 正式登记出来的 profile 不含任何 key 原文" do
    {_, npc} = NpcRegistry.brain("npc", @npc)
    {_, llm} = NpcRegistry.brain("llm", @llm)

    # 选择位置的另一种入口形状（OpenAI 兼容，key 取 NPC_JEV_KEY）；setup 已登记还原。
    System.put_env("NPC_JEV_API", "openai")
    {_, npc_openai} = NpcRegistry.brain("npc", @npc)

    # 四处 key 确实进了 profile（否则下面的 refute 是空断言）：取出入口在 `NpcServer.Http`，这里只核对位置。
    assert Map.has_key?(npc.jev, :key) and Map.has_key?(npc.reflect, :key)
    assert Map.has_key?(llm.endpoint, :key) and Map.has_key?(npc_openai.jev, :key)

    text = inspect([npc, llm, npc_openai], limit: :infinity, printable_limit: :infinity)

    for key <- @keys, do: refute(text =~ key, "inspect 输出里出现了 key 原文 #{key}")
  end

  test "持有 profile 的技能 worker 崩溃时，崩溃报告不含 key" do
    # Runtime 在技能终态时把这次调用记进 NPC 记忆（`DataService.NpcMemory`），要本 VM 独占的测试库与一个真实 NPC 角色。
    MmoTest.Database.start!()
    {:ok, %{id: cid}} = DataService.CharacterStore.ensure_npc("密钥脱敏测试 NPC")
    {backend, profile} = NpcRegistry.brain("llm", @llm)

    log =
      capture_log(fn ->
        # 测试进程充当 Body：Runtime 把 init/2 的调用进程当作 Body（技能 worker 向它取会话上下文）。
        runtime = Runtime.init({backend, profile}, %{cid: cid})

        send(
          runtime,
          {:observation, %{self: %{entity_id: cid, position: {0.0, 0.0, 0.0}}, entities: []}}
        )

        # 合法的技能命令经 Runtime 正式命令入口受理；Body（测试进程）交回的会话上下文缺 `movement_profile`，
        # worker 读它时 KeyError——Elixir 的 KeyError 消息会把整个 context（含 profile）打印出来。
        command = %{id: 7, verb: :skill, skill: :travel, args: %{"x" => 1.0, "z" => 2.0}}
        GenServer.cast(runtime, {:command, command})

        assert_receive {:"$gen_call", {worker, _} = from, :skill_context}, 2_000
        monitor = Process.monitor(worker)
        GenServer.reply(from, {:ok, %{}})

        # 退出原因是 Erlang 形的 `{:badkey, 键, map}`（Logger 打印时才规范成 KeyError）。
        assert_receive {:DOWN, ^monitor, :process, ^worker,
                        {{:badkey, :movement_profile, _context}, _}},
                       2_000

        # Runtime 把 worker 的退出记成技能终态（含写记忆）之后才算本用例的动作结束，不留在途工作。
        assert settled?(runtime, 20)

        # 崩溃报告由 ERTS 在进程因异常终止时交给 logger_proxy，再到各 handler；同步一次让它处理完。
        :sys.get_state(:logger_proxy)
      end)

    # 崩溃报告确实抓到了，而且打印了装着 profile 的 context（否则下面的 refute 是空断言）。
    assert log =~ "raised an exception"
    assert log =~ "key :movement_profile not found in"
    assert log =~ "endpoint: %{"

    for key <- @keys, do: refute(log =~ key, "崩溃报告里出现了 key 原文 #{key}")
  end

  test "出站请求头里仍是正确的 key：LLM 用 Bearer，写作（Messages）用 x-api-key" do
    url = HttpStub.start(fn :post, _path, _body -> {200, %{"ok" => true}} end)
    System.put_env("NPC_LLM_URL", url <> "/responses")
    System.put_env("NPC_REFLECT_URL", url <> "/v1/messages")

    {_, llm} = NpcRegistry.brain("llm", @llm)
    {_, npc} = NpcRegistry.brain("npc", @npc)

    assert {:ok, %{"ok" => true}} = Http.request(llm.endpoint, %{})
    assert [%{path: "/responses", headers: headers}] = HttpStub.requests(1)
    assert headers["authorization"] == "Bearer " <> @llm_key
    refute Map.has_key?(headers, "x-api-key")

    # 写作应答不是 Messages 形状，Writer 报 invalid_response；这里只看发出去的请求头。
    capture_log(fn ->
      assert {:error, :invalid_response} = Writer.write(npc.reflect, "s", "u")
    end)

    assert [%{path: "/v1/messages", headers: headers}] = HttpStub.requests(1)
    assert headers["x-api-key"] == @reflect_key
    assert headers["anthropic-version"] == "2023-06-01"
    refute Map.has_key?(headers, "authorization")
  end

  # 四个 key 各自所在的登记：变量名 → {brain, 参数, 额外环境}。
  @key_sites [
    {"NPC_LLM_KEY", "llm", @llm, %{}},
    {"NPC_REFLECT_KEY", "npc", @npc, %{}},
    {"TYPESAFE_API_KEY", "npc", @npc, %{}},
    {"NPC_JEV_KEY", "npc", @npc, %{"NPC_JEV_API" => "openai"}}
  ]

  # 不合法的 key：{环境变量的值, 值里可识别的一段（断言不回显用）, 错误里应有的原因}。
  @invalid_keys [
    {"fake-crlf-key-0001\r\n", "fake-crlf-key-0001", "控制字符"},
    # 环境变量本身装不下 NUL（C 字符串），另取一个 CTL（ESC）。
    {"fake-esc\ekey-0002", "key-0002", "控制字符"},
    {" fake-lead-space-key-0003", "fake-lead-space-key-0003", "首尾空白"},
    {"fake-trail-tab-key-0004\t", "fake-trail-tab-key-0004", "首尾空白"},
    # obs-text（0x80–0xFF）RFC 允许、Mint HTTP/1 不收：尾随 NBSP、零宽空格、全角字符。
    {"fake-nbsp-key-0005 ", "fake-nbsp-key-0005", "非 ASCII"},
    {"fake-zwsp​key-0006", "key-0006", "非 ASCII"},
    {"fake-fullwidth-ｋｅｙ-0007", "fake-fullwidth-", "非 ASCII"},
    {"", nil, "为空"}
  ]

  test "key 不是合法的 HTTP 头值时登记被拒，错误与日志只报变量名与原因、不回显原值" do
    for {env, brain, params, extra} <- @key_sites, {value, core, reason} <- @invalid_keys do
      System.put_env(env, value)
      for {k, v} <- extra, do: System.put_env(k, v)

      log =
        capture_log(fn ->
          error = assert_raise ArgumentError, fn -> NpcRegistry.brain(brain, params) end
          message = Exception.message(error)
          assert message =~ env and message =~ reason, "#{env}：#{message}"
          if core, do: refute(message =~ core, "#{env} 的错误回显了原值")
        end)

      if core, do: refute(log =~ core, "#{env} 的日志回显了原值")

      # 还原成合法值与缺省入口形状，下一组只坏一个变量。
      System.put_env(env, "fake-valid-key-for-#{env}")
      System.delete_env("NPC_JEV_API")
    end

    # 中间的空格与制表符是 RFC 9110 field-content 允许、Mint HTTP/1 也收的，不拒。
    System.put_env("NPC_LLM_KEY", "fake key\twith inner space")
    assert {_, %{endpoint: %{key: _}}} = NpcRegistry.brain("llm", @llm)
  end

  test "尾随 NBSP 的 key 在登记时被拒，HTTP/1 回环替身收不到任何请求" do
    url = HttpStub.start(fn :post, _path, _body -> {200, %{"ok" => true}} end)
    System.put_env("NPC_LLM_URL", url <> "/responses")
    System.put_env("NPC_LLM_KEY", "fake-nbsp-key-0008 ")

    error = assert_raise ArgumentError, fn -> NpcRegistry.brain("llm", @llm) end
    refute Exception.message(error) =~ "fake-nbsp-key-0008"
    refute_received {:http_request, _}
  end

  test "不合法的头值走到 Http.request 时，返回的错误与日志不带原值" do
    url = HttpStub.start(fn :post, _path, _body -> {200, %{"ok" => true}} end)

    # 绕过登记、直接构造的 endpoint（代码里直接拼 endpoint 的调用方会这样）：Mint HTTP/1 拒绝这个头值。
    endpoint = %{url: url <> "/responses", key: Secret.wrap("fake-bad-header-key-0009 ")}

    log =
      capture_log(fn ->
        result = Http.request(endpoint, %{})
        assert result == {:error, {:invalid_header_value, "authorization"}}
        refute inspect(result, limit: :infinity) =~ "fake-bad-header-key-0009"
      end)

    refute log =~ "fake-bad-header-key-0009"
    refute_received {:http_request, _}
  end

  test "endpoint 的 key 不是 Secret 时显式失败，错误与崩溃报告不带原值" do
    endpoint = %{url: "http://127.0.0.1:9/responses", key: "fake-plain-key-0010"}

    error = assert_raise ArgumentError, fn -> Http.request(endpoint, %{}) end
    assert Exception.message(error) =~ "NpcServer.Secret"
    refute Exception.message(error) =~ "fake-plain-key-0010"

    # 同样的调用在一个进程里崩溃：崩溃报告也不能带出原值（FunctionClauseError 会把实参打进栈帧）。
    # 用 Task：它在退出前于自己进程里同步记下崩溃报告，`:DOWN` 到达时报告已经被捕获，没有时序竞争。
    log =
      capture_log(fn ->
        {:ok, pid} = Task.start(fn -> Http.request(endpoint, %{}) end)
        monitor = Process.monitor(pid)
        assert_receive {:DOWN, ^monitor, :process, ^pid, _}, 2_000
      end)

    assert log =~ "terminating"
    assert log =~ "NpcServer.Secret"
    refute log =~ "fake-plain-key-0010"
  end

  # Runtime 已没有在途技能（`observe` 的 `skill` 为 nil）；每 100 ms 看一次，至多 `tries` 次。
  defp settled?(runtime, tries) do
    cond do
      Runtime.observe(runtime).skill == nil -> true
      tries == 0 -> false
      true -> receive(after: (100 -> settled?(runtime, tries - 1)))
    end
  end

  # 写入本用例的环境变量（nil = 删除），用例结束时还原。
  defp put_env(env) do
    previous = Map.new(env, fn {key, _} -> {key, System.get_env(key)} end)
    on_exit(fn -> set_env(previous) end)
    set_env(env)
  end

  defp set_env(env) do
    for {key, value} <- env,
        do: if(value, do: System.put_env(key, value), else: System.delete_env(key))

    :ok
  end
end
