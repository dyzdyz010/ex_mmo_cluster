defmodule VoxelRegion.ThermalNative do
  @moduledoc "全局系统功能：批量热数值 DirtyCpu 边界。输入与结果不可变，World 独占提交。"
  use Rustler, otp_app: :voxel_region, crate: "voxim_thermal"

  @doc "演进到步数耗尽或活动种子变化；返回实际步数、温度/HP/余能、供能和环境交换。"
  def batch(_nodes, _edges, _ambient, _exchange, _tolerance, _dt, _steps),
    do: :erlang.nif_error(:nif_not_loaded)

  @doc "按原 50ms 分段推进焓/温度；新前沿、相变完成、点燃及共享 HP 事件交还 World。节点可附 {点燃温度或 nil, {焓, 体积, 相变温度, 总潜热, 单位体积热容, 是否液体} 或 nil, 共享 HP}；相变结果为 {温度, HP, 余能, 焓}，其他结果与纯数值输入保持原元组。"
  # 灰体辐射 {[{a, b, 有效面积}], [{节点, ε×对天空面积}]}：互见面按 σw(T_b⁴−T_a⁴) 反对称交换，
  # 对天空面按 σs(T_amb⁴−T⁴) 记入环境账；两表为空时与无辐射内核逐位相同。
  # ambient 为全局标量，或逐节点环境温度列表（节点所在气候区，与节点同序同长）。
  def advance(_nodes, _contacts, _ambient, _exchange, _tolerance, _duration, _radiation),
    do: :erlang.nif_error(:nif_not_loaded)
end
