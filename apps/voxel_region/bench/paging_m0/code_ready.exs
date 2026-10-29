defmodule VoxelRegion.Bench.M0CodeReady do
  @moduledoc """
  只测试：M0 在大 World 创建前唯一的三应用代码就绪边界与启动事实 owner。

  规范取自目标 VM，批量加载恰好一次；正常 NIF on_load 属于本边界。
  失败可留下已加载模块，但必须结束该隔离 VM，不跳过、重试或卸载回滚。
  回调仅供无项目应用的纯边界测试；正式 boot 不传替身。
  """
  @apps [:voxel_region, :mmo_contracts, :data_service]
  @profile "m0_manifest_ready_v1"
  @startup_key {__MODULE__, :startup}

  @doc "在 World 尚未创建时接纳规范、一次补载并冻结启动报告；失败抛出带阶段的错误。"
  def prepare!(callbacks \\ []) do
    world_pid = Keyword.get(callbacks, :world_pid, fn -> Process.whereis(VoxelRegion.World) end)
    if world_pid.() != nil, do: fail!(:world_already_started, :world_must_not_exist)
    if :persistent_term.get(@startup_key, :absent) != :absent,
      do: fail!(:already_recorded, :startup_is_immutable)

    started_us = now_us()
    started_utc = utc()
    application_load = Keyword.get(callbacks, :application_load, &Application.load/1)
    application_key = Keyword.get(callbacks, :application_key, &:application.get_key/2)
    loader = Keyword.get(callbacks, :ensure_modules_loaded, &:code.ensure_modules_loaded/1)
    is_loaded = Keyword.get(callbacks, :is_loaded, &:code.is_loaded/1)

    manifests = Enum.map(@apps, fn app ->
      load_result = case application_load.(app) do
        :ok -> :loaded
        {:error, {:already_loaded, ^app}} -> :already_loaded
        other -> fail!(:application_load, {app, other})
      end

      vsn = case application_key.(app, :vsn) do
        {:ok, value} when is_binary(value) and byte_size(value) > 0 -> value
        {:ok, [_ | _] = value} -> List.to_string(value)
        other -> fail!(:manifest, {app, :vsn, other})
      end

      modules = case application_key.(app, :modules) do
        {:ok, [_ | _] = value} ->
          if Enum.all?(value, &is_atom/1), do: value, else: fail!(:manifest, {app, :invalid_modules})
        other -> fail!(:manifest, {app, :modules, other})
      end

      %{app: app, vsn: vsn, modules: Enum.map(modules, &Atom.to_string/1),
        application_load_result: load_result, module_atoms: modules}
    end)

    modules = manifests |> Enum.flat_map(& &1.module_atoms) |> Enum.uniq()
    manifests = Enum.map(manifests, &Map.delete(&1, :module_atoms))
    manifest_completed_us = now_us()
    before = loaded(modules, is_loaded)
    load_started_us = now_us()
    case loader.(modules) do
      :ok -> :ok
      other -> fail!(:module_load, other)
    end
    load_completed_us = now_us()
    after_load = loaded(modules, is_loaded)
    missing = Enum.filter(after_load, &(&1.status != :loaded))
    if missing != [], do: fail!(:loaded_verification, missing)

    report = %{
      profile: @profile, status: :ready, code_mode: :code.get_mode(),
      os_pid: :os.getpid() |> to_string() |> String.to_integer(), node: Atom.to_string(node()),
      app_manifests: manifests, module_count: length(modules), loaded_count: length(after_load),
      ensure_modules_loaded_result: :ok, loaded_before: before, loaded_after: after_load,
      started_utc: started_utc, completed_utc: utc(),
      phases: %{started_us: started_us, manifest_completed_us: manifest_completed_us,
        load_started_us: load_started_us, load_completed_us: load_completed_us, completed_us: now_us()}
    }

    # 唯一一次全局写发生在 World 创建前；运行期间只读，不更新或清除。
    :persistent_term.put(@startup_key, report)
    report
  end

  @doc "读取唯一启动报告及当前真实代码模式；没有本 profile 的启动事实时显式失败。"
  def startup_identity! do
    case :persistent_term.get(@startup_key, :absent) do
      :absent -> fail!(:startup_identity, :missing_startup_report)
      report -> %{startup: report, code_mode: :code.get_mode()}
    end
  end

  defp loaded(modules, is_loaded) do
    Enum.map(modules, fn module ->
      case is_loaded.(module) do
        false -> %{module: Atom.to_string(module), status: :not_loaded}
        {:file, file} -> %{module: Atom.to_string(module), status: :loaded, beam: to_string(file)}
        other -> fail!(:loaded_metadata, {module, other})
      end
    end)
  end

  defp now_us, do: System.monotonic_time(:microsecond)
  defp utc, do: DateTime.to_iso8601(DateTime.utc_now())
  defp fail!(stage, reason),
    do: raise("M0 code readiness failed: stage=#{stage} reason=#{inspect(reason, limit: :infinity)}")
end
