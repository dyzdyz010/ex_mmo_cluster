# 移动同步支柱 1.1 — 协议 wire 一次性升级 实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 把移动同步 wire 协议一次性升级到目标格式——热点帧带 `schema_version`、握手带 `protocol_version`(fail-fast 一致性断言)、`PlayerMove`/`MovementAck` 带 `server_send_ms`(wall-clock)、decode 带长度守卫——双端(Elixir codec + TS gateProtocol)同步改，**无迁移债**（不保留旧 layout / 不双 schema 并存）。

**Architecture:** 纯协议层切片。本 plan 只改 wire 编解码 + 发送瞬间注入 `server_send_ms` + 握手版本断言；**不改** tick 语义（支柱 1.2）、**不改**客户端插值时间轴消费 `server_send_ms` 的逻辑（支柱 1.3——客户端本 plan 只负责把字段解析出来存好）。完成后双端在新 wire 上正常通信、现有行为不回归。

**Tech Stack:** Elixir（`gate_server` codec，ExUnit）+ Rust 无关 + TypeScript（`web_client` gateProtocol，vitest）。

---

## 目标 wire layout（schema_version = 1，本 plan 一次到位）

> 字节含 opcode。`server_send_ms` 放在固定字段区（priority meta 之前），保证紧凑/完整版位置一致。

**Movement `0x01`（上行，26B）**
```
0x01 | schema_version u8 | seq u32 | client_tick u32 | dt_ms u16
     | input_dir_x f32 | input_dir_y f32 | speed_scale f32 | movement_flags u16
```

**PlayerMove `0x83`（下行）—— 紧凑版 95B / 完整版 106B**
```
0x83 | schema_version u8 | cid u64 | server_tick u32 | server_send_ms u64
     | x f64 | y f64 | z f64 | vx f64 | vy f64 | vz f64 | ax f64 | ay f64 | az f64
     | movement_mode u8
     [完整版追加] | priority_band u8 | priority_score f32 | observer_distance f32 | delivery_interval u16
```

**MovementAck `0x8b`（下行，113B）**
```
0x8b | schema_version u8 | ack_seq u32 | auth_tick u32 | server_send_ms u64 | cid u64
     | px f64 | py f64 | pz f64 | vx f64 | vy f64 | vz f64 | ax f64 | ay f64 | az f64
     | movement_mode u8 | correction_flags u32 | fixed_dt_ms u16 | ground_z f64
```

**EnterSceneResult `0x84`（下行成功帧，40B）**
```
0x84 | packet_id u64 | status u8(0x00) | x f64 | y f64 | z f64 | expected_seq u32 | protocol_version u16
```

常量：`PROTOCOL_VERSION = 1`、`MOVEMENT_WIRE_SCHEMA = 1`。

---

## File Structure

**服务端（Elixir）**
- `apps/gate_server/lib/gate_server/codec.ex` — 常量 + 全部 encode/decode 改动（核心）
- `apps/gate_server/lib/gate_server/worker/tcp_connection.ex` — `player_move`/`movement_ack` 发送处注入 `server_send_ms`；`enter_scene` 成功帧带 `protocol_version`
- `apps/gate_server/lib/gate_server/worker/udp_acceptor.ex` — UDP 直回 ack 发送处注入 `server_send_ms`（**实测发现的第二发送端，原 plan 遗漏**）
- `apps/gate_server/lib/gate_server/worker/ws_connection.ex` — WebSocket 发送处注入 `server_send_ms` + `player_move_message/2`（**第三发送端，原 plan 遗漏**）
- `apps/gate_server/test/gate_server/codec_test.exs` — codec 单元测试
- `apps/gate_server/test/gate_server/tcp_connection_protocol_test.exs` — 握手/movement e2e 测试

**客户端（TS, `clients/web_client/src`）**
- `infrastructure/net/protocolVersion.ts` — **新建**：`PROTOCOL_VERSION` / `MOVEMENT_WIRE_SCHEMA` 常量
- `infrastructure/net/gateProtocol.ts` — encode/decode 改动
- `infrastructure/net/gateProtocol.test.ts` — vitest

> 注：本 plan 改的 `MovementAck`/`PlayerMove` decode 会新增 `serverSendMs` 字段到返回结构。`ServerGateMessage` 类型定义同处更新。客户端**解析并存储** `serverSendMs`，但本 plan 不改插值/和解对它的使用（留 1.3）。

---

## Phase 1：服务端 codec（Elixir）

### Task 1：协议版本常量

**Files:**
- Modify: `apps/gate_server/lib/gate_server/codec.ex`（在 `@status_error 0x01` 之后的常量区追加）

- [ ] **Step 1：添加常量**

在 `codec.ex` 常量区（`@status_ok` / `@status_error` 附近）追加：

```elixir
  # ── Protocol versioning (Pillar 1.1) ──
  # PROTOCOL_VERSION 在 enter-scene 握手回传，客户端 fail-fast 断言一致。
  # MOVEMENT_WIRE_SCHEMA 是热点帧（movement/player_move/ack）的逐帧 schema 守卫。
  @protocol_version 1
  @movement_wire_schema 1

  @doc "当前线协议版本（握手协商）。"
  def protocol_version, do: @protocol_version

  @doc "当前移动热点帧 wire schema 版本。"
  def movement_wire_schema, do: @movement_wire_schema
```

- [ ] **Step 2：提交**

```bash
git add apps/gate_server/lib/gate_server/codec.ex
git commit -m "feat(codec): add protocol_version/movement_wire_schema constants (pillar 1.1)"
```

