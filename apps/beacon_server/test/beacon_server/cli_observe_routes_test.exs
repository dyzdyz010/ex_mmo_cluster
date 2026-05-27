defmodule BeaconServer.CliObserveRoutesTest do
  use ExUnit.Case, async: false

  alias BeaconServer.CliObserveRoutes

  setup do
    if is_nil(Process.whereis(CliObserveRoutes)) do
      start_supervised!({CliObserveRoutes, []})
    end

    :ok
  end

  test "clear_all removes stale observe routes across scopes" do
    fields = %{logical_scene_id: 42}

    assert {:ok, _token} = CliObserveRoutes.register(:scene_server, 42, "scene.log")
    assert {:ok, _token} = CliObserveRoutes.register(:gate_server, 42, "gate.log")
    assert CliObserveRoutes.lookup(:scene_server, fields) == "scene.log"
    assert CliObserveRoutes.lookup(:gate_server, fields) == "gate.log"

    assert :ok = CliObserveRoutes.clear_all()

    assert CliObserveRoutes.lookup(:scene_server, fields) == nil
    assert CliObserveRoutes.lookup(:gate_server, fields) == nil
    refute CliObserveRoutes.any?(:scene_server)
    refute CliObserveRoutes.any?(:gate_server)
  end
end
