defmodule SceneServer.Voxel.BuildTransactionApplierOwnerLookupTest do
  # Phase A4-4 (D7):after upserting a scene_object into the ObjectRegistry,
  # `register_scene_objects/2` must also write the per-region split to
  # `ObjectOwnerLookup` so subsequent damage / 0x6C broadcasts can route by
  # owner without a fresh SELECT。
  use ExUnit.Case, async: true

  alias SceneServer.Voxel.BuildTransactionApplier

  defmodule FakeRegistry do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      reply = Keyword.get(opts, :reply, :ok)
      GenServer.start_link(__MODULE__, %{calls: [], reply: reply}, name: name)
    end

    def calls(server), do: GenServer.call(server, :calls)
    def set_reply(server, reply), do: GenServer.call(server, {:set_reply, reply})

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call(:calls, _from, state), do: {:reply, Enum.reverse(state.calls), state}

    def handle_call({:set_reply, reply}, _from, state),
      do: {:reply, :ok, %{state | reply: reply}}

    def handle_call({:upsert_object, instance}, _from, state) do
      {:reply, state.reply,
       %{state | calls: [{:upsert_object, instance.object_id} | state.calls]}}
    end
  end

  defmodule FakeOwnerLookup do
    use GenServer

    def start_link(opts) do
      name = Keyword.fetch!(opts, :name)
      GenServer.start_link(__MODULE__, %{calls: []}, name: name)
    end

    def calls(server), do: GenServer.call(server, :calls)

    def register(server, instance, covered_chunks_by_region) do
      GenServer.call(server, {:register, instance, covered_chunks_by_region})
    end

    def fetch_owner(_server, _scene_id, _object_id), do: {:error, :not_found}
    def evict(_server, _scene_id, _object_id), do: :ok

    @impl true
    def init(state), do: {:ok, state}

    @impl true
    def handle_call(:calls, _from, state), do: {:reply, Enum.reverse(state.calls), state}

    def handle_call({:register, instance, covered}, _from, state) do
      entry =
        {:register, instance.object_id, instance.owner_region_id, instance.owner_lease_id,
         covered}

      {:reply, :ok, %{state | calls: [entry | state.calls]}}
    end
  end

  setup do
    registry_name = :"fake_registry_#{System.unique_integer([:positive])}"
    registry = start_supervised!({FakeRegistry, [name: registry_name]})

    lookup_name = :"fake_owner_lookup_#{System.unique_integer([:positive])}"
    lookup = start_supervised!({FakeOwnerLookup, [name: lookup_name]})

    %{
      registry: registry,
      registry_name: registry_name,
      lookup: lookup,
      lookup_name: lookup_name
    }
  end

  test "writes per-region split into ObjectOwnerLookup after upsert", ctx do
    obj = %{
      object_id: 42,
      logical_scene_id: 1,
      owner_region_id: 11,
      owner_lease_id: 101,
      covered_chunks_by_region: %{
        {11, 101} => [{0, 0, 0}],
        {12, 102} => [{1, 0, 0}]
      }
    }

    assert :ok =
             BuildTransactionApplier.register_scene_objects(
               [obj],
               object_registry: ctx.registry_name,
               owner_lookup: FakeOwnerLookup,
               owner_lookup_server: ctx.lookup_name
             )

    assert FakeRegistry.calls(ctx.registry) == [{:upsert_object, 42}]

    assert [{:register, 42, 11, 101, covered}] = FakeOwnerLookup.calls(ctx.lookup)

    assert covered == %{
             {11, 101} => [{0, 0, 0}],
             {12, 102} => [{1, 0, 0}]
           }
  end

  test "missing :covered_chunks_by_region defaults to empty map", ctx do
    obj = %{
      object_id: 7,
      logical_scene_id: 1,
      owner_region_id: 1,
      owner_lease_id: 100
    }

    assert :ok =
             BuildTransactionApplier.register_scene_objects(
               [obj],
               object_registry: ctx.registry_name,
               owner_lookup: FakeOwnerLookup,
               owner_lookup_server: ctx.lookup_name
             )

    assert [{:register, 7, 1, 100, %{}}] = FakeOwnerLookup.calls(ctx.lookup)
  end

  test "skips owner lookup when upsert fails", ctx do
    :ok = FakeRegistry.set_reply(ctx.registry, {:error, :persist_failed})

    obj = %{
      object_id: 99,
      logical_scene_id: 1,
      owner_region_id: 1,
      owner_lease_id: 100,
      covered_chunks_by_region: %{{1, 100} => [{0, 0, 0}]}
    }

    assert :ok =
             BuildTransactionApplier.register_scene_objects(
               [obj],
               object_registry: ctx.registry_name,
               owner_lookup: FakeOwnerLookup,
               owner_lookup_server: ctx.lookup_name
             )

    assert FakeOwnerLookup.calls(ctx.lookup) == []
  end
end
