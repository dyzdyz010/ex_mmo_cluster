defmodule VoxelRegion.TestSupport.NullLog do
  @moduledoc """
  只测试：不保留日志或页的空 `VoxelRegion.OverlayLog` 后端。

  替代范围：持久化与重启恢复；使用它的测试不得重启 World 或断言持久化语义。
  分页查询按空存储合同返回（无已发布页、无可定位旧身份），新区域仍由场景的正常 Source 供应。
  声明 behaviour，后端回调变化时编译期即暴露替身过期。
  """
  @behaviour VoxelRegion.OverlayLog

  @impl true
  def open(dir, _cv), do: dir
  @impl true
  def replay(_), do: []
  @impl true
  def append(_, _), do: :ok
  @impl true
  def checkpoint(_, _), do: :ok
  @impl true
  def prefix(_), do: nil
  @impl true
  def clear_unpublished(_, _), do: :ok
  @impl true
  def write_pages(_, _, _), do: :ok
  @impl true
  def publish(_, _, _, _), do: :ok
  @impl true
  def load(_), do: %{prefix: nil}
  @impl true
  def load_head(_, _), do: %{prefix: nil}
  @impl true
  def read_pages(_, _, _), do: %{prefix: nil, rows: []}
  @impl true
  def locate(_, _), do: %{}
  @impl true
  def page_keys(_), do: []
  @impl true
  def collect(_, _, _), do: 0
end
