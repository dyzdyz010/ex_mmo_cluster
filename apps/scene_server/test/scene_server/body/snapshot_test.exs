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

  test "不接受未知存档版本并重置为健康身体" do
    assert_raise ArgumentError, fn ->
      Snapshot.decode!(:erlang.term_to_binary({:body, 99, %{}}))
    end
  end
end