---

### Task 2：Movement `0x01` decode 加 schema_version + 长度守卫

**Files:**
- Modify: `apps/gate_server/lib/gate_server/codec.ex:138-156`
- Test: `apps/gate_server/test/gate_server/codec_test.exs`

- [ ] **Step 1：改测试（test-first）**

替换 `codec_test.exs` 中 `describe "decode movement input"` 的两个用例为带 `schema_version` 字节的新 layout，并加一个 schema 不符的拒绝用例：

```elixir
  describe "decode movement input" do
    test "decodes movement input with all fields (schema v1)" do
      msg =
        <<0x01, 1, 55::32-big, 1000::32-big, 100::16-big, 1.0::float-32-big, 0.5::float-32-big,
          1.25::float-32-big, 3::16-big>>

      assert {:ok,
              {:movement_input,
               %{
                 seq: 55,
                 client_tick: 1000,
                 dt_ms: 100,
                 input_dir: {1.0, 0.5},
                 speed_scale: 1.25,
                 movement_flags: 3
               }}} == Codec.decode(msg)
    end

    test "rejects movement input with unknown schema version" do
      msg =
        <<0x01, 9, 55::32-big, 1000::32-big, 100::16-big, 1.0::float-32-big, 0.5::float-32-big,
          1.25::float-32-big, 3::16-big>>

      assert {:error, :unsupported_schema} = Codec.decode(msg)
    end

    test "rejects truncated movement input" do
      assert {:error, :invalid_message} = Codec.decode(<<0x01, 1, 55::32-big>>)
    end
  end
```

- [ ] **Step 2：运行测试，确认失败**

Run: `cd apps/gate_server && mix test test/gate_server/codec_test.exs --no-start`
Expected: FAIL（旧 decode 不识别 schema 字节，断言不符）

- [ ] **Step 3：改实现**

替换 `codec.ex:138-156` 的 Movement decode：

```elixir
  # MovementInput (schema v1): 1 + 1 + 4 + 4 + 2 + 4 + 4 + 4 + 2 = 26 bytes
  def decode(
        <<@msg_movement, @movement_wire_schema, seq::32-big, client_tick::32-big, dt_ms::16-big,
          input_dir_x::float-32-big, input_dir_y::float-32-big, speed_scale::float-32-big,
          movement_flags::16-big>>
      ) do
    {:ok,
     {:movement_input,
      %{
        seq: seq,
        client_tick: client_tick,
        dt_ms: dt_ms,
        input_dir: {input_dir_x * 1.0, input_dir_y * 1.0},
        speed_scale: speed_scale * 1.0,
        movement_flags: movement_flags
      }}}
  end

  def decode(<<@msg_movement, schema, _rest::binary>>) when schema != @movement_wire_schema,
    do: {:error, :unsupported_schema}

  def decode(<<@msg_movement, _rest::binary>>), do: {:error, :invalid_message}
```

- [ ] **Step 4：运行测试，确认通过**

Run: `cd apps/gate_server && mix test test/gate_server/codec_test.exs --no-start`
Expected: PASS

- [ ] **Step 5：提交**

```bash
git add apps/gate_server/lib/gate_server/codec.ex apps/gate_server/test/gate_server/codec_test.exs
git commit -m "feat(codec): movement input carries schema_version + length guard (pillar 1.1)"
```

---

### Task 3：PlayerMove `0x83` encode 加 schema_version + server_send_ms（两条路径）

**Files:**
- Modify: `apps/gate_server/lib/gate_server/codec.ex:507-528`
- Test: `apps/gate_server/test/gate_server/codec_test.exs`

- [ ] **Step 1：改测试（test-first）**

替换 `describe "encode broadcast messages"` 中两个 `player_move` 用例（新 tuple 多一个 `server_send_ms` 字段，紧随 `server_tick`）：

```elixir
    test "encodes player_move (compact, schema v1 + server_send_ms)" do
      {:ok, bin} =
        Codec.encode(
          {:player_move, 55, 9, 1_700_000_000_123, {1.0, 2.0, 3.0}, {4.0, 5.0, 6.0},
           {0.1, 0.2, 0.3}, :airborne}
        )

      assert <<0x83, 1, 55::64-big, 9::32-big, 1_700_000_000_123::64-big, 1.0::float-64-big,
               2.0::float-64-big, 3.0::float-64-big, 4.0::float-64-big, 5.0::float-64-big,
               6.0::float-64-big, 0.1::float-64-big, 0.2::float-64-big, 0.3::float-64-big,
               1::8>> == bin
    end

    test "encodes player_move with AOI priority metadata (schema v1 + server_send_ms)" do
      {:ok, bin} =
        Codec.encode(
          {:player_move, 55, 9, 1_700_000_000_123, {1.0, 2.0, 3.0}, {4.0, 5.0, 6.0},
           {0.1, 0.2, 0.3}, :grounded, :medium, 0.75, 125.5, 2}
        )

      assert <<0x83, 1, 55::64-big, 9::32-big, 1_700_000_000_123::64-big, 1.0::float-64-big,
               2.0::float-64-big, 3.0::float-64-big, 4.0::float-64-big, 5.0::float-64-big,
               6.0::float-64-big, 0.1::float-64-big, 0.2::float-64-big, 0.3::float-64-big, 0::8,
               1::8, 0.75::float-32-big, 125.5::float-32-big, 2::16-big>> == bin
    end
```

- [ ] **Step 2：运行测试，确认失败**

