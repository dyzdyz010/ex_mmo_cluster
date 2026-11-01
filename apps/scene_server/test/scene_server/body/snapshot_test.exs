defmodule SceneServer.Body.SnapshotTest do
  @moduledoc "只测试：身体存档独立小例；不启动 World 或数据库。"
  use ExUnit.Case, async: true
  alias SceneServer.Body
  alias SceneServer.Body.Snapshot

  test "完整身体及待吸收热和分世界游标保留，会话位置和移交状态不进入存档" do
    body = %{
      Body.new()
      | core_k: 300.0,
        protein_g: 31.0,
        weak_s: 72.0,
        daze_s: 11.0,
        status: :dead,
        traumas: %{legs: %{depth: 0.2, protein_g: 3.0, heal_s: 20.0, heal: 0.25}}
    }

    heat = %{q_j: 90.0, tissue_j: 40.0, max_contact_k: 330.0, sole_k: 320.0, immersed: 0.5}

    saved = %{
      body: body,
      body_heat: heat,
      body_exchange_j: 123.0,
      life_generation: 7,
      food_cursors: %{11 => 9, 22 => 3},
      state: :old_position,
      revive: {123, :old_position},
      transfer: :sealed,
      identity: :old
    }

    restored = Snapshot.decode!(Snapshot.encode(saved))

    assert restored == %{
             body: body,
             body_heat: heat,
             body_exchange_j: 123.0,
             life_generation: 7,
             food_cursors: %{11 => 9, 22 => 3}
           }
  end

  test "版本 2 投射物收据按原 key 并入作用回执；版本 3 原样往返" do
    v1 = %{
      body: Body.new(),
      body_heat: %{q_j: 0.0, tissue_j: 0.0, max_contact_k: nil, sole_k: nil, immersed: 0.0},
      body_exchange_j: 0.0,
      life_generation: 5,
      food_cursors: %{}
    }

    # 手写版本 2 字节：与改前 Snapshot.encode/1 写出的项相同。
    v2 = :erlang.term_to_binary({:body, 2, Map.put(v1, :projectile_hits, %{{77, 15, 0} => :receipt})})
    assert Snapshot.decode!(v2) == Map.put(v1, :effect_receipts, %{{77, 15, 0} => :receipt})

    v3 = Map.put(v1, :effect_receipts, %{{:identity, 11} => :tool, {77, 15, 0} => :projectile})
    assert Snapshot.decode!(Snapshot.encode(v3)) == v3
  end

  test "不接受未知存档版本并重置为健康身体" do
    assert_raise ArgumentError, fn ->
      Snapshot.decode!(:erlang.term_to_binary({:body, 99, %{}}))
    end
  end
end
