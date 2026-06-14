# 对齐迁移 · 梯队 2 · step 2.7:场/体素本体迁入 ResourceArc<CellSim>(BND-1)

> 上层:[`phase-align-2-nif-fault-and-data-ownership.md`](./phase-align-2-nif-fault-and-data-ownership.md)
> 规范依据:BND-1(数据留 Rust)、PRIN-2、NIF-2/3/8、ANTI-3。
> 纪律:决策稿先行 → 逐子步 commit(`mix compile` 触发 rustler 重建 + `cargo test` + scene 回归)→
> 进度日志 → 不 push → 不留兼容。**关键:本步含一次不可避免的原子语义 flip(FieldLayer 值→句柄),
> 不能半迁移(no dual-path);故 flip 子步必须一次性全绿。**

## 目标

把局部场本体(`FieldLayer.values` 稀疏 map)从 Elixir 迁入 Rust `ResourceArc<CellSim>` 常驻,
消除"每 tick 把整层序列化进 field_kernel NIF、结果再序列化回 Elixir"的进出拷贝(BND-1/NIF-3/8)。
数据跨 tick 留在 Rust;kernel 计算原地双缓冲;Elixir 侧只持句柄 + 命令/事件 + 出口(wire/observe)读取。

## 现状锚点(2026-06-14 审计)

- `FieldLayer`(`field_layer.ex`):**不可变 Elixir struct**,`values: %{0..4095 => delta}` 稀疏 +
  `baseline`/`threshold`/`quantization`。函数 API:`new/get/get_delta/put/put_delta/active_cells/
  cell_count`(纯函数,`put` 返回新 layer)。内部多处 `%__MODULE__{values: values}` 模式匹配。
- `FieldRegion`(`field_region.ex`):`layers: %{field_type => FieldLayer.t()}`,`put_layer` 返回新 region。
- `field_kernel` NIF(`native/field_kernel/src/`):**无状态数学**,4 个 NIF——`diffuse_temperature`、
  `propagate_electric_potential`、`find_conduction_path`、`find_discharge_path`;数据每 tick `[{idx,val}]`
  向量进出。Elixir 绑定 `field_kernel.ex` + 包装 `field/native_backend.ex`。
- kernel 编排(`temperature_field.ex` 等):**读旧写新 stencil**——读当前 layer → NIF 算 delta → 应用回
  新 layer(`apply_delta_cells`)。依赖 FieldLayer 不可变(old/new 两份)。
- wire:`FieldCodec.encode_snapshot_payload` 每 tick 从 `layer` 经 `active_cells` 抽稀疏快照编 0x73。
- 测试:~12 个 field 测试文件经函数 API(get/put/active_cells)或 `.values` 构造/断言 layer。

## 关键决策(每项给推荐值)

### D2.7-1 CellSim 资源形态
**推荐**:`native/field_kernel` 新增 `#[rustler::resource_impl] CellSim`(`Mutex<CellSimState>`,
对齐 scene_ops `CharacterDataResource` 风格)。`CellSimState` 持**每 field_type 一个稠密/稀疏层**
(`HashMap<u16, f64>` delta + baseline/threshold/quantization),并持**双缓冲**(active + scratch)供
stencil 读旧写新。`ResourceArc<CellSim>` 由 Elixir FieldLayer/FieldRegion 持有(句柄)。

### D2.7-2 FieldLayer 从"值"变"句柄"(原子 flip)
**推荐**:`FieldLayer` defstruct 改持 `cell_sim: ResourceArc` + 元数据(field_type/baseline/
threshold/quantization),`values` 字段移除。**保持函数 API 签名不变**作为 seam:
- `get/get_delta/active_cells`:改走 NIF 从 CellSim 读(只读,返回值不变)。
- `put/put_delta`:**语义从"返回新不可变 layer"改为"原地改 CellSim 并返回同句柄 layer"**。
  调用方多写 `layer = FieldLayer.put(layer, ..)`——返回同句柄仍成立(rebind 无害),但**共享可变**:
  原"读旧 layer + 写新 layer"两份的 stencil 失效 → 见 D2.7-3。
