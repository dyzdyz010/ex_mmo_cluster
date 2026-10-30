defmodule VoxelRegion.ResidencyLoggingTest do
  @moduledoc "只测试：纯驻留回调的日志变化合同；不启动World、不注入authority。"
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog
  alias VoxelRegion.World.{PageLoad, Pages, Residency}

  defp blocked do
    %{
      source: VoxelRegion.GeneratedStore,
      thermal: %{},
      residency: Residency.new(),
      page_load: PageLoad.new(),
      liquid_active: MapSet.new(),
      liquid_bounds: nil,
      pending_casts: %{},
      magic: nil
    }
  end

  defp maintain(state), do: state |> Residency.request() |> Residency.maintain()

  test "相同连续阻退只警告一次，观察仍保留原错误" do
    {state, log} = with_log(fn -> Enum.reduce(1..4, blocked(), fn _, s -> maintain(s) end) end)
    assert length(Regex.scan(~r/voxel_page_retire_blocked/, log)) == 1
    assert state.residency.last.status == :blocked
    assert state.residency.last.reason =~ "natural_activity_unregistered"
    assert state.residency.retired_pages == 0
  end

  test "原因变化以及原原因再次出现均重新记录" do
    {_state, log} =
      with_log(fn ->
        first = maintain(blocked())
        changed = maintain(%{first | thermal: nil, pending_casts: %{1 => %{}}})
        assert changed.residency.last.reason =~ "pending_cast_without_magic_catalog"
        maintain(%{changed | thermal: %{}, pending_casts: %{}})
      end)

    assert length(Regex.scan(~r/voxel_page_retire_blocked/, log)) == 3
  end

  test "维护恢复ready后再次发生相同错误重新告警" do
    {_state, log} =
      with_log(fn ->
        state = maintain(blocked())

        ready =
          state
          |> Map.merge(%{
            thermal: nil,
            canonical_subs: %{},
            replica_subs: %{},
            simulation_windows: %{},
            input_ready: :queue.new(),
            input_current: nil,
            pages: Pages.new(),
            page_store: %{cut: nil, published: 0},
            resident: MapSet.new()
          })
          |> maintain()

        assert ready.residency.last.status == :ready
        maintain(%{ready | thermal: %{}})
      end)

    assert length(Regex.scan(~r/voxel_page_retire_blocked/, log)) == 2
  end
end
