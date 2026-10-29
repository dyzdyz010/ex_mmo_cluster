# 只测试：用受控规范与加载器验证启动接缝，不启动项目应用、NIF、数据库或 World。
for name <- ["boot.exs", "runtime_identity.exs"],
  do: name |> then(&Path.join(__DIR__, &1)) |> File.read!() |> Code.string_to_quoted!()
ExUnit.start()
helper = Path.join(__DIR__, "code_ready.exs")
if File.exists?(helper), do: Code.require_file(helper)

defmodule M0CodeReadyTest do
  use ExUnit.Case, async: false
  alias VoxelRegion.Bench.M0CodeReady

  setup do
    Process.put(:events, [])
    Process.put(:loaded, false)
    on_exit(fn -> :persistent_term.erase({M0CodeReady, :startup}) end)
    :ok
  end

  defp record(event), do: Process.put(:events, Process.get(:events) ++ [event])

  defp callbacks(overrides \\ []) do
    Keyword.merge([
      world_pid: fn -> nil end,
      application_load: fn app -> record({:load_app, app}); :ok end,
      application_key: fn
        _, :vsn -> {:ok, ~c"0.1.0"}
        :voxel_region, :modules -> {:ok, [M0Fixture.Voxel, M0Fixture.Shared]}
        :mmo_contracts, :modules -> {:ok, [M0Fixture.Shared, M0Fixture.Codec]}
        :data_service, :modules -> {:ok, [M0Fixture.Store]}
      end,
      ensure_modules_loaded: fn modules ->
        record({:batch, modules})
        Process.put(:loaded, true)
        :ok
      end,
      is_loaded: fn _ -> if Process.get(:loaded), do: {:file, ~c"fixture.beam"}, else: false end
    ], overrides)
  end

  defp prepare_then_start(callbacks) do
    facts = M0CodeReady.prepare!(callbacks)
    record(:start_world)
    record({:ready, facts})
    Process.get(:events)
  end

  test "prepare 返回前完成一次去重标准加载并冻结启动事实，调用方才可继续" do
    events = prepare_then_start(callbacks())
    assert [{:batch, modules}] = Enum.filter(events, &match?({:batch, _}, &1))
    assert modules == [M0Fixture.Voxel, M0Fixture.Shared, M0Fixture.Codec, M0Fixture.Store]
    assert Enum.find_index(events, &match?({:batch, _}, &1)) <
             Enum.find_index(events, &(&1 == :start_world))
    assert {:ready, ready} = List.last(events)
    assert ready.profile == "m0_manifest_ready_v1"
    assert ready.code_mode == :code.get_mode()
    assert ready.loaded_count == 4
    assert ready.ensure_modules_loaded_result == :ok
    assert length(ready.app_manifests) == 3
    assert ready.phases.started_us <= ready.phases.manifest_completed_us
    assert ready.phases.manifest_completed_us <= ready.phases.load_started_us
    assert ready.phases.load_started_us <= ready.phases.load_completed_us
    assert ready.phases.load_completed_us <= ready.phases.completed_us
    assert M0CodeReady.startup_identity!() == %{startup: ready, code_mode: :code.get_mode()}
    assert_raise RuntimeError, ~r/M0 code readiness.*already_recorded/, fn ->
      M0CodeReady.prepare!(callbacks())
    end
  end

  test "缺 manifest 阻止 prepare 返回，不加载模块、不启动后续动作、不发 ready" do
    opts = callbacks(application_key: fn _, _ -> :undefined end)
    assert_raise RuntimeError, ~r/M0 code readiness.*manifest/, fn -> prepare_then_start(opts) end
    refute :start_world in Process.get(:events)
    refute Enum.any?(Process.get(:events), &match?({kind, _} when kind in [:batch, :ready], &1))
  end

  test "模块或 NIF 加载失败阻止 prepare 返回，不重试、不发 ready" do
    opts = callbacks(ensure_modules_loaded: fn modules ->
      record({:batch, modules})
      {:error, [{M0Fixture.Voxel, :on_load_failure}]}
    end)
    assert_raise RuntimeError, ~r/M0 code readiness.*module_load.*on_load_failure/, fn -> prepare_then_start(opts) end
    assert length(Enum.filter(Process.get(:events), &match?({:batch, _}, &1))) == 1
    refute :start_world in Process.get(:events)
    refute Enum.any?(Process.get(:events), &match?({:ready, _}, &1))
  end

  test "应用规范加载只接受 ok 或同 app already_loaded" do
    for result <- [{:error, :enoent}, {:error, {:already_loaded, :other_app}}] do
      assert_raise RuntimeError, ~r/M0 code readiness.*application_load/, fn ->
        M0CodeReady.prepare!(callbacks(application_load: fn _ -> result end))
      end
    end
    facts = M0CodeReady.prepare!(callbacks(application_load: fn app -> {:error, {:already_loaded, app}} end))
    assert Enum.all?(facts.app_manifests, &(&1.application_load_result == :already_loaded))
  end

  test "空或非法 manifest 拒绝，loader ok 但模块未 loaded 也不能发 ready" do
    for modules <- [[], nil, ["not-an-atom"]] do
      assert_raise RuntimeError, ~r/M0 code readiness.*manifest/, fn ->
        M0CodeReady.prepare!(callbacks(application_key: fn
          _, :vsn -> {:ok, ~c"0.1.0"}
          _, :modules -> {:ok, modules}
        end))
      end
    end
    assert_raise RuntimeError, ~r/M0 code readiness.*loaded_verification/, fn ->
      prepare_then_start(callbacks(is_loaded: fn _ -> false end))
    end
    refute :start_world in Process.get(:events)
    refute Enum.any?(Process.get(:events), &match?({:ready, _}, &1))
  end

  test "已有 World 时在入口拒绝，不修改该 authority、不加载模块" do
    assert_raise RuntimeError, ~r/M0 code readiness.*world_already_started/, fn ->
      prepare_then_start(callbacks(world_pid: fn -> self() end))
    end
    assert Process.get(:events) == []
    assert :persistent_term.get({M0CodeReady, :startup}, :absent) == :absent
  end
end
