defmodule VoxelRegion.ThermalNative do
  @moduledoc "全局系统功能：批量热数值 DirtyCpu 边界。输入与结果不可变，World 独占提交；常驻的只有热域拓扑派生缓存。"
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

  @doc "新的热域拓扑资源（`VoxelRegion.ThermalDomain` 持有的可丢弃派生缓存）。"
  def domain_new, do: :erlang.nif_error(:nif_not_loaded)

  @doc "写入变化节点的接触 `{槽位, [{伙伴槽位, 导热, 本端发出?}]}`、移除槽位、替换视线 `{槽位, [{伙伴槽位或 nil（天空）, 面积}]}`。"
  def domain_put(_domain, _nodes, _removed, _sights, _reset_sights), do: :erlang.nif_error(:nif_not_loaded)

  @doc "按本轮节点次序（槽位列表，决定内核下标）与发边次序重建内核边与辐射项；返回 `{边数, 互见半对数, 对天空面数}`。"
  def domain_index(_domain, _order, _emission, _emissivity), do: :erlang.nif_error(:nif_not_loaded)

  @doc "上次 `domain_index/3` 生成的 `{内核边, {互见半对, 对天空}}`（与 `ThermalGeometry.contacts/1`、`ThermalRadiation.terms/4` 核对用）。"
  def domain_terms(_domain), do: :erlang.nif_error(:nif_not_loaded)

  @doc "槽位在本轮节点次序中的内核下标（不在节点集内为 nil）。"
  def domain_positions(_domain, _slots), do: :erlang.nif_error(:nif_not_loaded)

  @doc "装入节点 `[{槽位, 静态量, 动态量}]`（`ThermalRecord.static/3` 的宏格已换成编号并附足迹宏格编号，`ThermalRecord.dynamic/4`）。"
  def domain_load(_domain, _nodes), do: :erlang.nif_error(:nif_not_loaded)

  @doc "按当前记录替换节点动态量 `[{槽位, 动态量}]`；`only_clean` 时跳过有待写回变化的节点。"
  def domain_reload(_domain, _nodes, _only_clean), do: :erlang.nif_error(:nif_not_loaded)

  @doc "热格集合（宏格编号列表）。"
  def domain_hot(_domain, _cells), do: :erlang.nif_error(:nif_not_loaded)

  @doc """
  一个内核步：世界节点取自常驻工作副本；外部节点 `extra` 的接触 `extra_contacts` 追加在世界边之后，
  外部辐射项 `prefix` 排在世界辐射项之前。返回 `{时长, 供能, 环境交换, 耗燃, 外部节点结果, 新热格, 点燃候选,
  共享损失, 熄灭, 变化节点, 有限源余量, 所请求下标的温度}`。
  """
  def domain_step(_domain, _duration, _exchange, _tolerance, _epsilon, _sources, _powers, _extra, _extra_contacts,
        _extra_ambient, _prefix, _requested), do: :erlang.nif_error(:nif_not_loaded)

  @doc "取走自上次取回以来变化的节点 `[{槽位, 动态量}]`。"
  def domain_flush(_domain), do: :erlang.nif_error(:nif_not_loaded)

  @doc "节点当前动态量（不在热域内为 nil），不改变待写回标记。"
  def domain_values(_domain, _slots), do: :erlang.nif_error(:nif_not_loaded)
end