Run: `cd apps/gate_server && mix test test/gate_server/codec_test.exs --no-start`
Expected: FAIL

- [ ] **Step 3：改实现**

替换 `codec.ex:507-528` 的两个 `player_move` encode 子句（tuple 在 `server_tick` 后插入 `server_send_ms`，wire 在 opcode 后插 `@movement_wire_schema`、在 `server_tick` 后插 `server_send_ms`）：

```elixir
  # ── Broadcast: player move snapshot (schema v1 + server_send_ms) ──
  def encode(
        {:player_move, cid, server_tick, server_send_ms, {x, y, z}, {vx, vy, vz}, {ax, ay, az},
         movement_mode, priority_band, priority_score, observer_distance, delivery_interval}
      )
      when is_integer(server_send_ms) and is_integer(delivery_interval) and delivery_interval > 0 do
    {:ok,
     <<@msg_player_move, @movement_wire_schema, cid::64-big, server_tick::32-big,
       server_send_ms::64-big, x::float-64-big, y::float-64-big, z::float-64-big,
       vx::float-64-big, vy::float-64-big, vz::float-64-big, ax::float-64-big, ay::float-64-big,
       az::float-64-big, encode_movement_mode(movement_mode), encode_priority_band(priority_band)::8,
       priority_score * 1.0::float-32-big, observer_distance * 1.0::float-32-big,
       delivery_interval::16-big>>}
  end

  def encode(
        {:player_move, cid, server_tick, server_send_ms, {x, y, z}, {vx, vy, vz}, {ax, ay, az},
         movement_mode}
      )
      when is_integer(server_send_ms) do
    {:ok,
     <<@msg_player_move, @movement_wire_schema, cid::64-big, server_tick::32-big,
       server_send_ms::64-big, x::float-64-big, y::float-64-big, z::float-64-big,
       vx::float-64-big, vy::float-64-big, vz::float-64-big, ax::float-64-big, ay::float-64-big,
       az::float-64-big, encode_movement_mode(movement_mode)>>}
  end
```

- [ ] **Step 4：运行测试，确认通过**

Run: `cd apps/gate_server && mix test test/gate_server/codec_test.exs --no-start`
Expected: PASS

- [ ] **Step 5：提交**

```bash
git add apps/gate_server/lib/gate_server/codec.ex apps/gate_server/test/gate_server/codec_test.exs
git commit -m "feat(codec): player_move carries schema_version + server_send_ms (pillar 1.1)"
```

---

### Task 4：MovementAck `0x8b` encode 加 schema_version + server_send_ms

**Files:**
- Modify: `apps/gate_server/lib/gate_server/codec.ex:479-495`
- Test: `apps/gate_server/test/gate_server/codec_test.exs`

- [ ] **Step 1：改测试（test-first）**

替换 `describe "encode movement_ack"` 用例（tuple 在 `auth_tick` 后插 `server_send_ms`）：

```elixir
  describe "encode movement_ack" do
    test "encodes movement ack with schema_version + server_send_ms + ground_z" do
      {:ok, bin} =
        Codec.encode(
          {:movement_ack, 10, 77, 1_700_000_000_123, 42, {1.5, 2.5, 3.5}, {4.5, 5.5, 6.5},
           {0.1, 0.2, 0.3}, :grounded, 3, 100, 3.5}
        )

      assert <<0x8B, 1, 10::32-big, 77::32-big, 1_700_000_000_123::64-big, 42::64-big,
               1.5::float-64-big, 2.5::float-64-big, 3.5::float-64-big, 4.5::float-64-big,
               5.5::float-64-big, 6.5::float-64-big, 0.1::float-64-big, 0.2::float-64-big,
               0.3::float-64-big, 0::8, 3::32-big, 100::16-big, 3.5::float-64-big>> == bin
    end
  end
```

- [ ] **Step 2：运行测试，确认失败**

Run: `cd apps/gate_server && mix test test/gate_server/codec_test.exs --no-start`
Expected: FAIL

- [ ] **Step 3：改实现**

替换 `codec.ex:479-495` 的 movement_ack encode（tuple 在 `auth_tick` 后插 `server_send_ms`；wire 在 opcode 后插 schema、在 `auth_tick` 后插 `server_send_ms`）：

```elixir
  # ── Movement ack (schema v1 + server_send_ms) ──
  # server_send_ms: wall-clock 发送时刻（ms），客户端据此对齐时间轴（pillar 1.3 消费）。
  # 末尾 fixed_dt_ms (B-M2) 与 ground_z (Phase A1-4) 保留。
  def encode(
        {:movement_ack, ack_seq, auth_tick, server_send_ms, cid, {px, py, pz}, {vx, vy, vz},
         {ax, ay, az}, movement_mode, correction_flags, fixed_dt_ms, ground_z}
      )
      when is_integer(server_send_ms) and is_integer(fixed_dt_ms) and fixed_dt_ms > 0 and
             is_float(ground_z) do
    {:ok,
     <<@msg_movement_ack, @movement_wire_schema, ack_seq::32-big, auth_tick::32-big,
       server_send_ms::64-big, cid::64-big, px::float-64-big, py::float-64-big, pz::float-64-big,
       vx::float-64-big, vy::float-64-big, vz::float-64-big, ax::float-64-big, ay::float-64-big,
       az::float-64-big, encode_movement_mode(movement_mode), correction_flags::32-big,
       fixed_dt_ms::16-big, ground_z::float-64-big>>}
  end
```

