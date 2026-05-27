defmodule SceneServer.Aoi.RemoteMirrorLedgerTest do
  use ExUnit.Case, async: true

  alias SceneServer.Aoi.RemoteMirrorLedger

  test "replaces requests by cid and reports added retained removed counts" do
    name = unique_name()
    start_supervised!({RemoteMirrorLedger, name: name})

    request = remote_request(42, {:"scene-b@local", 200, {1, 0, 0}})

    assert %{
             cid: 42,
             added_count: 1,
             retained_count: 0,
             removed_count: 0,
             active_request_count: 1,
             total_request_count: 1,
             group_count: 1
           } = RemoteMirrorLedger.replace_requests(42, [request], name)

    assert %{
             added_count: 0,
             retained_count: 1,
             removed_count: 0,
             active_request_count: 1,
             total_request_count: 1,
             group_count: 1
           } = RemoteMirrorLedger.replace_requests(42, [request], name)

    assert %{
             added_count: 0,
             retained_count: 0,
             removed_count: 1,
             active_request_count: 0,
             total_request_count: 0,
             group_count: 0
           } = RemoteMirrorLedger.clear_requests(42, name)
  end

  test "snapshot aggregates matching remote mirror requests without creating actor state" do
    name = unique_name()
    start_supervised!({RemoteMirrorLedger, name: name})

    request_a = remote_request(42, {:"scene-b@local", 200, {1, 0, 0}})
    request_b = remote_request(43, {:"scene-b@local", 200, {1, 0, 0}})

    RemoteMirrorLedger.replace_requests(42, [request_a], name)
    RemoteMirrorLedger.replace_requests(43, [request_b], name)

    assert %{
             total_request_count: 2,
             cid_count: 2,
             owner_scene_count: 1,
             group_count: 1,
             by_cid: by_cid,
             request_groups: [
               %{
                 logical_scene_id: 7,
                 request_key: {:"scene-b@local", 200, {1, 0, 0}},
                 request_cids: [42, 43],
                 cid_count: 2,
                 canonical_request: %{cid: 42, request_mode: :ghost}
               }
             ],
             requests: requests
           } = RemoteMirrorLedger.snapshot(name)

    assert Map.keys(by_cid) |> Enum.sort() == [42, 43]

    assert Enum.map(requests, & &1.request_key) == [
             {:"scene-b@local", 200, {1, 0, 0}},
             {:"scene-b@local", 200, {1, 0, 0}}
           ]
  end

  test "request groups are namespaced by logical scene id" do
    name = unique_name()
    start_supervised!({RemoteMirrorLedger, name: name})

    request_key = {:"scene-b@local", 200, {1, 0, 0}}

    RemoteMirrorLedger.replace_requests(
      42,
      [remote_request(42, request_key, logical_scene_id: 7)],
      name
    )

    RemoteMirrorLedger.replace_requests(
      43,
      [remote_request(43, request_key, logical_scene_id: 8)],
      name
    )

    assert %{
             total_request_count: 2,
             group_count: 2,
             request_groups: [
               %{logical_scene_id: 7, request_cids: [42]},
               %{logical_scene_id: 8, request_cids: [43]}
             ]
           } = RemoteMirrorLedger.snapshot(name)
  end

  test "accepts prewarm requests and keeps request modes in separate groups" do
    name = unique_name()
    start_supervised!({RemoteMirrorLedger, name: name})

    request_key = {:"scene-b@local", 200, {1, 0, 0}}

    RemoteMirrorLedger.replace_requests(
      42,
      [
        remote_request(42, request_key, request_mode: :ghost),
        remote_request(42, request_key, request_mode: :prewarm)
      ],
      name
    )

    assert %{
             total_request_count: 2,
             group_count: 2,
             request_groups: [
               %{request_mode: :ghost, request_cids: [42]},
               %{request_mode: :prewarm, request_cids: [42]}
             ]
           } = RemoteMirrorLedger.snapshot(name)
  end

  test "drops unexpected fields so the ledger stays control-plane only" do
    name = unique_name()
    start_supervised!({RemoteMirrorLedger, name: name})

    request =
      42
      |> remote_request({:"scene-b@local", 200, {1, 0, 0}})
      |> Map.merge(%{
        actors: [:should_not_be_here],
        remote_payload: :large_blob,
        subscribees: %{9001 => self()}
      })

    assert %{added_count: 1} = RemoteMirrorLedger.replace_requests(42, [request], name)

    assert %{
             requests: [stored],
             request_groups: [%{canonical_request: canonical}]
           } = RemoteMirrorLedger.snapshot(name)

    refute Map.has_key?(stored, :actors)
    refute Map.has_key?(stored, :remote_payload)
    refute Map.has_key?(stored, :subscribees)
    refute Map.has_key?(canonical, :actors)

    assert Map.keys(stored) |> Enum.sort() == expected_request_keys()
  end

  test "rejects invalid requests without crashing or changing active demand" do
    name = unique_name()
    start_supervised!({RemoteMirrorLedger, name: name})

    good_request = remote_request(42, {:"scene-b@local", 200, {1, 0, 0}})
    RemoteMirrorLedger.replace_requests(42, [good_request], name)

    assert {:error, {:invalid_request, message}} =
             RemoteMirrorLedger.replace_requests(
               99,
               [remote_request(42, {:"scene-b@local", 200, {1, 0, 0}})],
               name
             )

    assert message =~ "cid"

    assert {:error, {:invalid_request, mode_message}} =
             RemoteMirrorLedger.replace_requests(
               42,
               [
                 remote_request(42, {:"scene-b@local", 200, {1, 0, 0}},
                   request_mode: :authoritative
                 )
               ],
               name
             )

    assert mode_message =~ "request_mode"

    assert {:error, {:invalid_request, lease_message}} =
             RemoteMirrorLedger.replace_requests(
               42,
               [remote_request(42, {:"scene-b@local", 200, {1, 0, 0}}, lease_id: 201)],
               name
             )

    assert lease_message =~ "lease_id"

    assert {:error, {:invalid_request, chunk_message}} =
             RemoteMirrorLedger.replace_requests(
               42,
               [remote_request(42, {:"scene-b@local", 200, {1, 0, 0}}, chunk_coord: {2, 0, 0})],
               name
             )

    assert chunk_message =~ "chunk_coord"

    assert {:error, {:invalid_request, assigned_owner_message}} =
             RemoteMirrorLedger.replace_requests(
               42,
               [
                 remote_request(42, {:"scene-b@local", 200, {1, 0, 0}},
                   assigned_scene_node: :"scene-c@local"
                 )
               ],
               name
             )

    assert assigned_owner_message =~ "assigned_scene_node"

    assert {:error, {:invalid_request, requester_message}} =
             RemoteMirrorLedger.replace_requests(
               42,
               [
                 remote_request(42, {:"scene-b@local", 200, {1, 0, 0}}, requester_scene_node: nil)
               ],
               name
             )

    assert requester_message =~ "requester_scene_node"

    assert %{total_request_count: 1, request_groups: [%{request_cids: [42]}]} =
             RemoteMirrorLedger.snapshot(name)
  end

  defp remote_request(cid, request_key, opts \\ []) do
    {owner_scene_node, lease_id, chunk_coord} = request_key

    %{
      cid: cid,
      logical_scene_id: Keyword.get(opts, :logical_scene_id, 7),
      center_chunk: {0, 0, 0},
      requester_scene_node: Keyword.get(opts, :requester_scene_node, :"scene-a@local"),
      owner_scene_node: owner_scene_node,
      chunk_coord: Keyword.get(opts, :chunk_coord, chunk_coord),
      tier: :halo,
      region_id: lease_id,
      lease_id: Keyword.get(opts, :lease_id, lease_id),
      assigned_scene_node: Keyword.get(opts, :assigned_scene_node, owner_scene_node),
      query_scope: :halo_ghost,
      priority_band: :low,
      delivery_interval: 5,
      request_mode: Keyword.get(opts, :request_mode, :ghost),
      request_key: request_key,
      status: :planned,
      reason: :remote_halo_route
    }
  end

  defp unique_name do
    :"remote_mirror_ledger_#{System.unique_integer([:positive])}"
  end

  defp expected_request_keys do
    [
      :assigned_scene_node,
      :center_chunk,
      :chunk_coord,
      :cid,
      :delivery_interval,
      :lease_id,
      :logical_scene_id,
      :owner_scene_node,
      :priority_band,
      :query_scope,
      :reason,
      :region_id,
      :request_key,
      :request_mode,
      :requester_scene_node,
      :status,
      :tier
    ]
  end
end
