defmodule GateServer.CodecHandlerCompletenessTest do
  use ExUnit.Case, async: true

  alias GateServer.Codec

  @moduledoc """
  Handler 完备性门禁（S6 / 6.2）。

  ## 根因

  `GateServer.Codec.decode/1` 能解码的 client→server message-type 集合，与各连接
  进程（`TcpConnection` / `WsConnection`）`dispatch/2` 实际拥有的 handler 集合，
  历史上靠人工保持一致，极易漂移：某个 message-type codec 能解但某一端无显式
  handler，会被两端的 catch-all 子句（`dispatch(msg, state)` / `dispatch(_msg,
  state)`）静默吞掉成 `:unknown_message`，运行时不崩溃、不报错，难以被发现。

  ## 门禁机制

  本测试以 `Codec.decodable_message_tags/0` 为**唯一真相源**，对每个连接模块做
  **静态子句头扫描**：解析连接源码 AST，提取所有 `dispatch/2` 显式子句的第一个
  参数元组的首元素 tag，断言 codec 可解码的每个 tag（除按传输豁免的少数项）都有
  对应显式子句。

  之所以走 AST 静态扫描而非运行时调用 `dispatch/2`：两端都有 catch-all 子句，
  运行时探测无法区分"有专属 handler"与"落到 catch-all"。静态子句头扫描精确
  对应"是否真的写了这个 handler"。

  ## 传输豁免（documented exemptions）

  - `:fast_lane_attach`(0x07)：UDP 快速通道专属附着握手，只在 `UdpAcceptor` 处理，
    TCP/WS 会话进程不应处理 → 对 TCP/WS 永久豁免。

  ## 当前已知漂移（tracked debt → 6.1）

  本批立门禁时扫描发现两处真实漂移，登记在 `@tcp_known_drift` / `@ws_known_drift`：

  - `:voxel_field_conduct_intent`(0x75)：**WS 有** dispatch handler，**TCP 缺**。
  - `:skill_cast`(0x09)：**TCP 有** dispatch handler，**WS 缺**。

  本批（6.2）只立门禁、**不碰 tcp/ws 连接逻辑**（它们是 movement-sync 1.2 的发送
  路径，handler 收口属于 6.1 ConnectionCore 的范畴）。门禁因此具备三条性质：
  新增（未登记）漂移立即报红；已登记漂移被 6.1 修复后仍留在表里也报红（提醒清理）；
  当前已知漂移不让整套 gate_server 测试长期挂红。6.1 补齐 handler 后删除对应登记项。
  """

  @tcp_connection_source Path.join([
                           __DIR__,
                           "..",
                           "..",
                           "lib",
                           "gate_server",
                           "worker",
                           "tcp_connection.ex"
                         ])

  @ws_connection_source Path.join([
                          __DIR__,
                          "..",
                          "..",
                          "lib",
                          "gate_server",
                          "worker",
                          "ws_connection.ex"
                        ])

  # 按传输豁免的 message-type tag（永久豁免：该端架构上不应处理）。
  # `:fast_lane_attach`(0x07)：UDP 专属附着握手，只在 UdpAcceptor 处理。
  @tcp_exempt_tags [:fast_lane_attach]
  @ws_exempt_tags [:fast_lane_attach]

  # ── 已知漂移（tracked debt，归 6.1 ConnectionCore 收口修复）──
  #
  # 这两端**当前确有 handler 漂移**：codec 能解码、但该端无显式 dispatch 子句，
  # 运行时落到 catch-all 静默丢弃成 :unknown_message。本批（6.2）只立门禁、
  # 不碰 tcp/ws 连接逻辑（那是 movement-sync 1.2 / 6.1 的路径），故把已知漂移
  # 显式登记在此，使门禁满足三条性质：
  #   1. 新增漂移（不在登记表里的缺失）→ 立即报红；
  #   2. 已登记漂移被 6.1 修复后**仍留在表里** → 报红，提醒删除登记项；
  #   3. 当前已知漂移 → 不让整套 gate_server 测试长期挂红。
  #
  # 6.1 补齐对应 handler 后，必须把该 tag 从这里删除，门禁才会回到"全覆盖"语义。
  @tcp_known_drift [:voxel_field_conduct_intent]
  @ws_known_drift [:skill_cast]

  describe "codec decodable enumeration is internally consistent" do
    test "decodable_message_tags 与 decodable_message_types 同步" do
      assert Codec.decodable_message_tags() ==
               Enum.map(Codec.decodable_message_types(), &elem(&1, 1))
    end

    test "枚举无重复 opcode、无重复 tag" do
      opcodes = Enum.map(Codec.decodable_message_types(), &elem(&1, 0))
      tags = Codec.decodable_message_tags()

      assert opcodes == Enum.uniq(opcodes), "decodable_message_types 存在重复 opcode"
      assert tags == Enum.uniq(tags), "decodable_message_tags 存在重复 tag"
    end

    test "枚举里每个 opcode 用代表帧 decode 后确实产出声明的 tag（防枚举与 decode/1 漂移）" do
      for {opcode, tag} <- Codec.decodable_message_types() do
        frame = representative_frame(opcode, tag)

        assert {:ok, decoded} = Codec.decode(frame),
               "枚举声明 0x#{Integer.to_string(opcode, 16)} 可解码为 #{inspect(tag)}，" <>
                 "但代表帧 decode 失败：#{inspect(frame)}"

        assert elem(decoded, 0) == tag,
               "0x#{Integer.to_string(opcode, 16)} 声明 tag #{inspect(tag)}，" <>
                 "实际 decode 出 #{inspect(elem(decoded, 0))}"
      end
    end
  end

  describe "every decodable message-type has an explicit TCP dispatch handler" do
    test "TcpConnection.dispatch/2 覆盖所有可解码 tag（豁免/已知漂移除外）" do
      handled = dispatch_tags_from_source(@tcp_connection_source)
      assert_handler_completeness("TcpConnection", handled, @tcp_exempt_tags, @tcp_known_drift)
    end

    test "TcpConnection 的每个已知漂移 tag 仍未修复（修复后须从登记表删除）" do
      handled = dispatch_tags_from_source(@tcp_connection_source)
      assert_known_drift_still_present("TcpConnection", handled, @tcp_known_drift)
    end
  end

  describe "every decodable message-type has an explicit WS dispatch handler" do
    test "WsConnection.dispatch/2 覆盖所有可解码 tag（豁免/已知漂移除外）" do
      handled = dispatch_tags_from_source(@ws_connection_source)
      assert_handler_completeness("WsConnection", handled, @ws_exempt_tags, @ws_known_drift)
    end

    test "WsConnection 的每个已知漂移 tag 仍未修复（修复后须从登记表删除）" do
      handled = dispatch_tags_from_source(@ws_connection_source)
      assert_known_drift_still_present("WsConnection", handled, @ws_known_drift)
    end
  end

  # ── 断言辅助 ──

  # 性质 1+3：除豁免与已登记的已知漂移外，必须全覆盖；任何**未登记**的缺失立即报红。
  defp assert_handler_completeness(label, handled_tags, exempt_tags, known_drift) do
    # 注意：Elixir 的 `--` 是**右结合**的，`a -- b -- c` 会解析成
    # `a -- (b -- c)`，导致 known_drift 根本没从 required 里减掉（已登记漂移仍被
    # 当成未登记新漂移报红，与"已知漂移登记"自相矛盾）。必须显式加括号逐步左折叠。
    required = ((Codec.decodable_message_tags() -- exempt_tags) -- known_drift)
    missing = required -- handled_tags

    assert missing == [],
           """
           #{label} 缺少以下可解码 message-type 的显式 dispatch handler（codec 能解但该端会落到 catch-all 静默丢弃）：
             #{inspect(missing)}

           这是**未登记的新漂移**。真相源 Codec.decodable_message_tags(): #{inspect(Codec.decodable_message_tags())}
           #{label} 已有显式 dispatch tag: #{inspect(Enum.sort(handled_tags))}
           传输豁免: #{inspect(exempt_tags)}   已知漂移登记: #{inspect(known_drift)}

           处置：
             - 若确属传输豁免 → 加入对应 *_exempt_tags 并在 @moduledoc 记录理由；
             - 否则为真实 handler 漂移 → 在 6.1 ConnectionCore 收口补齐 handler；
               若本批暂不修，须把该 tag 登记进对应 *_known_drift 并注明归属 finding。
           """
  end

  # 性质 2：登记的已知漂移若被悄悄修复（该端已出现显式 handler），提醒清理登记表。
  defp assert_known_drift_still_present(label, handled_tags, known_drift) do
    stale = known_drift -- (known_drift -- handled_tags)

    assert stale == [],
           """
           #{label} 的以下 tag 已登记为"已知漂移"，但该端现在**已有显式 dispatch handler**：
             #{inspect(stale)}

           说明漂移已被修复，请把这些 tag 从对应 *_known_drift 登记表删除，
           让完备性门禁回到对它们的"全覆盖"语义。
           """
  end

  # ── 静态子句头扫描：从连接源码 AST 提取 dispatch/2 显式子句 tag ──

  defp dispatch_tags_from_source(path) do
    source = File.read!(path)
    {:ok, ast} = Code.string_to_quoted(source)

    ast
    |> collect_dispatch_clause_args()
    |> Enum.map(&clause_tag/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  # 遍历 AST，收集所有 `defp dispatch(arg1, arg2)` / `def dispatch(...)` 的第一个参数。
  defp collect_dispatch_clause_args(ast) do
    {_ast, acc} =
      Macro.prewalk(ast, [], fn node, acc ->
        case node do
          {def_kind, _meta, [{:dispatch, _, [first_arg | _rest]} | _]}
          when def_kind in [:def, :defp] ->
            {node, [first_arg | acc]}

          # 带 guard 的子句头：def(p) dispatch(...) when ...
          {def_kind, _meta, [{:when, _, [{:dispatch, _, [first_arg | _rest]} | _]} | _]}
          when def_kind in [:def, :defp] ->
            {node, [first_arg | acc]}

          _other ->
            {node, acc}
        end
      end)

    acc
  end

  # 从 dispatch 第一个参数中提取 message-type tag。
  # 形如 `{:movement_input, frame_params}` → :movement_input
  # catch-all `msg` / `_msg`（裸变量）→ nil（不算显式 handler）
  defp clause_tag({:{}, _meta, [tag | _rest]}) when is_atom(tag), do: tag

  # 二元组在 AST 里是 `{a, b}` 字面量，不是 `{:{}, _, _}`
  defp clause_tag({tag, _second}) when is_atom(tag), do: tag

  defp clause_tag(_other), do: nil

  # ── 各 message-type 的代表合法帧（用于"枚举与 decode/1 漂移"自检）──
  # 这些帧逐字对齐 `Codec.decode/1` 对应子句的 wire 布局；任一子句 wire 变更
  # 而枚举未同步时，本帧 decode 会失败 / tag 不匹配，从而报红。

  defp representative_frame(_opcode, :movement_input) do
    <<0x01, 2, 9::32-big, 100::32-big, 16::16-big, 0.0::float-32-big, 0.0::float-32-big,
      1.0::float-32-big, 0::16-big>>
  end

  defp representative_frame(_opcode, :enter_scene), do: <<0x02, 7::64-big, 42::64-big>>

  defp representative_frame(_opcode, :time_sync), do: <<0x03, 8::64-big, 999::64-big>>

  defp representative_frame(_opcode, :heartbeat), do: <<0x04, 999::64-big>>

  defp representative_frame(_opcode, :auth_request) do
    <<0x05, 7::64-big, 4::16-big, "user", 5::16-big, "token">>
  end

  defp representative_frame(_opcode, :fast_lane_request), do: <<0x06, 7::64-big>>

  defp representative_frame(_opcode, :fast_lane_attach) do
    <<0x07, 7::64-big, 3::16-big, "tok">>
  end

  defp representative_frame(_opcode, :chat_say), do: <<0x08, 11::64-big, 2::16-big, "hi">>

  defp representative_frame(_opcode, :skill_cast) do
    <<0x09, 12::64-big, 1::16-big, 0::8, -1::64-big-signed, 0.0::float-64-big, 0.0::float-64-big,
      0.0::float-64-big>>
  end

  defp representative_frame(_opcode, :chat_say_scoped) do
    <<0x0A, 11::64-big, 0::8, 2::16-big, "hi">>
  end

  defp representative_frame(_opcode, :voxel_chunk_subscribe) do
    # request_id, logical_scene_id, center (0,0,0), radius 1, want_snapshot 1, known_count 0
    <<0x60, 13::64-big, 77::64-big, 0::32-big-signed, 0::32-big-signed, 0::32-big-signed, 1::8,
      1::8, 0::16-big>>
  end

  defp representative_frame(_opcode, :voxel_chunk_unsubscribe) do
    # request_id, logical_scene_id, chunk_count 0
    <<0x61, 13::64-big, 77::64-big, 0::16-big>>
  end

  defp representative_frame(_opcode, :voxel_chunk_ack) do
    <<0x76, 13::64-big, 77::64-big, 1::16-big, 1::32-big-signed, 2::32-big-signed, 3::32-big-signed,
      5::64-big>>
  end

  defp representative_frame(_opcode, :voxel_impact_intent) do
    <<0x64, 13::64-big, 1::32-big, 77::64-big, 5::32-big, 0::64-big-signed, 0::64-big-signed,
      0::64-big-signed, 2::16-big, 0xDEAD_BEEF::64-big>>
  end

  defp representative_frame(_opcode, :voxel_build_reservation_intent) do
    <<0x65, 200::64-big, 5::32-big, 555::64-big, 9_001::64-big, 17::64-big, -100::64-big-signed,
      -50::64-big-signed, -25::64-big-signed, 200::64-big-signed, 75::64-big-signed,
      50::64-big-signed, 0xCAFE_BABE_DEAD_BEEF::64-big, 5_000::32-big>>
  end

  defp representative_frame(_opcode, :voxel_prefab_place_intent) do
    <<0x67, 300::64-big, 6::32-big, 777::64-big, 8_888::64-big, 21::64-big, 4_242::64-big, 7::32-big,
      1_000::64-big-signed, -2_000::64-big-signed, 3_000::64-big-signed, 90::8, 1::16-big,
      -1::32-big-signed, 0::32-big-signed, 1::32-big-signed, 11::64-big, 1::16-big, 9_001::64-big,
      1::64-big, 1::16-big, -1::32-big-signed, 0::32-big-signed, 1::32-big-signed, 1_234::16-big,
      5::32-big, 0xAABB_CCDD::32-big, 0x0000_0001::32-big>>
  end

  defp representative_frame(_opcode, :voxel_debug_probe) do
    cmd = "ping"
    <<0x6F, 13::64-big, byte_size(cmd)::16-big, cmd::binary>>
  end

  defp representative_frame(_opcode, :voxel_edit_intent) do
    # 固定 91 字节 payload（含 opcode 共 92 字节），逐字段对齐 decode/1 的 0x70 子句。
    <<0x70, 13::64-big, 1::32-big, 77::64-big, 0::8, 0::8, 0::64-big-signed, 0::64-big-signed,
      0::64-big-signed, 0::8-signed, 0::8-signed, 1::8-signed, 0::16-big, 0::32-big, 0::64-big,
      0::32-big, 0::32-big, 0::64-big, 0::32-big, 0xDEAD_BEEF::64-big>>
  end

  defp representative_frame(_opcode, :voxel_field_conduct_intent) do
    # power_flags=0 → 后续 power 字段不解析，但 wire 仍需占位（decode 子句固定布局）。
    <<0x75, 13::64-big, 1::32-big, 77::64-big, 0::64-big-signed, 0::64-big-signed, 0::64-big-signed,
      10::64-big-signed, 0::64-big-signed, 0::64-big-signed, 1.0::float-64, 100::32-big, 0::8, 0::8,
      0::16-big, 0.0::float-64, 0.0::float-64, 0.0::float-64, 0.0::float-64, 0.0::float-64>>
  end
end