- `new/1`:`ResourceArc::new(CellSim::new(field_type, ..))`。
**理由**:函数 API 作 seam 使大多数测试(用 get/put/active_cells)零改;直接 `.values` 访问的
~少数测试/lib 点(7 lib + 部分测试)改走 `active_cells`/新 `dump_values/1`。

### D2.7-3 stencil 读旧写新 → Rust 内部双缓冲
**推荐**:把"读旧写新"下沉进 NIF。`diffuse_temperature(cell_sim, candidates, thermal_props, ..)`
在 Rust 内:读 active 缓冲(旧)→ 算 → 写 scratch(新)→ swap。Elixir 侧 kernel 不再
`apply_delta_cells`(NIF 已原地完成),只传命令 + 取事件/摘要。`temperature_field.ex` 等 kernel
orchestration 改为:`NativeBackend.diffuse_temperature(layer.cell_sim, candidates, ..) → :ok`。
**理由**:消除 Elixir 侧双 layer + 进出序列化;双缓冲是 stencil 的本质,放 Rust 最自然。

### D2.7-4 wire / observe 出口读取
**推荐**:`FieldCodec.encode_snapshot_payload` 经 `FieldLayer.active_cells`(→ NIF 读 CellSim active 缓冲)
取稀疏快照。**出口方向(Rust→Elixir 读一次/ tick)保留**;BND-1 关切的是**计算热路径不进出**,出口
单向读可接受(数据仍常驻 Rust)。未来可把 wire 编码也下沉 NIF(本步不做)。

### D2.7-5 命令队列 / 事件回传 / 水位背压
**推荐 MVP**:命令 = 现有 NIF 调用(diffuse/propagate/find_*)直接作用 CellSim;事件 = NIF 返回的
结构化摘要(applied_count / effect 列表)。**显式命令队列 + 水位背压**(NIF-2)作为 2.7 收尾子步或
2.7-后续:先落地数据归属(最大 BND-1 价值),队列/背压增量补。**理由**:控制 flip 子步规模。

### D2.7-6 子步切分(控制原子 flip 风险)
- **2.7a(green,非 flip)**:Rust `CellSim` 资源 + `cell_sim_new/cell_sim_get/cell_sim_put/
  cell_sim_active_cells` NIF 脚手架 + Elixir 绑定;**不接 FieldLayer**(独立 cargo test + NIF 冒烟)。
  全绿,零行为变化。
- **2.7b(green,非 flip)**:把 4 个计算 NIF(diffuse/propagate/find_*)改为**接受 CellSim 句柄**
  的新 arity(旧 arity 暂留供过渡测试),Rust 内双缓冲;独立测试验证与旧路径数值等价。
- **2.7c(原子 flip,一次性全绿)**:FieldLayer 改持 cell_sim 句柄(D2.7-2),kernel orchestration
  改走句柄 NIF(D2.7-3),FieldCodec 经 active_cells 读(D2.7-4);删旧无状态 NIF arity(不留兼容);
  迁所有直接 `.values` 访问点 + 受影响测试。**此子步必须一次性全绿**(scene 全量 + field 全量)。
- **2.7d(增量)**:命令队列 + 水位背压(NIF-2,可并入或延后)。

> 排序理由:2.7a/2.7b 是可独立验证的 green 脚手架(零风险);2.7c 是不可分的原子 flip(集中风险,
> 一次做全);2.7d 增量。每 green 子步独立 commit;2.7c flip 不全绿不提交。

## 测试矩阵

- `mix compile`(rustler 重建 field_kernel,0 warning)+ `cargo test`(field_kernel crate)。
- field 目录全量(149)+ scene 全量(908,排除已知 observe-log flaky)。
- 数值等价:2.7b 新句柄 NIF 与旧向量 NIF 在同输入下 delta 位级/容差等价测试。
- flip 后:温度扩散 / 电势 / 导电 / 放电 端到端不变;wire 0x73 字节不变(parity)。

## 验收