- [ ] **Step 4：运行测试，确认通过**

Run: `cd apps/gate_server && mix test test/gate_server/codec_test.exs --no-start`
Expected: PASS

- [ ] **Step 5：提交**

```bash
git add apps/gate_server/lib/gate_server/codec.ex apps/gate_server/test/gate_server/codec_test.exs
git commit -m "feat(codec): movement_ack carries schema_version + server_send_ms (pillar 1.1)"
```

---

### Task 5：EnterSceneResult `0x84` encode 加 protocol_version

**Files:**
- Modify: `apps/gate_server/lib/gate_server/codec.ex:468-473`
- Test: `apps/gate_server/test/gate_server/codec_test.exs`

- [ ] **Step 1：加测试（test-first）**

在 `codec_test.exs` 新增：

```elixir
  describe "encode enter_scene_result" do
    test "ok frame carries protocol_version trailer" do
      {:ok, bin} = Codec.encode({:enter_scene_result, :ok, 12, {10.0, 20.0, 30.0}, 1})

      assert <<0x84, 12::64-big, 0x00, 10.0::float-64-big, 20.0::float-64-big, 30.0::float-64-big,
               1::32-big, 1::16-big>> == bin
    end
  end
```

- [ ] **Step 2：运行测试，确认失败**

Run: `cd apps/gate_server && mix test test/gate_server/codec_test.exs --no-start`
Expected: FAIL

- [ ] **Step 3：改实现**

替换 `codec.ex:468-473`：

```elixir
  def encode({:enter_scene_result, :ok, packet_id, {x, y, z}, expected_seq})
      when is_integer(expected_seq) and expected_seq >= 0 do
    {:ok,
     <<@msg_enter_scene_result, packet_id::64-big, @status_ok, x::float-64-big, y::float-64-big,
       z::float-64-big, expected_seq::32-big, @protocol_version::16-big>>}
  end
```

- [ ] **Step 4：运行测试，确认通过**

Run: `cd apps/gate_server && mix test test/gate_server/codec_test.exs --no-start`
Expected: PASS

- [ ] **Step 5：提交**

```bash
git add apps/gate_server/lib/gate_server/codec.ex apps/gate_server/test/gate_server/codec_test.exs
git commit -m "feat(codec): enter_scene_result carries protocol_version (pillar 1.1)"
```

---

## Phase 2：服务端注入 server_send_ms（tcp / udp / ws 三发送端）

> **实测修正（2026-05-28）**：`movement_ack`/`player_move` 实际有**三个平行发送端**——`tcp_connection.ex`、`udp_acceptor.ex`（UDP 直回 ack）、`ws_connection.ex`（WebSocket）。原 plan 只列了 tcp_connection，导致 Phase 1 改完 codec 后全量 suite 留下 23 个失败（udp/ws 发送端未同步 + 多个测试 fixture 断言旧 layout）。**三端必须同步注入**（udp 只有 movement_ack、无 player_move），且验证**必须跑全量 `mix test --no-start`**，不能只跑单个 codec 测试文件。详见 memory `ex-mmo-three-parallel-send-paths`。

### Task 6：player_move / movement_ack 发送处注入 server_send_ms（三发送端）

**Files:**
- Modify: `apps/gate_server/lib/gate_server/worker/tcp_connection.ex:193-211`（movement_ack handle_cast）
- Modify: `apps/gate_server/lib/gate_server/worker/tcp_connection.ex:3071-3082+`（`player_move_message/1` → `/2`）
- Modify: `apps/gate_server/lib/gate_server/worker/tcp_connection.ex:154-190`（player_move handle_cast 传时间）
- Test: `apps/gate_server/test/gate_server/tcp_connection_protocol_test.exs`

- [ ] **Step 1：改 e2e 测试（test-first）**

更新 `tcp_connection_protocol_test.exs` 中 movement ack 断言为新 layout（含 schema + server_send_ms）。把 §506-528 用例的 ack 断言改为：

```elixir
    assert {:ok,
            <<0x8B, 1, 73::32-big, _auth_tick::32-big, server_send_ms::64-big, 42::64-big,
              8.0::float-64-big, 9.0::float-64-big, 10.0::float-64-big, _rest::binary>>} =
             :gen_tcp.recv(client, 0, 500)

    assert server_send_ms > 0
```

- [ ] **Step 2：运行测试，确认失败**

Run: `cd apps/gate_server && mix test test/gate_server/tcp_connection_protocol_test.exs --no-start`
Expected: FAIL（旧 message tuple 无 server_send_ms，encode 不匹配）

- [ ] **Step 3：改 movement_ack handle_cast（tcp_connection.ex:193-211）**

把 message tuple 构造改为在发送瞬间生成 server_send_ms：

```elixir
  @impl true
  def handle_cast({:movement_ack, ack}, %{socket: socket} = state) do
    {udp_peer, state} = resolve_udp_peer(state)

    GateServer.CliObserve.emit("movement_ack_push", fn ->
      %{
        connection_pid: self(),
        ack_seq: ack.ack_seq,
        auth_tick: ack.auth_tick,
        transport: if(udp_peer, do: :udp, else: :tcp)
      }
    end)

    server_send_ms = :os.system_time(:millisecond)

    message =
      {:movement_ack, ack.ack_seq, ack.auth_tick, server_send_ms, ack.cid, ack.position,
       ack.velocity, ack.acceleration, ack.movement_mode, ack.correction_flags, ack.fixed_dt_ms,
       ack.ground_z}

    if udp_peer do
      GateServer.UdpAcceptor.send_to_peer(udp_peer, message)
    else
      send_encoded(socket, message)
    end

    {:noreply, state}
  end
```

