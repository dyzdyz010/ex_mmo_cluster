defmodule MmoContracts.CodecOwnershipTest do
  use ExUnit.Case, async: true

  test "current codec byte owners have no sibling app imports or application supervisor" do
    for module <- [
          MmoContracts.Session.Codec,
          MmoContracts.Voxel.Codec,
          MmoContracts.Voxel.Payload,
          MmoContracts.Voxel.Skins,
          MmoContracts.Voxel.Fields
        ] do
      {:ok, {^module, [{:imports, imports}]}} = :beam_lib.chunks(:code.which(module), [:imports])

      for {dependency, _, _} <- imports do
        refute String.starts_with?(Atom.to_string(dependency), [
                 "Elixir.GateServer.",
                 "Elixir.SceneServer.",
                 "Elixir.VoxelRegion."
               ])
      end
    end

    assert Application.spec(:mmo_contracts, :mod) == []

    refute Enum.any?(
             Application.spec(:mmo_contracts, :applications),
             &(&1 in [:gate_server, :scene_server, :voxel_region])
           )
  end
end
