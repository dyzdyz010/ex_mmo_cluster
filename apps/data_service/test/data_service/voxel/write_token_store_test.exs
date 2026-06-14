defmodule DataService.Voxel.WriteTokenStoreTest do
  # 梯队1 step1.2:WriteTokenStore DB 化后共享 voxel_write_tokens 表,改 async:false + 每测试清表。
  use ExUnit.Case, async: false

  alias DataService.Voxel.WriteTokenStore

  setup do
    WriteTokenStore.reset()
    :ok
  end

  test "accepts current lease writes and rejects stale lease writes after CAS update" do
    store = start_supervised!(WriteTokenStore)
    future_ms = System.system_time(:millisecond) + 60_000

    token_v1 = %{
      logical_scene_id: 1,
      region_id: 10,
      lease_id: 100,
      owner_scene_instance_ref: 1_000,
      owner_epoch: 1,
      bounds_chunk_min: {0, 0, 0},
      bounds_chunk_max: {4, 4, 4},
      expires_at_ms: future_ms,
      token_version: 1
    }

    assert {:ok, :inserted} = WriteTokenStore.upsert_token(store, token_v1)
    assert {:ok, :unchanged} = WriteTokenStore.upsert_token(store, token_v1)

    assert :ok =
             WriteTokenStore.validate_write(store, %{
               logical_scene_id: 1,
               region_id: 10,
               chunk_coord: {1, 1, 1},
               lease_id: 100,
               owner_scene_instance_ref: 1_000,
               owner_epoch: 1
             })

    token_v2 = %{
      token_v1
      | lease_id: 101,
        owner_scene_instance_ref: 2_000,
        owner_epoch: 2,
        token_version: 2
    }

    assert {:ok, :updated} = WriteTokenStore.upsert_token(store, token_v2)
    assert {:error, :stale_token} = WriteTokenStore.upsert_token(store, token_v1)

    assert {:error, :lease_id_mismatch} =
             WriteTokenStore.validate_write(store, %{
               logical_scene_id: 1,
               region_id: 10,
               chunk_coord: {1, 1, 1},
               lease_id: 100,
               owner_scene_instance_ref: 1_000,
               owner_epoch: 1
             })

    assert :ok =
             WriteTokenStore.validate_write(store, %{
               logical_scene_id: 1,
               region_id: 10,
               chunk_coord: {1, 1, 1},
               lease_id: 101,
               owner_scene_instance_ref: 2_000,
               owner_epoch: 2
             })
  end

  test "rejects writes outside half-open region bounds" do
    store = start_supervised!(WriteTokenStore)

    assert {:ok, :inserted} =
             WriteTokenStore.upsert_token(store, %{
               logical_scene_id: 1,
               region_id: 10,
               lease_id: 100,
               owner_scene_instance_ref: 1_000,
               owner_epoch: 1,
               bounds_chunk_min: {0, 0, 0},
               bounds_chunk_max: {4, 4, 4},
               expires_at_ms: System.system_time(:millisecond) + 60_000,
               token_version: 1
             })

    assert {:error, :chunk_out_of_bounds} =
             WriteTokenStore.validate_write(store, %{
               logical_scene_id: 1,
               region_id: 10,
               chunk_coord: {4, 0, 0},
               lease_id: 100,
               owner_scene_instance_ref: 1_000,
               owner_epoch: 1
             })
  end

  test "token 在进程重启后仍有效(durable fencing,CELL-19/21)" do
    store = start_supervised!(WriteTokenStore)

    assert {:ok, :inserted} =
             WriteTokenStore.upsert_token(store, %{
               logical_scene_id: 7,
               region_id: 70,
               lease_id: 700,
               owner_scene_instance_ref: 7_000,
               owner_epoch: 3,
               bounds_chunk_min: {0, 0, 0},
               bounds_chunk_max: {4, 4, 4},
               expires_at_ms: System.system_time(:millisecond) + 60_000,
               token_version: 1
             })

    # 模拟重启:停掉垫片进程,token 真相在 Postgres,validate 仍通过(此前内存版会失效)。
    :ok = stop_supervised(WriteTokenStore)

    assert :ok =
             WriteTokenStore.validate_write(%{
               logical_scene_id: 7,
               region_id: 70,
               chunk_coord: {1, 1, 1},
               lease_id: 700,
               owner_scene_instance_ref: 7_000,
               owner_epoch: 3
             })
  end
end
