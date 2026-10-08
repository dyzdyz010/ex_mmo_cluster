defmodule GateServer.NpcWorldRequestTest do
  @moduledoc """
  只测试：NPC 规范命令与玩家线帧是同一个世界意图。冻结样本是按 `MmoContracts.Voxel.Codec.decode/1` 的字节布局
  （大端；rid u64、client_intent_seq u32、scene u64 之后各 opcode 的字段）手写的十六进制帧，含负坐标与非零 owner；
  期望不由被测函数生成：`Codec.decode(帧)` 与 `WorldRequest.build(同语义命令)` 必须全等，且 `Codec.intent?/1` 为真。
  浮点按 IEEE 754 双精度手写：0.6 = 3FE3333333333333、-0.8 = BFE999999999999A、±1.0 = 3FF… / BFF…。
  """
  use ExUnit.Case, async: true
  alias GateServer.Npc.WorldRequest
  alias MmoContracts.Voxel.Codec

  # rid = client_intent_seq = 5，logical_scene_id = 1。
  @context %{seq: 5, scene_id: 1, eye: nil}
  @head "0000000000000005" <> "00000005" <> "0000000000000001"
  @zero64 "0000000000000000"
  @one "3FF0000000000000"
  @def_ab String.duplicate("AB", 32)
  @def_cd String.duplicate("CD", 32)
  # 0x82 的程序字节：Test-only 魔法目录 19c513f9… 的预设 ignite_near 原样；目录 digest 取 32 字节 EE。
  @ignite ~s({"v":1,"target":{"kind":"aim"},"emit":"at_target","steps":[{"sym":"act.heat","args":{"energy_j":400000,"power_w":200000}}]})
  @digest :binary.copy(<<0xEE>>, 32)

  defp frame(hex), do: Base.decode16!(String.replace(hex, " ", ""))

  # 0x82 action 之后的字段：digest EE…、方向 (0.6, 0, -0.8)、g2 构件 micro (-17, 513, 83)、incarnation 12、owner {12, 1}、
  # material 11、granularity 2、拟态 id {0, 0}；程序字段另接 u16 长度 + 字节。
  @spell_body String.duplicate("EE", 32) <> "3FE3333333333333" <> @zero64 <> "BFE999999999999A" <>
                "FFFFFFFFFFFFFFEF" <> "0000000000000201" <> "0000000000000053" <>
                "000000000000000C" <> "000000000000000C" <> "00000001" <> "000B" <> "02" <>
                @zero64 <> "00000000"

  defp program_tail, do: <<byte_size(@ignite)::16, @ignite::binary>>

  defp same(hex, command, context \\ @context) do
    assert {:ok, decoded} = Codec.decode(frame(hex))
    assert Codec.intent?(decoded)
    assert WorldRequest.build(command, context) == decoded
  end

  describe "0x7D 工具意图" do
    test "a0 探测，无目标：方向 (0.6, 0, -0.8)，身份字段全零" do
      same(
        "7D" <> @head <> "00" <> "3FE3333333333333" <> @zero64 <> "BFE999999999999A" <>
          @zero64 <> @zero64 <> @zero64 <> @zero64 <> @zero64 <> "00000000" <> "0000" <> "0001" <> "00",
        %{verb: :probe_toward, direction: {0.6, 0.0, -0.8}, tool_id: 1}
      )
    end

    test "a1 地形格 g0（负 micro）与附件 g3（非零 owner）按探测返回的身份寻址" do
      same(
        "7D" <> @head <> "01" <> @one <> @zero64 <> @zero64 <>
          "FFFFFFFFFFFFFFE8" <> "00000000000001F8" <> "0000000000000050" <>
          "0000000000000009" <> @zero64 <> "00000000" <> "000B" <> "0001" <> "00",
        %{
          verb: :use_tool,
          direction: {1.0, 0.0, 0.0},
          tool_id: 1,
          target: %{granularity: 0, micro: {-24, 504, 80}, incarnation: 9, owner: {0, 0}, material: 11}
        }
      )

      same(
        "7D" <> @head <> "01" <> @one <> @zero64 <> @zero64 <>
          "FFFFFFFFFFFFFF88" <> "0000000000000200" <> "0000000000000050" <>
          "0000000000000007" <> "0000000000000007" <> "00000004" <> "000B" <> "0002" <> "03",
        %{
          verb: :use_tool,
          direction: {1.0, 0.0, 0.0},
          tool_id: 2,
          target: %{granularity: 3, micro: {-120, 512, 80}, incarnation: 7, owner: {7, 4}, material: 11}
        }
      )
    end

    test "a2 拆解 prefab 构件 g2：owner = 实例 {birth, occurrence}" do
      same(
        "7D" <> @head <> "02" <> @zero64 <> "BFF0000000000000" <> @zero64 <>
          "FFFFFFFFFFFFFFEF" <> "0000000000000201" <> "0000000000000053" <>
          "000000000000000C" <> "000000000000000C" <> "00000001" <> "000B" <> "0001" <> "02",
        %{
          verb: :dismantle,
          direction: {0.0, -1.0, 0.0},
          tool_id: 1,
          target: %{granularity: 2, micro: {-17, 513, 83}, incarnation: 12, owner: {12, 1}, material: 11}
        }
      )
    end

    test "g5 人物：a0 探测 owner {cid, 0}；a1 带目标生命代次，方向可取自句柄" do
      same(
        "7D" <> @head <> "00" <> @one <> @zero64 <> @zero64 <>
          @zero64 <> @zero64 <> @zero64 <> @zero64 <> "000000000000238E" <> "00000000" <> "0000" <> "0001" <> "05",
        %{verb: :probe_toward, direction: {1.0, 0.0, 0.0}, tool_id: 1, target: %{granularity: 5, owner: {9102, 0}}}
      )

      a1 =
        "7D" <> @head <> "01" <> @one <> @zero64 <> @zero64 <>
          @zero64 <> @zero64 <> @zero64 <> "000000000000002A" <> "000000000000238E" <> "00000000" <> "0000" <> "0001" <> "05"

      handle = %{granularity: 5, owner: {9102, 0}, incarnation: 42, micro: {0, 0, 0}, material: 0}
      same(a1, %{verb: :use_tool, direction: {1.0, 0.0, 0.0}, tool_id: 1, target: handle})

      # 不给方向：g5 句柄的 direction（探测时的方向）就是瞄准方向，眼点不参与。
      same(a1, %{verb: :use_tool, tool_id: 1, target: Map.put(handle, :direction, {1.0, 0.0, 0.0})}, %{
        @context
        | eye: {0.0, 0.0, 0.0}
      })
    end
  end

  test "0x7F 生产 a1–a5：放置 / 盛取 / 倾倒带负坐标，合成与进食填零坐标与 1 号工具" do
    for {action, verb, coord, tool, material} <- [
          {"01", :place, "FFFFFFFD" <> "00000040" <> "0000000A", "0001", "000B"},
          {"02", :scoop, "FFFFFFFD" <> "00000040" <> "0000000A", "0003", "0015"},
          {"03", :pour, "FFFFFFFD" <> "00000040" <> "0000000A", "0004", "0015"}
        ] do
      same(
        "7F" <> @head <> action <> coord <> tool <> material,
        %{
          verb: verb,
          coord: {-3, 64, 10},
          tool_id: String.to_integer(tool, 16),
          material: String.to_integer(material, 16)
        }
      )
    end

    same("7F" <> @head <> "04" <> "000000000000000000000000" <> "0001" <> "0013", %{verb: :craft, material: 19})
    same("7F" <> @head <> "05" <> "000000000000000000000000" <> "0001" <> "0024", %{verb: :eat, material: 36})
  end

  test "0x81 附件 a0 贴 / a1 拆：anchor 是 micro 坐标，拆除带附件 id" do
    body = "00" <> "01" <> "01" <> "FFFFFFFFFFFFFF88" <> "0000000000000200" <> "0000000000000050"
    attach = %{verb: :attach, kind: 0, axis: 1, size: 1, anchor: {-120, 512, 80}, material: 11, tool_id: 1}

    same("81" <> @head <> "00" <> body <> @zero64 <> "000B" <> "0001", attach)

    same(
      "81" <> @head <> "01" <> body <> "0000000000000007" <> "000B" <> "0001",
      Map.merge(attach, %{verb: :detach, attachment_id: 7})
    )
  end

  test "0x7A / 0x7B / 0x7C prefab 放置、拆除、替换" do
    same(
      "7A" <> @head <> @def_ab <> "FFFFFFFFFFFFFFD0" <> "0000000000000200" <> "0000000000000050" <> "03",
      %{verb: :prefab_place, definition_id: :binary.copy(<<0xAB>>, 32), anchor: {-48, 512, 80}, orientation: 3}
    )

    same("7B" <> @head <> "000000000000000C" <> "00000000", %{verb: :prefab_remove, instance_id: {12, 0}})

    same(
      "7C" <> @head <> "000000000000000C" <> "00000001" <> @def_cd,
      %{verb: :prefab_replace, instance_id: {12, 1}, definition_id: :binary.copy(<<0xCD>>, 32)}
    )
  end

  # I4（设计稿 §7.8）：0x82 的布局 = 公共头、action u8、目录 digest 32B、方向 f64×3、目标 micro i64×3、incarnation u64、
  # owner {birth u64, occurrence u32}、material u16、granularity u8、拟态 id {seq u64, n u32}、程序 u16 长度 + 字节。
  # 目录 digest 在 Body 受理时未知（执行进程投递前经 World.magic_digest/1 填入），build 留 nil，比较时补上 EE…。
  describe "0x82 施法意图" do
    test "a1 施放 g2 构件（负 micro、非零 owner）；a2 取消 = 同一请求换 action 与 request_id，client_intent_seq 不变" do
      assert {:ok, {:voxel_spell_intent, cast} = decoded} =
               Codec.decode(frame("82" <> @head <> "01" <> @spell_body) <> program_tail())

      assert Codec.intent?(decoded)

      command = %{
        verb: :cast_spell,
        program: @ignite,
        direction: {0.6, 0.0, -0.8},
        target: %{
          granularity: 2,
          micro: {-17, 513, 83},
          incarnation: 12,
          owner: {12, 1},
          material: 11
        }
      }

      assert {:voxel_spell_intent, built} = WorldRequest.build(command, @context)
      assert built.catalog_digest == nil
      assert %{built | catalog_digest: @digest} == cast

      # 玩家前摇中再按 M：同一帧（同 digest、目标、程序与 client_intent_seq 5）换 action 2 与新 request_id 6。
      a2 = "82" <> "0000000000000006" <> "00000005" <> "0000000000000001" <> "02" <> @spell_body
      assert {:ok, {:voxel_spell_intent, cancel}} = Codec.decode(frame(a2) <> program_tail())
      assert {:voxel_spell_intent, built_cancel} =
               WorldRequest.cancel(built, %{@context | seq: 6})
      assert %{built_cancel | catalog_digest: @digest} == cancel
    end

    test "不给方向时从眼点瞄准句柄；附件 g3、人物 g5、非二进制程序拼不出（0x82 的 granularity 只有 0..2）" do
      handle = %{granularity: 0, micro: {8, 512, 0}, incarnation: 1, owner: {0, 0}, material: 11}
      command = %{verb: :cast_spell, program: @ignite, target: handle}
      assert WorldRequest.aims?(command)

      # 与 0x7D 同一手算：宏格 (1, 64, 0) 中心 (1.5, 64.5, 0.5)，眼 (0.5, 64.6, 0.5) → (1, −0.1, 0) / √1.01。
      assert {:voxel_spell_intent, %{direction: {dx, dy, dz}, micro: {8, 512, 0}, granularity: 0}} =
               WorldRequest.build(command, %{@context | eye: {0.5, 64.6, 0.5}})

      assert_in_delta dx, 1 / :math.sqrt(1.01), 1.0e-12
      assert_in_delta dy, -0.1 / :math.sqrt(1.01), 1.0e-12
      assert dz == 0.0

      aimed = Map.put(command, :direction, {1.0, 0.0, 0.0})

      for bad <- [
            %{aimed | target: %{handle | granularity: 3}},
            %{aimed | target: %{handle | granularity: 5, owner: {9102, 0}}},
            %{aimed | program: 42},
            %{aimed | target: %{handle | micro: {8.0, 512, 0}}}
          ],
          do: assert(WorldRequest.build(bad, @context) == nil, inspect(bad))
    end
  end

  test "类型或取值不合法的命令拼不出意图（Body 据此回 invalid_command）" do
    for command <- [
          # 线布局不可表达的实例 id：birth −1、occurrence 2³²。
          %{verb: :prefab_remove, instance_id: {-1, 0}},
          %{verb: :prefab_remove, instance_id: {1, 0x1_0000_0000}},
          %{verb: :probe_toward, direction: {"a", 0, 0}, tool_id: 1},
          %{verb: :use_tool, direction: {1.0, 0.0, 0.0}, tool_id: :x},
          %{verb: :prefab_place, definition_id: 42, anchor: {0, 0, 0}, orientation: 0},
          %{verb: :prefab_replace, instance_id: {1, 0}, definition_id: ~c"abc"},
          # 不给方向也没有句柄：无从瞄准。
          %{verb: :use_tool, tool_id: 1},
          # 句柄身份字段不是线帧的整数型（JSON 的 12.0 解成浮点）：交给 World 会在其整数运算里崩溃。
          %{
            verb: :use_tool,
            direction: {1.0, 0.0, 0.0},
            tool_id: 1,
            target: %{granularity: 0, micro: {1.5, 64, 0}}
          },
          %{
            verb: :use_tool,
            direction: {1.0, 0.0, 0.0},
            tool_id: 1,
            target: %{granularity: 5, owner: {7.0, 0}, incarnation: 1}
          },
          %{
            verb: :dismantle,
            direction: {1.0, 0.0, 0.0},
            tool_id: 1,
            target: %{granularity: 2, owner: {12, 1}, incarnation: 1.0}
          }
        ] do
      assert WorldRequest.build(command, @context) == nil, inspect(command)
    end
  end

  test "眼点恰在瞄准点上：没有方向，拼不出意图（Body 回 invalid_command，不在 Body 进程里除以零）" do
    # 宏格 (60, 520, 57) = micro (480, 4160, 456)，中心 (60.5, 520.5, 57.5)：Demo 出生格心站地时的眼点。
    handle = %{granularity: 0, micro: {480, 4160, 456}, incarnation: 0, owner: {0, 0}, material: 11}
    eye = {60.5, 520.5, 57.5}

    assert WorldRequest.aim(eye, handle) == nil

    assert WorldRequest.build(%{verb: :use_tool, tool_id: 1, target: handle}, %{@context | eye: eye}) ==
             nil
  end

  test "瞄准点按粒度：g0 宏格中心、g1 / g2 micro 中心、g3 任意单位方向（手算）" do
    # 宏格 (1, 64, 0) 的中心 (1.5, 64.5, 0.5)；眼 (0.5, 64.6, 0.5) → (1, −0.1, 0) / √1.01。
    {dx, dy, dz} = WorldRequest.aim({0.5, 64.6, 0.5}, %{granularity: 0, micro: {8, 512, 0}})
    assert_in_delta dx, 1 / :math.sqrt(1.01), 1.0e-12
    assert_in_delta dy, -0.1 / :math.sqrt(1.01), 1.0e-12
    assert dz == 0.0

    # micro (13, 517, 2) 的中心 = (13.5, 517.5, 2.5) / 8 = (1.6875, 64.6875, 0.3125)；眼在其 −Z 3 m 处。
    assert WorldRequest.aim({1.6875, 64.6875, -2.6875}, %{granularity: 1, micro: {13, 517, 2}}) ==
             {0.0, 0.0, 1.0}

    assert WorldRequest.aim({9.0, 9.0, 9.0}, %{granularity: 3, micro: {1, 2, 3}}) == {1.0, 0.0, 0.0}

    # 不给方向的 use_tool 用同一瞄准点。
    assert {:voxel_tool_intent, %{direction: {^dx, ^dy, ^dz}}} =
             WorldRequest.build(
               %{verb: :use_tool, tool_id: 1, target: %{granularity: 0, micro: {8, 512, 0}, incarnation: 1, owner: {0, 0}, material: 11}},
               %{@context | eye: {0.5, 64.6, 0.5}}
             )
  end
end
