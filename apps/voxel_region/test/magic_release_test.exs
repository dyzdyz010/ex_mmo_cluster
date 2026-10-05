defmodule VoxelRegion.MagicReleaseTest do
  @moduledoc "只测试：最终定形后的释放前置时长与维护费，期望由 1000 W × 0.25 s 手算。"
  use ExUnit.Case, async: true
  alias VoxelRegion.Magic.{Catalog, Cost}

  test "最终符号无需调整时仍须等待出手帧，并且仅支付一次维护" do
    path = Path.expand("fixtures/magic/41d668f375b795ce9129dd3bbc1f9c70ce70278ded49f39c2441ccc540386bde.json", __DIR__)
    catalog = Catalog.load(path) |> Map.put(:release_lead_s, 0.25)
    catalog = put_in(catalog, [:symbols, "energy.draw", :pose], catalog.rest_pose)
    program = %{steps: [%{sym: "energy.draw", args: %{"energy_j" => 1000}}]}
    q = Cost.quote(program, catalog)
    assert q.steps == [{0.0, 0.0}]
    assert q.windup_s == 0.25
    assert q.physical_j == 0.0
    assert q.loss_j == 250.0
    assert q.total_j == 250.0
    assert Cost.misfire(q, 249.0, catalog) == :misfire_energy
    assert Cost.misfire(q, 250.0, catalog) == nil
  end
end
