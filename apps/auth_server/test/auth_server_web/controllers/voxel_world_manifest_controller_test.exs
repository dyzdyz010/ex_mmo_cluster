defmodule AuthServerWeb.VoxelWorldManifestControllerTest do
  use AuthServerWeb.ConnCase, async: false

  alias DataService.Voxel.ChunkSnapshotStore
  alias DataService.Voxel.LodHeightmapStore
  alias DataService.Voxel.WriteTokenStore

  setup do
    {:ok, _data_started} = Application.ensure_all_started(:data_service)
    {:ok, _auth_started} = Application.ensure_all_started(:auth_server)

    previous_auto_login = Application.get_env(:auth_server, :dev_auto_login, false)
    previous_world_pack = Application.get_env(:auth_server, :voxel_world_pack, [])

    Application.put_env(:auth_server, :dev_auto_login, true)
    Application.delete_env(:auth_server, :voxel_world_pack)
    ChunkSnapshotStore.reset()
    LodHeightmapStore.reset()
    WriteTokenStore.reset()

    on_exit(fn ->
      Application.put_env(:auth_server, :dev_auto_login, previous_auto_login)
      Application.put_env(:auth_server, :voxel_world_pack, previous_world_pack)
      ChunkSnapshotStore.reset()
      LodHeightmapStore.reset()
      WriteTokenStore.reset()
    end)

    :ok
  end

  test "GET /ingame/voxel/world_manifest rejects scene entry without a verified world pack",
       %{conn: conn} do
    conn = get(conn, ~p"/ingame/voxel/world_manifest", %{"logical_scene_id" => "91001"})
    body = json_response(conn, 200)

    assert body["logical_scene_id"] == 91_001
    assert body["scene_entry_allowed"] == false
    assert body["reject_reason"] == "world_pack_missing_or_unverified"
    assert body["phase_contract"]["launcher_stage"] == "world_pack_download_and_hash_validation"
    assert body["phase_contract"]["scene_stage"] == "runtime_diff_streaming"
    assert body["phase_contract"]["runtime_snapshot_is_baseline_fallback"] == false
    assert body["world_pack"]["required"] == true
    assert body["world_pack"]["status"] == "missing"
    assert body["world_pack"]["scene_entry_allowed"] == false
    assert body["world_pack"]["diff_endpoint"] == "/ingame/voxel/world_diff"
    assert body["startup_sync"]["client_must_persist_before_scene"] == true
    assert body["dev_materialization"]["diagnostic_only"] == true
    assert body["dev_materialization"]["scene_entry_allowed"] == false

    assert body["dev_materialization"]["chunk_snapshots"]["status"] == "empty"
    assert body["dev_materialization"]["lod_projection"]["status"] == "empty"
  end

  test "GET /ingame/voxel/world_manifest allows scene entry only for a ready world pack",
       %{conn: conn} do
    Application.put_env(:auth_server, :voxel_world_pack,
      status: :ready,
      version: "worldgen-test-pack",
      content_version: "worldgen-test-pack@42",
      world_macro_extent: 32_768,
      generated: %{
        logical_scene_id: 91_002,
        chunk_min: [-3, -3, -3],
        chunk_max: [3, 3, 3],
        chunk_count: 343
      }
    )

    conn = get(conn, ~p"/ingame/voxel/world_manifest", %{"logical_scene_id" => "91002"})
    body = json_response(conn, 200)

    assert body["scene_entry_allowed"] == true
    assert body["reject_reason"] == nil
    assert body["world_pack"]["status"] == "ready"
    assert body["world_pack"]["version"] == "worldgen-test-pack"
    assert body["world_pack"]["content_version"] == "worldgen-test-pack@42"
    assert body["world_pack"]["scene_entry_allowed"] == true
    assert body["world_pack"]["generated"]["chunk_count"] == 343
    assert body["world_pack"]["generated"]["chunk_min"] == [-3, -3, -3]
    assert body["startup_sync"]["target_content_version"] == "worldgen-test-pack@42"
  end

  test "GET /ingame/voxel/world_manifest is disabled outside the dev auth surface",
       %{conn: conn} do
    Application.put_env(:auth_server, :dev_auto_login, false)

    conn = get(conn, ~p"/ingame/voxel/world_manifest")
    body = json_response(conn, 403)

    assert body["error"] == "dev_auto_login_disabled"
  end

  test "GET /ingame/voxel/world_diff refuses to synthesize data when the world pack is missing",
       %{conn: conn} do
    conn = get(conn, ~p"/ingame/voxel/world_diff", %{"logical_scene_id" => "91003"})
    body = json_response(conn, 409)

    assert body["error"] == "world_pack_not_ready"
    assert body["required_stage"] == "launcher_worldgen_materialization"
  end

  test "GET /ingame/voxel/world_diff pages canonical snapshot payloads for a ready pack",
       %{conn: conn} do
    logical_scene_id = 91_004
    token = token(logical_scene_id)
    assert {:ok, _} = WriteTokenStore.upsert_token(token)

    assert {:ok, :inserted} =
             ChunkSnapshotStore.put_snapshot(snapshot_attrs(token, {0, 0, 0}, 0, <<"zero">>))

    assert {:ok, :inserted} =
             ChunkSnapshotStore.put_snapshot(snapshot_attrs(token, {1, 0, 0}, 1, <<"one">>))

    Application.put_env(:auth_server, :voxel_world_pack,
      status: :ready,
      version: "worldgen-test-pack",
      content_version: "worldgen-test-pack@43"
    )

    conn =
      get(conn, ~p"/ingame/voxel/world_diff", %{
        "logical_scene_id" => Integer.to_string(logical_scene_id),
        "base_version" => "",
        "limit" => "1"
      })

    body = json_response(conn, 200)

    assert body["target_content_version"] == "worldgen-test-pack@43"
    assert body["complete"] == false
    assert body["next_cursor"] == 1

    assert [%{"chunk_coord" => [0, 0, 0], "snapshot_payload_b64" => first_payload}] =
             body["chunks"]

    assert Base.decode64!(first_payload) == <<"zero">>

    conn =
      conn
      |> recycle()
      |> get(~p"/ingame/voxel/world_diff", %{
        "logical_scene_id" => Integer.to_string(logical_scene_id),
        "base_version" => "",
        "cursor" => "1",
        "limit" => "1"
      })

    body = json_response(conn, 200)

    assert body["complete"] == false

    assert [%{"chunk_coord" => [1, 0, 0], "snapshot_payload_b64" => second_payload}] =
             body["chunks"]

    assert Base.decode64!(second_payload) == <<"one">>

    conn =
      conn
      |> recycle()
      |> get(~p"/ingame/voxel/world_diff", %{
        "logical_scene_id" => Integer.to_string(logical_scene_id),
        "base_version" => "worldgen-test-pack@43",
        "cursor" => "0",
        "limit" => "1"
      })

    body = json_response(conn, 200)

    assert body["complete"] == true
    assert body["chunks"] == []
  end

  defp token(logical_scene_id) do
    %{
      logical_scene_id: logical_scene_id,
      region_id: logical_scene_id * 10,
      lease_id: 1,
      owner_scene_instance_ref: 1,
      owner_epoch: 1,
      bounds_chunk_min: {-10, -10, -10},
      bounds_chunk_max: {10, 10, 10},
      expires_at_ms: System.system_time(:millisecond) + 60_000,
      token_version: 1
    }
  end

  defp snapshot_attrs(token, chunk_coord, chunk_version, payload) do
    %{
      logical_scene_id: token.logical_scene_id,
      region_id: token.region_id,
      lease_id: token.lease_id,
      owner_scene_instance_ref: token.owner_scene_instance_ref,
      owner_epoch: token.owner_epoch,
      chunk_coord: chunk_coord,
      schema_version: 1,
      chunk_size_in_macro: 16,
      micro_resolution: 8,
      chunk_version: chunk_version,
      chunk_hash: :crypto.hash(:sha256, payload) |> binary_part(0, 8),
      data: payload
    }
  end
end
