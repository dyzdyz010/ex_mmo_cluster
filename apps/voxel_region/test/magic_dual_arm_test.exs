defmodule VoxelRegion.MagicDualArmTest do
  @moduledoc "Test-only: six coordinates, authored rest, and independent right-arm cost."
  use ExUnit.Case, async: true
  alias VoxelRegion.Magic.{Catalog, Cost}

  test "v3 uses every coordinate and the authored rest pose" do
    path = Path.expand("fixtures/magic/ff15757b8a7bfc20954ffde9370f04f0bc22b8a0b93fe31e03eb893165c7e9b1.json", __DIR__)
    data = Jason.decode!(File.read!(path))
    rest = [150, -120, -120, 30, 120, 120]
    data = data |> Map.put("version", 3) |> Map.put("rest_pose", rest)
    data = Map.update!(data, "symbols", fn rows ->
      Enum.map(rows, &Map.put(&1, "pose", [150, -120, -120, 30, 120, 30]))
    end)
    catalog = Catalog.decode(Jason.encode!(data))
    program = %{steps: [%{sym: "energy.draw", args: %{"energy_j" => 1000}}]}
    q = Cost.quote(program, catalog)
    # Only the sixth joint travels 90 degrees: d=pi/2, b=1000, eta=50.
    assert_in_delta q.windup_s, :math.pi() / 2 * :math.sqrt(0.05), 1.0e-12
    assert_in_delta q.loss_j, :math.pi() * :math.sqrt(50_000), 1.0e-9
    same = put_in(catalog, [:symbols, "energy.draw", :pose], catalog.rest_pose)
    assert %{windup_s: 0.0, loss_j: 0.0} = Cost.quote(program, same)
    for bad <- [[0, 0, 0, 0], [0, 0, 0, 0, 0, 176], [0, 0, 0, 0, 0, 1]] do
      assert_raise MatchError, fn -> Catalog.decode(Jason.encode!(Map.put(data, "rest_pose", bad))) end
    end
  end
end
