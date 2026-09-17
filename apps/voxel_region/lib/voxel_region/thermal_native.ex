defmodule VoxelRegion.ThermalNative do
  @moduledoc "全局系统功能：批量热数值 DirtyCpu 边界。输入与结果不可变，World 独占提交。"
  use Rustler, otp_app: :voxel_region, crate: "voxim_thermal"

  @doc "演进到步数耗尽或活动种子变化；返回实际步数、温度/HP/余能、供能和环境交换。"
  def batch(_nodes, _edges, _ambient, _exchange, _tolerance, _dt, _steps),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc "按原 50ms 分段选择稳定子步并推进 duration；新前沿立即返回，段末点燃、相变或共享 HP 事件交还 World。节点可附 {点燃温度或 nil, {相变温度, 是否液体} 或 nil, 共享 HP} 控制元组；纯数值调用仍接受原节点元组。"
  def advance(_nodes, _contacts, _ambient, _exchange, _tolerance, _duration),
    do: :erlang.nif_error(:nif_not_loaded)
end