> 注：若原 §209-211 的 else 分支用 `send_encoded(socket, message)` 之外的写法，保持原 send 写法、只改 message tuple。

- [ ] **Step 4：改 player_move_message 为 /2（tcp_connection.ex:3071+）**

把 `player_move_message/1` 改为 `player_move_message/2`（第二参 `server_send_ms`），两个子句都在 tuple 的 `server_tick` 后插入它：

```elixir
  defp player_move_message(
         %RemoteSnapshot{
           priority_band: nil,
           priority_score: nil,
           observer_distance: nil,
           delivery_interval: nil
         } = snapshot,
         server_send_ms
       ) do
    {:player_move, snapshot.cid, snapshot.server_tick, server_send_ms, snapshot.position,
     snapshot.velocity, snapshot.acceleration, snapshot.movement_mode}
  end

  defp player_move_message(%RemoteSnapshot{} = snapshot, server_send_ms) do
    {:player_move, snapshot.cid, snapshot.server_tick, server_send_ms, snapshot.position,
     snapshot.velocity, snapshot.acceleration, snapshot.movement_mode, snapshot.priority_band,
     snapshot.priority_score, snapshot.observer_distance, snapshot.delivery_interval}
  end
```

> 定位第二个子句：grep `defp player_move_message(%RemoteSnapshot{} = snapshot)`（带优先级的子句，紧跟无优先级子句之后）。

- [ ] **Step 5：改 player_move handle_cast 两处调用点（tcp_connection.ex:172、186）**

在 handle_cast({:player_move, snapshot}) 顶部生成时间，并把两处 `player_move_message(snapshot)` 改为 `player_move_message(snapshot, server_send_ms)`：

```elixir
  @impl true
  def handle_cast({:player_move, snapshot}, %{socket: socket} = state) do
    snapshot = normalize_remote_snapshot(snapshot)
    {udp_peer, state} = resolve_udp_peer(state)
    server_send_ms = :os.system_time(:millisecond)

    if udp_peer do
      # ...（保留原 observe emit 不变）...
      GateServer.UdpAcceptor.send_to_peer(udp_peer, player_move_message(snapshot, server_send_ms))
    else
      # ...（保留原 observe emit 不变）...
      send_encoded(socket, player_move_message(snapshot, server_send_ms))
    end

    {:noreply, state}
  end
```

- [ ] **Step 6：运行测试，确认通过**

Run: `cd apps/gate_server && mix test test/gate_server/tcp_connection_protocol_test.exs --no-start`
Expected: PASS

- [ ] **Step 7：跑全 gate_server 测试回归**

Run: `cd apps/gate_server && mix test --no-start`
Expected: PASS（全绿）

- [ ] **Step 8：提交**

```bash
git add apps/gate_server/lib/gate_server/worker/tcp_connection.ex apps/gate_server/test/gate_server/tcp_connection_protocol_test.exs
git commit -m "feat(gate): inject server_send_ms at player_move/movement_ack send site (pillar 1.1)"
```

---

## Phase 3：客户端 codec（TypeScript）

### Task 7：客户端协议版本常量

**Files:**
- Create: `clients/web_client/src/infrastructure/net/protocolVersion.ts`

- [ ] **Step 1：新建常量文件**

```typescript
// Protocol versioning (Pillar 1.1). Must match
// apps/gate_server/lib/gate_server/codec.ex @protocol_version / @movement_wire_schema.
export const PROTOCOL_VERSION = 1;
export const MOVEMENT_WIRE_SCHEMA = 1;
```

- [ ] **Step 2：提交**

```bash
git add clients/web_client/src/infrastructure/net/protocolVersion.ts
git commit -m "feat(web): add protocol version constants (pillar 1.1)"
```

---

### Task 8：encodeMovementInput 加 schema_version

**Files:**
- Modify: `clients/web_client/src/infrastructure/net/gateProtocol.ts:157-184`
- Test: `clients/web_client/src/infrastructure/net/gateProtocol.test.ts`

- [ ] **Step 1：加/改测试（test-first）**

在 `gateProtocol.test.ts` 加：

```typescript
import { encodeMovementInput } from "./gateProtocol";
import { MOVEMENT_WIRE_SCHEMA } from "./protocolVersion";

it("encodeMovementInput emits schema_version byte after opcode (26 bytes)", () => {
  const bytes = encodeMovementInput({
    seq: 55,
    clientTick: 1000,
    dtMs: 100,
    inputDir: { x: 1.0, y: 0.5 },
    speedScale: 1.25,
    movementFlags: 3,
  });
  expect(bytes.byteLength).toBe(26);
  const view = new DataView(bytes.buffer);
  expect(view.getUint8(0)).toBe(0x01);
  expect(view.getUint8(1)).toBe(MOVEMENT_WIRE_SCHEMA);
  expect(view.getUint32(2, false)).toBe(55);
});
```

- [ ] **Step 2：运行测试，确认失败**

Run: `cd clients/web_client && npm test -- gateProtocol`
Expected: FAIL（旧 25 字节、无 schema 字节）

- [ ] **Step 3：改实现（gateProtocol.ts:157-184）**

