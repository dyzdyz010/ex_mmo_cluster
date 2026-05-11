defmodule WorldServer.WorldSupResolverTest do
  use ExUnit.Case, async: true

  defp participant(region_id, lease_id, scene_node) do
    %WorldServer.Voxel.TransactionParticipant{
      participant_key: {:scene_owner, scene_node, region_id, lease_id},
      region_id: region_id,
      lease_id: lease_id,
      owner_scene_instance_ref: 1,
      owner_epoch: 0,
      assigned_scene_node: scene_node,
      affected_chunks: [{region_id, 0, 0}],
      chunk_owners: %{{region_id, 0, 0} => {region_id, lease_id}}
    }
  end

  defp unresolved_participant(region_id, lease_id) do
    %{
      participant_key: {:scene_owner, :missing, region_id, lease_id},
      region_id: region_id,
      lease_id: lease_id
    }
  end

  describe "default_scene_opts_resolver/2 (Phase A4-bis-4 段 2d)" do
    test "single participant uses its explicit assigned_scene_node" do
      assert {:ok, [scene_opts_by_participant: opts]} =
               WorldServer.WorldSup.default_scene_opts_resolver(
                 [participant(7_001, 100, :a@h)],
                 []
               )

      assert opts == %{
               {:scene_owner, :a@h, 7_001, 100} => [
                 chunk_directory: {SceneServer.Voxel.ChunkDirectory, :a@h}
               ]
             }
    end

    test "multiple participants use their own explicit scene_nodes" do
      assert {:ok, [scene_opts_by_participant: opts]} =
               WorldServer.WorldSup.default_scene_opts_resolver(
                 [participant(7_101, 200, :a@h), participant(7_102, 201, :b@h)],
                 []
               )

      assert opts[{:scene_owner, :a@h, 7_101, 200}] == [
               chunk_directory: {SceneServer.Voxel.ChunkDirectory, :a@h}
             ]

      assert opts[{:scene_owner, :b@h, 7_102, 201}] == [
               chunk_directory: {SceneServer.Voxel.ChunkDirectory, :b@h}
             ]
    end

    test "all participants unresolved → scene_unavailable with missing keys" do
      assert {:error, {:scene_unavailable, [{:scene_owner, :missing, 7_201, 300}]}} =
               WorldServer.WorldSup.default_scene_opts_resolver(
                 [unresolved_participant(7_201, 300)],
                 []
               )
    end

    test "partial resolution is rejected instead of dropping unresolved participants" do
      assert {:error, {:scene_unavailable, [{:scene_owner, :missing, 7_302, 401}]}} =
               WorldServer.WorldSup.default_scene_opts_resolver(
                 [participant(7_301, 400, :a@h), unresolved_participant(7_302, 401)],
                 []
               )
    end
  end
end
