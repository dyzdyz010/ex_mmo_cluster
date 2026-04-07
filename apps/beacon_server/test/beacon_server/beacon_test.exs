defmodule BeaconServer.BeaconTest do
  use ExUnit.Case, async: false

  alias BeaconServer.Beacon

  setup do
    name = :"beacon_#{:erlang.unique_integer([:positive])}"
    {:ok, pid} = Beacon.start_link(name: name)
    %{beacon: pid}
  end

  describe "register/2" do
    test "registers a node with resource and no requirements", %{beacon: pid} do
      credentials = {:"node1@test", TestModule, :gate_server, []}
      assert :ok = GenServer.call(pid, {:register, credentials})
    end

    test "registers a node with requirements", %{beacon: pid} do
      credentials = {:"node2@test", TestModule, :auth_server, [:data_contact]}
      assert :ok = GenServer.call(pid, {:register, credentials})
    end

    test "registers multiple nodes", %{beacon: pid} do
      assert :ok = GenServer.call(pid, {:register, {:"n1@test", M1, :service_a, []}})
      assert :ok = GenServer.call(pid, {:register, {:"n2@test", M2, :service_b, [:service_a]}})
      assert :ok = GenServer.call(pid, {:register, {:"n3@test", M3, :service_c, []}})
    end

    test "does not duplicate resources for same node", %{beacon: pid} do
      credentials = {:"dup@test", TestModule, :my_service, []}
      GenServer.call(pid, {:register, credentials})
      GenServer.call(pid, {:register, credentials})

      # get_requirements should still work fine
      assert {:ok, _} = GenServer.call(pid, {:get_requirements, :"dup@test"})
    end
  end

  describe "get_requirements/2" do
    test "returns {:ok, []} for node with no requirements", %{beacon: pid} do
      GenServer.call(pid, {:register, {:"nr@test", M, :svc, []}})
      assert {:ok, []} = GenServer.call(pid, {:get_requirements, :"nr@test"})
    end

    test "returns matching resources when requirements are met", %{beacon: pid} do
      # Register provider
      GenServer.call(pid, {:register, {:"provider@test", ProvMod, :data_contact, []}})
      # Register consumer that needs :data_contact
      GenServer.call(pid, {:register, {:"consumer@test", ConMod, :data_service, [:data_contact]}})

      {:ok, resources} = GenServer.call(pid, {:get_requirements, :"consumer@test"})
      assert length(resources) == 1
      assert hd(resources).name == :data_contact
      assert hd(resources).node == :"provider@test"
    end

    test "returns {:err, nil} when requirements are NOT met", %{beacon: pid} do
      unique = :erlang.unique_integer([:positive])
      lonely_node = :"lonely_#{unique}@test"
      missing = :"missing_#{unique}"
      GenServer.call(pid, {:register, {lonely_node, Mod, :lonely_svc, [missing]}})
      assert {:err, nil} = GenServer.call(pid, {:get_requirements, lonely_node})
    end

    test "resolves multiple requirements", %{beacon: pid} do
      GenServer.call(pid, {:register, {:"p1@test", M1, :svc_a, []}})
      GenServer.call(pid, {:register, {:"p2@test", M2, :svc_b, []}})
      GenServer.call(pid, {:register, {:"c@test", M3, :consumer, [:svc_a, :svc_b]}})

      {:ok, resources} = GenServer.call(pid, {:get_requirements, :"c@test"})
      names = Enum.map(resources, & &1.name)
      assert :svc_a in names
      assert :svc_b in names
    end

    test "returns {:ok, []} for unknown node (no requirements registered)", %{beacon: pid} do
      unique = :erlang.unique_integer([:positive])
      unknown_node = :"unknown_#{unique}@test"
      # Node never registered — find_requirements returns [], which means no requirements → {:ok, []}
      assert {:ok, []} = GenServer.call(pid, {:get_requirements, unknown_node})
    end
  end
end