- 场本体常驻 Rust `ResourceArc<CellSim>`,计算热路径不每 tick 进出序列化(BND-1/NIF-3/8)。
- FieldLayer 函数 API 作 seam,大多数调用方/测试零改;`.values` 直访点全迁。
- stencil 读旧写新下沉 Rust 双缓冲;Elixir 侧无双 layer 拷贝。
- wire/observe 出口经 active_cells 单向读 CellSim;0x73 parity 不变。
- 不留旧无状态 NIF arity(no dual-path);scene + field 全量 0 净回归。

## 2.7c flip 接线面与已发现的微妙点(供原子 pass 直接用)

flip 必须一次性翻完以下接线面(翻完才再次全绿,no dual-path):

- **FieldLayer**(根):defstruct `values` → `cell_sim`(ResourceArc)+ 元数据;`get/get_delta/put/
  put_delta/active_cells` 全改委托 cell_sim NIF(`cell_sim_get/put/active_cells`);`new/1`
  `cell_sim_new`。函数签名不变(seam)。
- **FieldRegion**:`get_layer` 现用 `Map.get_lazy(layers, type, fn -> new_layer end)`——**句柄态下
  同一 absent type 多次 get_layer 会得不同句柄、互不可见**!flip 时改为:absent 时 `new_layer`
  后**立即 put_layer 存回**(或 region 构造时为所有 field_types 预建句柄),保证每 type 唯一句柄。
  `put_layer` 存句柄态 layer。
- **temperature_field.ex**:`diffuse_layer` 改调 `NativeBackend` 的句柄版(走 `diffuse_temperature_sim`);
  删 `apply_delta_cells`(NIF 已原地 apply);`apply_source_points`/impulse 改原地 put。stencil 的
  old/new 双 layer 语义由 NIF 内部双缓冲承担,Elixir 不再持两份。
- **electric_field.ex**:`tick` 改调 `propagate_electric_potential_sim`(传 potential_sim + ionization_sim
  句柄);删 `apply_cells`/`clear_layer_in_aabb`(NIF 内 clear_aabb + put_absolute 已做)。
- **conduction/discharge kernel**:只读 ionization——改从 ionization 句柄 `active_cells` 取(或保留旧
  序列化读,因只读不 mutate,可后置)。
- **native_backend.ex**:温度/电势包装改句柄签名;旧向量包装删。
- **field_kernel.ex + lib.rs**:删旧 `diffuse_temperature`/`propagate_electric_potential` NIF(no dual-path)。
- **field_codec.ex**:`encode_snapshot_payload` 经 `FieldLayer.active_cells`(→ NIF)读,签名不变即可。
- **~12 测试**:用 `FieldLayer.put/get/active_cells`(函数 seam)的多数零改;直接 `.values` 访问点
  (7 lib + 少数测试)改 `active_cells`/新 `dump_values`;构造 FieldLayer 的测试随 new 改句柄。
- **不可变假设审计**:全仓搜 `layer = ` / `%FieldLayer{` / `.values` / `put_layer`,逐点确认
  rebind-同句柄语义成立(顺序 mutation 正确);特别警惕"留旧 layer 快照对比"的点(句柄态会被 mutate)。
- **native_backend backend 选择 + fallback 作废(2026-06-14 起手验证发现)**:`native_backend.ex` 现有
  `:native`/`:elixir` backend 选择 + NIF 不可用时 `fallback`(纯 Elixir `elixir_diffusion_cells`/
  `elixir_propagation` 计算)。**句柄态下 FieldLayer 本身就依赖 field_kernel NIF**(get/put/active_cells
  全是 NIF),故 NIF 变为**强制依赖**,`:elixir` backend + fallback 整套作废,flip 时一并删除(no
  dual-path)。这是 flip 的额外接线面,使其超出"FieldLayer + 2 kernel",还含 backend 选择/fallback
  架构拆除。**已起手验证:FieldLayer→句柄 + 委托 NIF 本体可行(FieldRegion.new 预建唯一句柄 +
  顺序 mutation 对齐),阻力点在 backend/fallback 拆除的弥散性,需全新 pass 一次完成。**
- **预存验证基线**:flip 前 field 163 / scene 908 全绿;flip 后须回到此基线方可 commit。

## 风险与缓解