```typescript
import { MOVEMENT_WIRE_SCHEMA } from "./protocolVersion";

export function encodeMovementInput(frame: {
  seq: number;
  clientTick: number;
  dtMs: number;
  inputDir: { x: number; y: number };
  speedScale: number;
  movementFlags: number;
}): Uint8Array {
  const buffer = new ArrayBuffer(1 + 1 + 4 + 4 + 2 + 4 + 4 + 4 + 2);
  const view = new DataView(buffer);
  let offset = 0;
  view.setUint8(offset, 0x01);
  offset += 1;
  view.setUint8(offset, MOVEMENT_WIRE_SCHEMA);
  offset += 1;
  view.setUint32(offset, frame.seq, false);
  offset += 4;
  view.setUint32(offset, frame.clientTick, false);
  offset += 4;
  view.setUint16(offset, frame.dtMs, false);
  offset += 2;
  view.setFloat32(offset, frame.inputDir.x, false);
  offset += 4;
  view.setFloat32(offset, frame.inputDir.y, false);
  offset += 4;
  view.setFloat32(offset, frame.speedScale, false);
  offset += 4;
  view.setUint16(offset, frame.movementFlags, false);
  return new Uint8Array(buffer);
}
```

- [ ] **Step 4：运行测试，确认通过**

Run: `cd clients/web_client && npm test -- gateProtocol`
Expected: PASS

- [ ] **Step 5：提交**

```bash
git add clients/web_client/src/infrastructure/net/gateProtocol.ts clients/web_client/src/infrastructure/net/gateProtocol.test.ts
git commit -m "feat(web): encodeMovementInput emits schema_version (pillar 1.1)"
```

---

### Task 9：decode player_move `0x83` 新 layout（schema + server_send_ms）

**Files:**
- Modify: `clients/web_client/src/infrastructure/net/gateProtocol.ts:264-277`（0x83 分支）
- Modify: `clients/web_client/src/infrastructure/net/gateProtocol.ts`（`decodeAoiPriority` 偏移、`ServerGateMessage` / snapshot 类型加 `serverSendMs`）
- Test: `clients/web_client/src/infrastructure/net/gateProtocol.test.ts`

- [ ] **Step 1：加测试（test-first）**

```typescript
it("decodes player_move with schema_version + server_send_ms (compact, 95 bytes)", () => {
  const buf = new ArrayBuffer(95);
  const v = new DataView(buf);
  v.setUint8(0, 0x83);
  v.setUint8(1, 1); // schema
  v.setBigUint64(2, 55n, false); // cid
  v.setUint32(10, 9, false); // server_tick
  v.setBigUint64(14, 1_700_000_000_123n, false); // server_send_ms
  v.setFloat64(22, 1.0, false); // x
  v.setFloat64(30, 2.0, false); // y (server) -> z (browser)
  v.setFloat64(38, 3.0, false); // z (server) -> y (browser)
  v.setFloat64(46, 0, false);
  v.setFloat64(54, 0, false);
  v.setFloat64(62, 0, false);
  v.setFloat64(70, 0, false);
  v.setFloat64(78, 0, false);
  v.setFloat64(86, 0, false);
  v.setUint8(94, 1); // movement_mode airborne

  const msg = decodeServerMessage(buf);
  expect(msg?.type).toBe("player_move");
  if (msg?.type === "player_move") {
    expect(msg.snapshot.cid).toBe(55);
    expect(msg.snapshot.serverTick).toBe(9);
    expect(msg.snapshot.serverSendMs).toBe(1_700_000_000_123);
    expect(msg.snapshot.position.x).toBeCloseTo(1.0);
    expect(msg.snapshot.position.y).toBeCloseTo(3.0); // server z -> browser y
    expect(msg.snapshot.position.z).toBeCloseTo(2.0); // server y -> browser z
  }
});
```

- [ ] **Step 2：运行测试，确认失败**

Run: `cd clients/web_client && npm test -- gateProtocol`
Expected: FAIL

- [ ] **Step 3：改实现**

3a. 在 `src/domain/movement/types.ts` 的 `RemoteMoveSnapshot` 类型加 `serverSendMs: number;`（grep `serverTick` 定位），**并同步更新同文件的 `cloneRemoteMoveSnapshot` 复制该字段**（否则 `pushSnapshot` 存快照时丢失 `serverSendMs`，破坏 1.3 时间轴消费）。加字段后 `npm run typecheck` 会暴露所有构造 `RemoteMoveSnapshot` 的地方——逐一补 `serverSendMs`（测试 fixture 用 `0` 即可）。

3b. 替换 `gateProtocol.ts:264-277` 的 0x83 分支（新偏移）：

```typescript
    case 0x83:
      if (!hasBytes(view, 95)) return null;
      if (view.getUint8(1) !== MOVEMENT_WIRE_SCHEMA) return null;
      return {
        type: "player_move",
        snapshot: {
          cid: readI64(view, 2),
          serverTick: view.getUint32(10, false),
          serverSendMs: Number(view.getBigUint64(14, false)),
          position: readServerVec3AsBrowserVec3(view, 22),
          velocity: readServerVec3AsBrowserVec3(view, 46),
          acceleration: readServerVec3AsBrowserVec3(view, 70),
          movementMode: decodeMovementMode(view.getUint8(94)),
          ...decodeAoiPriority(view, 95),
        },
      };
```

3c. 确认 `decodeAoiPriority(view, 95)` 内部偏移随基址 95 起算（grep `function decodeAoiPriority`，确保它用传入的 offset 读 band/score/dist/interval，且长度守卫 `byteLength >= offset + 11`）。若它硬编码了旧基址 86，改为接收的 `offset`。

