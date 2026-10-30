defmodule VoxelRegion.TestSupport.StaticL0Audit do
  @moduledoc """
  只测试：以 OTP 局部 trace 记录限定 L0 页的真实 canonical 读取，并采集已有 debug 驻留事件。
  arity 标志和常量 message 避免复制 World 参数；只观察事件，不写入 authority 或改变读取结果。
  """
  alias VoxelRegion.World.{Canonical, StaticL0.Index}
  @handler :static_l0_test_audit
  @mfa {Canonical, :cell_value, 3}

  def capture(world, pages, action) do
    audit = start(world, pages)
    result = try do
      {:ok, action.()}
    catch
      kind, reason -> {:error, kind, reason, __STACKTRACE__}
    end
    events = stop(audit)
    case result do
      {:ok, value} -> {value, events}
      {:error, kind, reason, stack} -> :erlang.raise(kind, reason, stack)
    end
  end

  def start(world, pages) do
    Code.ensure_loaded!(Canonical)
    {:ok, handler} = :logger.get_handler_config(:default)
    module_level = :logger.get_module_level(Index)
    :ok = :logger.set_handler_config(:default, :level, :warning)
    :ok = :logger.set_module_level(Index, :debug)
    :ok = :logger.add_handler(@handler, __MODULE__, %{level: :debug,
      config: %{owner: self(), world: world, pages: MapSet.new(pages)}})
    session = :trace.session_create(:static_l0_reads, self(), [])
    specs = Enum.map(pages, &read_spec/1)
    1 = :trace.function(session, @mfa, specs, [:local])
    1 = :trace.process(session, world, true, [:call, :arity, :monotonic_timestamp])
    %{world: world, session: session, handler_level: handler.level, module_level: module_level}
  end

  defp read_spec({0, {x, y, z}} = page) do
    edge = MmoContracts.Voxel.Payload.extent() - 2
    bounds = Enum.zip([:"$1", :"$2", :"$3"], [x, y, z]) |> Enum.flat_map(fn {variable, coord} ->
      [{:>=, variable, coord * edge}, {:<, variable, (coord + 1) * edge}]
    end)
    {[:_, 0, {:"$1", :"$2", :"$3"}], bounds, [{:message, {:const, page}}]}
  end

  def log(%{meta: %{pid: pid, static_l0_event: event}}, %{config: config}) do
    if pid == config.world and event.action in [:resident, :retire] and MapSet.member?(config.pages, event.page_key) do
      send(config.owner, {:static_page_event, %{action: event.action, page: event.page_key, at: event.at_ns}})
    end
    :ok
  end
  def log(_, _), do: :ok

  def stop(audit) do
    :trace.process(audit.session, audit.world, false, [:call, :arity, :monotonic_timestamp])
    marker = :trace.delivered(audit.session, audit.world)
    try do
      drain(audit.world, marker, []) |> Enum.sort_by(& &1.at)
    after
      :trace.session_destroy(audit.session)
      :logger.remove_handler(@handler)
      :logger.set_handler_config(:default, :level, audit.handler_level)
      case audit.module_level do
        [] -> :logger.unset_module_level(Index)
        [{Index, level}] -> :logger.set_module_level(Index, level)
      end
    end
  end

  defp drain(world, marker, events) do
    receive do
      {:static_page_event, event} -> drain(world, marker, [event | events])
      {:trace_ts, ^world, :call, @mfa, page, at} ->
        drain(world, marker, [%{action: :read, page: page, at: at} | events])
      {:trace_delivered, ^world, ^marker} -> Enum.reverse(events)
    after
      5_000 -> raise "static L0 trace delivery did not complete"
    end
  end
end
