defmodule WorldServer.InterfaceTest do
  use ExUnit.Case, async: true

  alias WorldServer.Interface

  test "starts ready when service discovery already has scene and data nodes" do
    parent = self()

    pid =
      start_interface!(
        join_fun: fn -> send(parent, :joined) end,
        register_fun: fn resource -> send(parent, {:registered, resource}) end,
        lookup_fun: fn
          :scene_server -> {:ok, :scene@local}
          :data_service -> {:ok, :data@local}
        end
      )

    assert_eventually(fn ->
      assert %{
               scene_server: :scene@local,
               data_service: :data@local,
               server_state: :ready
             } = :sys.get_state(pid)
    end)

    assert_receive :joined
    assert_receive {:registered, :world_server}
    assert_receive {:registered, :voxel_transaction_coordinator}
  end

  test "keeps running and retries when dependencies are not available yet" do
    parent = self()

    {:ok, lookup_agent} =
      Agent.start_link(fn ->
        %{scene_server: :error, data_service: :error}
      end)

    pid =
      start_interface!(
        retry_interval_ms: 10,
        join_fun: fn -> send(parent, :joined) end,
        register_fun: fn resource -> send(parent, {:registered, resource}) end,
        lookup_fun: fn resource -> Agent.get(lookup_agent, &Map.fetch!(&1, resource)) end
      )

    assert_eventually(fn ->
      assert %{server_state: :waiting_requirements, scene_server: nil, data_service: nil} =
               :sys.get_state(pid)
    end)

    assert Process.alive?(pid)

    Agent.update(lookup_agent, fn _state ->
      %{scene_server: {:ok, :scene@local}, data_service: {:ok, :data@local}}
    end)

    assert_eventually(fn ->
      assert %{
               scene_server: :scene@local,
               data_service: :data@local,
               server_state: :ready
             } = :sys.get_state(pid)
    end)
  end

  defp start_interface!(opts) do
    name = :"world_interface_test_#{System.unique_integer([:positive])}"
    start_supervised!({Interface, Keyword.put(opts, :name, name)})
  end

  defp assert_eventually(fun, attempts \\ 20)

  defp assert_eventually(fun, attempts) when attempts > 0 do
    fun.()
  rescue
    ExUnit.AssertionError ->
      Process.sleep(10)
      assert_eventually(fun, attempts - 1)
  end

  defp assert_eventually(fun, 0), do: fun.()
end
