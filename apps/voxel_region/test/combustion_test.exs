defmodule VoxelRegion.CombustionTest do
  use ExUnit.Case, async: true
  @moduletag :b6

  alias VoxelRegion.Combustion

  @wood %{
    "ignition_kelvin" => 300.0,
    "fuel_energy_per_macro_j" => 90_000.0,
    "burn_power_per_macro_w" => 900.0
  }

  test "ignition initializes finite fuel once and consumes it at published power" do
    row = %{granularity: 0, temperature_kelvin: 300.0}
    burning = Combustion.ignite(row, @wood, 1.0)
    assert burning.burning
    assert burning.remaining_fuel_j == 90_000.0
    assert burning.power_w == 900.0

    {next, used, _} = Combustion.step(burning, 0.5)
    assert used == 450.0
    assert next.remaining_fuel_j == 89_550.0

    {unchanged, _, _} = Combustion.step(%{next | remaining_fuel_j: 0.0}, 0.5)
    refute unchanged.burning
    assert unchanged.remaining_fuel_j == 0.0
  end

  test "ignition does not refill an existing remainder" do
    row = %{granularity: 0, burning: false, remaining_fuel_j: 123.0}
    assert Combustion.ignite(row, @wood, 1.0).remaining_fuel_j == 123.0
  end

  test "non combustible materials do not acquire combustion state" do
    row = %{granularity: 0}
    assert Combustion.ignite(row, %{}, 1.0) == row
  end
end