- [ ] **Step 4：运行测试，确认通过**

Run: `cd clients/web_client && npm test -- gateProtocol`
Expected: PASS

- [ ] **Step 5：提交**

```bash
git add clients/web_client/src/infrastructure/net/gateProtocol.ts clients/web_client/src/infrastructure/net/gateProtocol.test.ts clients/web_client/src/domain/movement/types.ts
git commit -m "feat(web): decode player_move schema_version + server_send_ms (pillar 1.1)"
```

---

### Task 10：decode movement_ack `0x8b` 新 layout

**Files:**
- Modify: `clients/web_client/src/infrastructure/net/gateProtocol.ts:232-263`（0x8b 分支）+ ack 类型加 `serverSendMs`
- Test: `clients/web_client/src/infrastructure/net/gateProtocol.test.ts`

- [ ] **Step 1：加测试（test-first）**

```typescript
it("decodes movement_ack with schema_version + server_send_ms (113 bytes)", () => {
  const buf = new ArrayBuffer(113);
  const v = new DataView(buf);
  v.setUint8(0, 0x8b);
  v.setUint8(1, 1); // schema
  v.setUint32(2, 10, false); // ack_seq
  v.setUint32(6, 77, false); // auth_tick
  v.setBigUint64(10, 1_700_000_000_123n, false); // server_send_ms
  v.setBigUint64(18, 42n, false); // cid
  v.setFloat64(26, 1.5, false); // px
  v.setFloat64(34, 2.5, false); // py
  v.setFloat64(42, 3.5, false); // pz
  // vel(50..73), accel(74..97) leave 0
  v.setUint8(98, 0); // movement_mode grounded
  v.setUint32(99, 3, false); // correction_flags
  v.setUint16(103, 100, false); // fixed_dt_ms
  v.setFloat64(105, 3.5, false); // ground_z

  const msg = decodeServerMessage(buf);
  expect(msg?.type).toBe("movement_ack");
  if (msg?.type === "movement_ack") {
    expect(msg.ack.ackSeq).toBe(10);
    expect(msg.ack.authTick).toBe(77);
    expect(msg.ack.serverSendMs).toBe(1_700_000_000_123);
    expect(msg.ack.correctionFlags).toBe(3);
    expect(msg.ack.serverFixedDtMs).toBe(100);
    expect(msg.ack.groundY).toBeCloseTo(3.5);
  }
});
```

- [ ] **Step 2：运行测试，确认失败**

Run: `cd clients/web_client && npm test -- gateProtocol`
Expected: FAIL

- [ ] **Step 3：改实现**

3a. ack 类型加 `serverSendMs: number`（grep `authTick` 定位 ack 结构/类型，加字段）。**加字段后 `npm run typecheck` 会暴露所有构造 ack 的地方**（如 `simulatedMovementTransport.ts` 的本地模拟 ack）——逐一补 `serverSendMs`（本地模拟用 `Date.now()`，测试 fixture 用 `0`）。

3b. 替换 `gateProtocol.ts:232-263` 的 0x8b 分支（新偏移，schema@1、server_send_ms@10、cid@18、pos@26、vel@50、accel@74、mode@98、flags@99、fixed_dt@103、ground_z@105）：

```typescript
    case 0x8b:
      if (!hasBytes(view, 113)) return null;
      if (view.getUint8(1) !== MOVEMENT_WIRE_SCHEMA) return null;
      return {
        type: "movement_ack",
        ack: {
          ackSeq: view.getUint32(2, false),
          authTick: view.getUint32(6, false),
          serverSendMs: Number(view.getBigUint64(10, false)),
          position: readServerVec3AsBrowserVec3(view, 26),
          velocity: readServerVec3AsBrowserVec3(view, 50),
          acceleration: readServerVec3AsBrowserVec3(view, 74),
          movementMode: decodeMovementMode(view.getUint8(98)),
          correctionFlags: view.getUint32(99, false),
          serverFixedDtMs: view.getUint16(103, false),
          groundY: view.getFloat64(105, false),
        },
      };
```

- [ ] **Step 4：运行测试，确认通过**

Run: `cd clients/web_client && npm test -- gateProtocol`
Expected: PASS

- [ ] **Step 5：提交**

```bash
git add clients/web_client/src/infrastructure/net/gateProtocol.ts clients/web_client/src/infrastructure/net/gateProtocol.test.ts
git commit -m "feat(web): decode movement_ack schema_version + server_send_ms (pillar 1.1)"
```

---

### Task 11：decode enter_scene_ok 解析 protocol_version + fail-fast 断言

**Files:**
- Modify: `clients/web_client/src/infrastructure/net/gateProtocol.ts:225-242`（0x84 分支，长度 38→40、读 protocol_version）+ `enter_scene_ok` 类型加 `protocolVersion`
- Modify: 调用 enter_scene_ok 的消费处（grep `enter_scene_ok`，多为 `serverMovementTransport.ts`）加版本断言
- Test: `clients/web_client/src/infrastructure/net/gateProtocol.test.ts`

- [ ] **Step 1：加测试（test-first）**

