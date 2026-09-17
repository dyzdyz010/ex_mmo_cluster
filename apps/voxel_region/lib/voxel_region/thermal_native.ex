defmodule VoxelRegion.ThermalNative do
  @moduledoc "全局系统功能：批量热数值 DirtyCpu 边界。输入与结果不可变，World 独占提交。"
  use Rustler, otp_app: :voxel_region, crate: "voxim_thermal"

  @doc "演进到步数耗尽或活动种子变化；返回实际步数、温度/HP/余能、供能和环境交换。"
  def batch(_nodes, _edges, _ambient, _exchange, _tolerance, _dt, _steps),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc "按真实体积及接触选择稳定步长；新热前沿立即返回，已激活域由 World 在提交批末收缩。"
  def advance(_nodes, _contacts, _ambient, _exchange, _tolerance, _duration),
    do: :erlang.nif_error(:nif_not_loaded)
end
