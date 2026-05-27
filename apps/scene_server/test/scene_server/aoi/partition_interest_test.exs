defmodule SceneServer.Aoi.PartitionInterestTest do
  use ExUnit.Case, async: true

  alias SceneServer.Aoi.PartitionInterest

  test "plans AOI queries from assigned near and halo partition routes" do
    plan =
      PartitionInterest.plan(%{
        cid: 42,
        partition_window: partition_window()
      })

    assert plan.cid == 42
    assert plan.logical_scene_id == 7
    assert plan.center_chunk == {0, 0, 0}
    assert plan.near_query_count == 1
    assert plan.halo_query_count == 1
    assert plan.skipped_count == 2
    assert plan.missing_count == 1
    assert plan.unleased_count == 1

    assert [
             %{
               chunk_coord: {0, 0, 0},
               tier: :near,
               region_id: 10,
               lease_id: 100,
               assigned_scene_node: :"scene-a@local",
               query_scope: :authoritative,
               priority_band: :high,
               delivery_interval: 1
             },
             %{
               chunk_coord: {1, 0, 0},
               tier: :halo,
               region_id: 20,
               lease_id: 200,
               assigned_scene_node: :"scene-b@local",
               query_scope: :halo_ghost,
               priority_band: :low,
               delivery_interval: 5
             }
           ] = plan.query_entries

    assert %{
             chunk_coord: {-1, 0, 0},
             tier: :halo,
             status: :region_without_lease,
             reason: :missing_lease
           } in plan.skipped_entries

    assert %{
             chunk_coord: {0, 1, 0},
             tier: :halo,
             status: :missing,
             reason: :missing_route
           } in plan.skipped_entries

    assert plan.region_query_summaries == [
             %{
               region_id: 10,
               assigned_scene_node: :"scene-a@local",
               near_count: 1,
               halo_count: 0
             },
             %{
               region_id: 20,
               assigned_scene_node: :"scene-b@local",
               near_count: 0,
               halo_count: 1
             }
           ]
  end

  test "ignores client supplied region hints and uses only partition-window route truth" do
    plan =
      PartitionInterest.plan(%{
        cid: 42,
        client_region_id: 999,
        partition_window: partition_window()
      })

    assert Enum.map(plan.query_entries, & &1.region_id) == [10, 20]
    refute Enum.any?(plan.query_entries, &(&1.region_id == 999))
  end

  test "plans remote halo routes as explicit remote mirror requests" do
    plan =
      PartitionInterest.plan(%{
        cid: 42,
        local_scene_node: :"scene-a@local",
        partition_window: partition_window()
      })

    assert plan.local_scene_node == :"scene-a@local"
    assert plan.remote_mirror_request_count == 1

    assert [
             %{
               cid: 42,
               logical_scene_id: 7,
               center_chunk: {0, 0, 0},
               requester_scene_node: :"scene-a@local",
               owner_scene_node: :"scene-b@local",
               chunk_coord: {1, 0, 0},
               tier: :halo,
               region_id: 20,
               lease_id: 200,
               assigned_scene_node: :"scene-b@local",
               query_scope: :halo_ghost,
               priority_band: :low,
               delivery_interval: 5,
               request_mode: :ghost,
               request_key: {:"scene-b@local", 200, {1, 0, 0}},
               status: :planned,
               reason: :remote_halo_route
             }
           ] = plan.remote_mirror_requests
  end

  test "does not request remote mirrors for local halo or remote near routes" do
    plan =
      PartitionInterest.plan(%{
        cid: 42,
        local_scene_node: :"scene-a@local",
        partition_window: %{
          logical_scene_id: 7,
          center_chunk: {0, 0, 0},
          near_radius: 0,
          halo_radius: 1,
          route_entries: [
            %{
              chunk_coord: {0, 0, 0},
              tier: :near,
              status: :assigned,
              region_id: 10,
              lease_id: 100,
              assigned_scene_node: :"scene-a@local"
            },
            %{
              chunk_coord: {0, 1, 0},
              tier: :near,
              status: :assigned,
              region_id: 20,
              lease_id: 200,
              assigned_scene_node: :"scene-b@local"
            },
            %{
              chunk_coord: {1, 0, 0},
              tier: :halo,
              status: :assigned,
              region_id: 10,
              lease_id: 100,
              assigned_scene_node: :"scene-a@local"
            }
          ]
        }
      })

    assert plan.remote_mirror_requests == []
    assert plan.remote_mirror_request_count == 0
  end

  test "rejects malformed assigned routes before they become AOI queries" do
    for {field, value, expected_message} <- [
          {:region_id, nil, "region_id"},
          {:region_id, -1, "region_id"},
          {:lease_id, nil, "lease_id"},
          {:assigned_scene_node, nil, "assigned_scene_node"}
        ] do
      bad_entry =
        %{
          chunk_coord: {0, 0, 0},
          tier: :near,
          status: :assigned,
          region_id: 10,
          lease_id: 100,
          assigned_scene_node: :"scene-a@local"
        }
        |> Map.put(field, value)

      assert_raise ArgumentError, ~r/#{expected_message}/, fn ->
        PartitionInterest.plan(%{
          cid: 42,
          partition_window: %{
            logical_scene_id: 7,
            center_chunk: {0, 0, 0},
            near_radius: 0,
            halo_radius: 0,
            route_entries: [bad_entry]
          }
        })
      end
    end
  end

  test "summarizes near and halo AOI queries for the same routed region" do
    plan =
      PartitionInterest.plan(%{
        cid: 42,
        partition_window: %{
          logical_scene_id: 7,
          center_chunk: {0, 0, 0},
          near_radius: 0,
          halo_radius: 1,
          route_entries: [
            %{
              chunk_coord: {0, 0, 0},
              tier: :near,
              status: :assigned,
              region_id: 10,
              lease_id: 100,
              assigned_scene_node: :"scene-a@local"
            },
            %{
              chunk_coord: {1, 0, 0},
              tier: :halo,
              status: :assigned,
              region_id: 10,
              lease_id: 100,
              assigned_scene_node: :"scene-a@local"
            }
          ]
        }
      })

    assert plan.region_query_summaries == [
             %{
               region_id: 10,
               assigned_scene_node: :"scene-a@local",
               near_count: 1,
               halo_count: 1
             }
           ]
  end

  defp partition_window do
    %{
      logical_scene_id: 7,
      center_chunk: {0, 0, 0},
      near_radius: 0,
      halo_radius: 1,
      route_entries: [
        %{
          chunk_coord: {0, 0, 0},
          tier: :near,
          status: :assigned,
          region_id: 10,
          lease_id: 100,
          assigned_scene_node: :"scene-a@local"
        },
        %{
          chunk_coord: {1, 0, 0},
          tier: :halo,
          status: :assigned,
          region_id: 20,
          lease_id: 200,
          assigned_scene_node: :"scene-b@local"
        },
        %{
          chunk_coord: {-1, 0, 0},
          tier: :halo,
          status: :region_without_lease,
          region_id: 30,
          lease_id: nil,
          assigned_scene_node: :"scene-c@local"
        },
        %{
          chunk_coord: {0, 1, 0},
          tier: :halo,
          status: :missing,
          region_id: nil,
          lease_id: nil,
          assigned_scene_node: nil
        }
      ]
    }
  end
end
