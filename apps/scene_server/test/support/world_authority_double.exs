defmodule MmoTest.WorldAuthorityDouble do
  @moduledoc """
  只测试：Scene/Player 流送路径所见 `VoxelRegion.World` 公共调用协议的唯一替身写法。

  替代范围：`VoxelRegion.World.PageLoad.call/3` 的 `{:page_request, ref, message}` 信封与超时取消
  `{:page_cancel, ref}`，以及 `World.prepare` 的准备作用域 `{:prepare, keys}` →
  `{token, source, source_state, missing}`、作用域内带 token 的 `{:canonical_snapshot, ..., token}`，
  以及结束时 `{:release_preparation, token, caller}`。
  替身声明无缺失区域（`missing = []`），不证明 World 的装页、准备 owner 或液体接纳；
  它把自身模块作为 source 返回，因此使用方须提供 `ensure/3`。

  使用方以 `world_call/3` 定义各自的场景数据（canonical 快照等）；信封与准备协议只在本模块维护。
  """

  defmacro __using__(_opts) do
    quote do
      use GenServer

      @impl true
      def handle_call({:page_request, _request, message}, from, state),
        do: handle_call(message, from, state)

      def handle_call({:prepare, _keys}, _from, state),
        do: {:reply, {make_ref(), __MODULE__, nil, []}, state}

      def handle_call({:adopt_liquid, _regions}, _from, state), do: {:reply, :ok, state}

      # 准备作用域内的快照请求携带 token（World 在接纳时释放该准备）；替身无准备状态，按原快照请求交给使用方。
      def handle_call({:canonical_snapshot, box, subscriber, ref, include_chunks, _token}, from, state),
        do: handle_call({:canonical_snapshot, box, subscriber, ref, include_chunks}, from, state)

      def handle_call(message, from, state), do: world_call(message, from, state)

      @impl true
      def handle_cast({:release_preparation, _token, _caller}, state), do: {:noreply, state}
      def handle_cast({:page_cancel, _request}, state), do: {:noreply, state}
    end
  end
end