- **原子 flip(2.7c)规模大**:用 2.7a/2.7b green 脚手架先把 Rust 侧验证透,flip 仅"接线 + 删旧 +
  迁测试",降低 flip 子步认知负荷。
- **stencil 数值漂移**:2.7b 数值等价测试守门;quantization(:integer 温度)边界单独测。
- **测试 churn**:函数 API seam 吸收大多数;`.values` 直访点(7 lib + 少数测试)用 `active_cells` /
  新 `dump_values` 替换。
- **wire parity**:flip 后跑 0x73 golden/parity,确保客户端 decoder 不受影响(web_client 主线)。

## 进度日志(时间倒序)

- 2026-06-14:**step 2.7b 电势部分(propagate_electric_potential_sim)完成 → 2.7b 收口**。lib.rs 加
  `propagate_electric_potential_sim(potential_sim, ionization_sim, sources, entries, aabb)`:读
  ionization_sim active(旧,= `active_cells(aabb,0)`)→ **复用** `electric_potential::propagate_electric_potential`
  (逐位等价)→ 写 potential_sim(merge `put_absolute`)+ ionization_sim(`clear_aabb` 再 put,= Elixir
  `clear_layer_in_aabb |> apply_cells`)。cell_sim.rs 加 `put_absolute`/`clear_aabb` 助手。两 sim 顺序锁
  (无同时双锁)。**数值等价测试**(句柄版 vs 旧 propagate + 两 FieldLayer apply,导电 storage 经
  ParticipantProjection→ConductionPathInput.conduction_entries,potential+ionization 两层逐位 `==`)。
  field 163 全绿。**两 mutating NIF 句柄版齐备 + 等价守门;2.7c 原子 flip 的计算底座就位。剩 2.7c flip、
  2.7d 队列背压。**

- 2026-06-14:**step 2.7b 温度部分(diffuse_temperature_sim 句柄 NIF)完成**。lib.rs 加
  `diffuse_temperature_sim(sim, candidates, aabb, thermal, ..)`:读 CellSim active(旧)→ **复用
  无状态 `temperature_diffusion::diffuse_temperature`**(逐位等价旧路径)→ 原地 put_delta apply
  (双缓冲:全算入 Vec 再 apply,邻居读全取旧态)。Elixir 绑定 + **数值等价测试**(句柄版 vs 旧
  diffuse_temperature + FieldLayer.apply,含相邻 candidates 验双缓冲,逐位 `==`)。field 162 全绿。
  **剩 2.7b 电势部分(propagate_electric_potential_sim,写两层)、2.7c 原子 flip、2.7d 队列背压。**

- 2026-06-14:**step 2.7a(Rust CellSim 脚手架,green 非-flip)完成**。`native/field_kernel` 新增
  `cell_sim.rs`:`FieldLayerSim`(`#[rustler::resource_impl]` + `Mutex<LayerState>`,稀疏 delta +
  baseline/threshold/quant,poison-safe lock 不 panic 越 FFI)。lib.rs 加 4 脚手架 NIF(`cell_sim_new`/
  `cell_sim_put`/`cell_sim_get`/`cell_sim_active_cells`,复用 `grid` 做 aabb 过滤,与 Elixir
  `Types.macro_index!`/`FieldLayer` 语义等价)+ `ok` atom。Elixir `FieldKernel` 加绑定 stub。
  **未接 FieldLayer,零行为变化**;scratch 双缓冲推迟到 2.7b。3 cargo 单测 + 6 Elixir NIF 冒烟全绿;
  field 161 全绿 0 回归。**剩 2.7b 句柄计算 NIF + 数值等价、2.7c 原子 flip、2.7d 队列背压。**

- 2026-06-14:设计稿落定。FieldLayer/FieldRegion/4 NIF/kernel orchestration/FieldCodec/~12 测试
  审计完成;确认核心难点=FieldLayer 值→句柄的原子 flip + stencil 下沉 Rust 双缓冲。拆 2.7a(Rust
  CellSim 脚手架)/2.7b(句柄 NIF + 数值等价)/2.7c(原子 flip)/2.7d(队列背压增量)。先执行 2.7a。