```typescript
it("decodes enter_scene_ok with trailing protocol_version (40 bytes)", () => {
  const buf = new ArrayBuffer(40);
  const v = new DataView(buf);
  v.setUint8(0, 0x84);
  v.setBigUint64(1, 12n, false); // packet_id
  v.setUint8(9, 0x00); // ok
  v.setFloat64(10, 10.0, false); // x
  v.setFloat64(18, 20.0, false); // y(server)
  v.setFloat64(26, 30.0, false); // z(server)
  v.setUint32(34, 1, false); // expected_seq
  v.setUint16(38, 1, false); // protocol_version

  const msg = decodeServerMessage(buf);
  expect(msg?.type).toBe("enter_scene_ok");
  if (msg?.type === "enter_scene_ok") {
    expect(msg.expectedSeq).toBe(1);
    expect(msg.protocolVersion).toBe(1);
  }
});
```

- [ ] **Step 2：运行测试，确认失败**

Run: `cd clients/web_client && npm test -- gateProtocol`
Expected: FAIL

- [ ] **Step 3：改实现**

3a. `enter_scene_ok` 类型加 `protocolVersion: number`。

3b. 替换 `gateProtocol.ts:225-242` 的 0x84 ok 分支（长度 40、读 offset 38）：

```typescript
    case 0x84: {
      if (!hasBytes(view, 10)) return null;
      const requestId = readU64(view, 1);
      const ok = view.getUint8(9) === 0;
      if (!ok) {
        return { type: "enter_scene_error", requestId };
      }
      if (!hasBytes(view, 40)) return null;
      // packet_id(8) + ok(1) + vec3(24) + expected_seq(u32) + protocol_version(u16)
      return {
        type: "enter_scene_ok",
        requestId,
        position: readServerVec3AsBrowserVec3(view, 10),
        expectedSeq: view.getUint32(34, false),
        protocolVersion: view.getUint16(38, false),
      };
    }
```

- [ ] **Step 4：运行测试，确认通过**

Run: `cd clients/web_client && npm test -- gateProtocol`
Expected: PASS

- [ ] **Step 5：加 fail-fast 断言**

grep `enter_scene_ok` 在 `serverMovementTransport.ts` 的处理处，加：

```typescript
import { PROTOCOL_VERSION } from "./protocolVersion";
// ...在处理 enter_scene_ok 的分支内：
if (message.protocolVersion !== PROTOCOL_VERSION) {
  console.error(
    `[gate] protocol_version mismatch: server=${message.protocolVersion} client=${PROTOCOL_VERSION}`,
  );
  this.disconnect?.(); // 用现有断开方法；若无则 this.socket?.close()
  return;
}
```

> 定位现有断开方法：grep `disconnect|socket?.close|this.socket.close` in serverMovementTransport.ts，用既有的清理路径。

- [ ] **Step 6：运行测试 + typecheck**

Run: `cd clients/web_client && npm test -- gateProtocol && npm run typecheck`
Expected: PASS

- [ ] **Step 7：提交**

```bash
git add clients/web_client/src/infrastructure/net/gateProtocol.ts clients/web_client/src/infrastructure/net/gateProtocol.test.ts clients/web_client/src/infrastructure/net/serverMovementTransport.ts
git commit -m "feat(web): parse protocol_version + fail-fast on mismatch (pillar 1.1)"
```

---

## Phase 4：回归与真相源回写

### Task 12：双端全量回归 + e2e 冒烟

**Files:** 无代码改动（验证）

- [ ] **Step 1：服务端全量**

Run: `cd apps/gate_server && mix test --no-start`
Expected: PASS

- [ ] **Step 2：客户端全量 + typecheck**

Run: `cd clients/web_client && npm test && npm run typecheck`
Expected: PASS

- [ ] **Step 3：e2e 浏览器移动冒烟（双端串联，验证新 wire 通）**

Run: `cd clients/web_client && npm run smoke:browser-movement`
Expected: 双客户端连接、移动、ack 正常；observe 无 decode 错误。产物在 `.demo/observe/`。

> 若 e2e 因后端启动环境（Windows VsDevCmd / 端口）失败，记录失败原因，至少保证 Step 1/2 全绿，并在 PR 描述里标注 e2e 手动验证状态。

### Task 13：真相源回写

**Files:**
- Modify: `docs/2026-04-10-线协议规范.md`（Movement/PlayerMove/MovementAck/EnterSceneResult 新 layout + schema_version/protocol_version/server_send_ms 说明）
- Modify: `docs/2026-05-28-移动同步现状调研与重构方向.md`（§6 标注支柱 1.1 wire 升级"已实现"，指向本 plan）

- [ ] **Step 1：更新线协议规范**

按本 plan 顶部"目标 wire layout"逐消息更新字节表；标注 `PROTOCOL_VERSION=1`、`MOVEMENT_WIRE_SCHEMA=1`、`server_send_ms` 语义（wall-clock 发送时刻，pillar 1.3 客户端消费）。

- [ ] **Step 2：提交**

```bash
git add docs/2026-04-10-线协议规范.md docs/2026-05-28-移动同步现状调研与重构方向.md
git commit -m "docs: record pillar 1.1 wire layout in protocol spec + research doc"
```

---

## 完成定义（Plan 1.1 DoD）
1. 五条消息（Movement/PlayerMove/MovementAck/EnterSceneResult + 常量）双端按新 layout 编解码，单元测试全绿。
2. `server_send_ms` 在发送瞬间注入；`schema_version` 逐帧守卫 + decode 长度守卫生效。
3. 握手 `protocol_version` 双端断言，不一致 fail-fast。
4. 服务端 `mix test` + 客户端 `npm test`/`typecheck` 全绿；e2e 冒烟通过（或记录环境限制）。
5. 线协议规范 + 研究文档已回写。
6. **无迁移债**：旧 layout decode 路径、旧 tuple 形状已删除，无双 schema 并存。
