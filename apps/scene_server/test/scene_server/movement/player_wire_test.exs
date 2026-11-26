defmodule SceneServer.Movement.PlayerWireTest do
  use ExUnit.Case, async: true

  @moduletag :t0

  alias MmoContracts.{Session, Voxel}
  alias SceneServer.Body
  alias SceneServer.Movement.PlayerWire

  defp identity do
    %Session.Identity{
      session_epoch: 7,
      scene_id: "scene-a",
      scene_epoch: 3
    }
  end

  test "window_domain 与 property_box 在正负 XYZ 坐标下互逆且行程盒内缩 1/4 tile" do
    extent = Voxel.Payload.extent() - 2
    snapshot = %{l0_min: {-2, -1, 0}, l0_max_exclusive: {1, 2, 3}}

    domain = PlayerWire.window_domain(snapshot)

    assert domain.l0_box == {{-2, -1, 0}, {1, 2, 3}}

    assert domain.bounds ==
             {{-2.0 * extent, -1.0 * extent, 0.0}, {1.0 * extent, 2.0 * extent, 3.0 * extent}}

    assert domain.travel == {
             {-2.0 * extent + extent / 4, -1.0 * extent + extent / 4, extent / 4},
             {1.0 * extent - extent / 4, 2.0 * extent - extent / 4, 3.0 * extent - extent / 4}
           }

    assert PlayerWire.property_box(domain) == {{-2, -1, 0}, {1, 2, 3}}
  end

  test "property_batch 缺少 property_context 时跳过；存在时按坐标排序打包 epochs 并返回字节统计" do
    id = identity()
    box = {{-1, 0, 0}, {2, 1, 2}}

    assert :skip == PlayerWire.property_batch(id, %{transaction_seq: 10}, false, box)

    digest = :binary.copy(<<0xAB>>, 32)

    value = %{
      seq: 42,
      property_context: %{
        hp_enabled: true,
        digest: digest,
        thermal_enabled: false,
        ambient_kelvin: 293.15
      },
      epochs: %{
        {1, 0, -1} => 9,
        {-2, 3, 4} => 5
      },
      property_states: []
    }

    assert {:ok, %Voxel.PropertyBatch{} = batch, stats} =
             PlayerWire.property_batch(id, value, true, box)

    assert batch.identity == id
    assert batch.transaction_seq == 42
    assert batch.l0_min == {-1, 0, 0}
    assert batch.l0_max_exclusive == {2, 1, 2}
    assert batch.complete == 1
    assert batch.hp_enabled == 1
    assert batch.thermal_enabled == 0
    assert batch.digest == digest
    assert batch.ambient_kelvin == 293.15

    # epochs 按键升序编码：{-2, 3, 4} 先于 {1, 0, -1}，每条 20 字节
    assert batch.epochs ==
             <<-2::signed-32, 3::signed-32, 4::signed-32, 5::64, 1::signed-32, 0::signed-32,
               -1::signed-32, 9::64>>

    assert stats == %{states: 0, epochs: 2, body_bytes: 40}
  end

  test "collision_window、collision_applied、relocate 与 body_state 投影保留完整字段" do
    id = identity()

    snapshot = %{
      transaction_seq: 12,
      l0_min: {0, 0, 0},
      l0_max_exclusive: {3, 3, 3},
      regions: [{{0, 0, 0}, <<1, 2, 3>>}]
    }

    domain = PlayerWire.window_domain(snapshot)
    window = PlayerWire.collision_window(id, 99, 120, snapshot, 4, domain)

    assert %Voxel.CollisionWindow{apply_tick: 120, content_version: 99, collision_revision: 4} =
             window

    assert window.travel_min_m == elem(domain.travel, 0)
    assert window.travel_max_exclusive_m == elem(domain.travel, 1)

    applied =
      PlayerWire.collision_applied(id, 121, 13, 5, [%{coord: {1, 2, 3}}, %{coord: {4, 5, 6}}])

    assert %Voxel.CollisionApplied{changed_chunks: [{1, 2, 3}, {4, 5, 6}], apply_tick: 121} =
             applied

    state = %Session.State{
      position: {1.0, 2.0, 3.0},
      velocity: {0.0, 0.0, 0.0},
      grounded: 1,
      yaw: 0
    }

    assert %Voxel.Relocate{identity: ^id, apply_tick: 122, state: ^state} =
             PlayerWire.relocate(id, 122, state)

    report = %{
      life: 95,
      recoverable: 100,
      status: 0,
      core_k: 310.15,
      skin_k: 306.15,
      protein_g: 50.0,
      injuries: [{:burn, 1, 0.25, 30}]
    }

    body_msg = PlayerWire.body_state(id, report)

    assert %Session.BodyState{
             identity: ^id,
             life: 95,
             injuries: [%Session.BodyInjury{tag: :burn, severity: 1, heal: 0.25, remaining_s: 30}]
           } = body_msg
  end

  test "body_contact 正确计算脚部坐标、身高与局部组织待吸收热温升" do
    body = Body.new()
    profile = %{half_height: 0.9, radius: 0.35}
    tissue_cap = Body.tissue_capacity_j_per_k()

    contact =
      PlayerWire.body_contact({10.0, 2.9, -4.0}, profile, body, %{tissue_j: 2.0 * tissue_cap})

    assert contact.feet == {10.0, 2.0, -4.0}
    assert_in_delta contact.height, 1.8, 1.0e-9
    assert contact.radius == 0.35
    assert_in_delta contact.tissue_k, body.tissue_k + 2.0, 1.0e-9
    assert contact.tissue_capacity == tissue_cap
  end
end
