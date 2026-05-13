# Phase 5.C: 第一批 attribute / tag catalog seed + in-memory catalog runtime — 设计草案

状态：设计稿，等用户复核 C-1..C-8 决策点
日期：2026-05-13
归属：goal `voxel-authoritative-and-field-minimum` Phase 5.C

姊妹草案：
- `2026-05-13-phase5a-attribute-catalog-snapshot.md`（A-1..A-6 已 approve）
- `2026-05-13-phase5b` 实施（无独立草案，与 5.A 对称）

真相源：
- `docs/2026-05-07-体素服务器权威化架构进度检查.md` §"目标三缺口 A" / §"目标三缺口 B"（第一批 typed attribute 字段集）
- Phase 5.A `attribute_catalog_snapshot.ex` / `attribute_definition.ex`（commit `8b61c60`）
- Phase 5.B `tag_catalog_snapshot.ex` / `tag_definition.ex`（commit `e635196`）
- Phase 1.2 `attribute_set.ex` / `attribute_entry.ex`（chunk-local AttributeSet pool，section 0x04）

---

## 1. 目标

把 Phase 5.A/5.B 的 catalog wire 类型从"空壳"升级为"含第一批真实定义"：

1. **定义 5 个 attribute**：`temperature / humidity / moisture / density / thermal_conductivity`（主线 §"目标三缺口 A" 字段集）
2. **定义第一批 tag**（C-8 决策）：常见的物理状态 tag
3. **seed 文件**：将定义写入 `priv/catalogs/`，启动时加载
4. **in-memory runtime**：`AttributeCatalog` / `TagCatalog` GenServer + ETS，支持 lookup_by_id / lookup_by_name
5. **`Storage.put_attribute_for_cell` 高层 API**：按 catalog name 设置 attribute（不强制 caller 知道 id）

**Phase 5.C 不做**（Phase 5.C.2 / 5.D / 5.E / 5.F 工作）：
- DataService 持久化（catalog 跨进程重启恢复）—— Phase 5.C.2
- 五层 merge_rule 实施（material default / normal block override / refined micro override / object-part / environment summary）—— Phase 5.D
- 模拟器 / 规则帧—— Phase 5.E/F
- 客户端 catalog 消费（web_client TS decoder for opcode 0x6E/0x6D + UI 渲染）—— 推到 Phase 5.D/E

---

## 2. 第一批 attribute 定义

按主线 §"目标三缺口 A" 推荐 + Phase 5.A A-3..A-5 决策：

| id | name | unit | value_type | default | min | max | merge_rule | dynamic |
|---|---|---|---|---|---|---|---|---|
| 1 | `temperature` | `°C` | fixed32 (Q16.16) | 20.0 (raw=1310720) | -273.15 (raw=-17904824) | 5000.0 (raw=327680000) | add_delta | 1 |
| 2 | `humidity` | `%` | fixed32 (Q16.16) | 50.0 (raw=3276800) | 0.0 (raw=0) | 100.0 (raw=6553600) | add_delta | 1 |
| 3 | `moisture` | `kg/m³` | fixed32 (Q16.16) | 0.0 (raw=0) | 0.0 | 1000.0 (raw=65536000) | add_delta | 1 |
| 4 | `density` | `kg/m³` | fixed32 (Q16.16) | 1.0 (raw=65536) | 0.001 (raw=66) | 20000.0 (raw=1310720000) | material_default | 0 |
| 5 | `thermal_conductivity` | `W/(m·K)` | fixed32 (Q16.16) | 0.1 (raw=6554) | 0.0 (raw=0) | 500.0 (raw=32768000) | material_default | 0 |

> **决策点 C-1**：catalog id 分配方式？
> - (a) **顺序数字 1..5**（推荐，简单）
> - (b) `Hash(name)` —— 自动避免重复，但 wire size 不变
> - (c) 固定预留区间：1..1000 = builtin / 1001..= 用户自定义

> **决策点 C-2**：fixed32 Q16.16 数值范围？
> - (a) **按上表**（推荐，物理常识范围 + 留 4×安全余量）
> - (b) 全 i32 范围（min=INT32_MIN/65536 max=INT32_MAX/65536）—— 不强制语义但允许极端值

> **决策点 C-3**：default value 是否绝对值还是相对值？
> - (a) **绝对值**（推荐，物理量直观）：temperature default=20.0°C
> - (b) 相对环境值：temperature default=0 表示"等同 MacroEnvironmentSummary.current_temperature"
>
> 选 (a) 时，merge_rule add_delta 的语义清晰：当 cell 没有 attribute_set_ref（或 ref 指向的 set 不含 temperature）时，cell 显示 default=20.0；当 cell 的 attribute_set 含 temperature delta=+5 时，最终 effective = 20.0 + 5.0 = 25.0。

---

## 3. 第一批 tag 定义

主线进度文档未明确给"第一批 tag"清单。Phase 5.C 提议 8 个基础 tag：

| id | name | 用途（Phase 5+ 描述） |
|---|---|---|
| 1 | `flammable` | 标记可燃 cell（Phase 6 燃烧机制） |
| 2 | `conductive` | 标记导电 cell（Phase 6 电场） |
| 3 | `wet` | 标记湿润 cell（影响导电 / 燃烧） |
| 4 | `frozen` | 标记冻结 cell |
| 5 | `burning` | 标记正在燃烧（runtime state） |
| 6 | `magical` | 标记被魔法影响的 cell |
| 7 | `structural` | 标记结构性 cell（影响破坏行为） |
| 8 | `transparent` | 标记可见但不阻挡 cell |

> **决策点 C-8**：第一批 tag 清单？
> - (a) **上表 8 个**（推荐，覆盖 Phase 6 magic kernel 直接需要的物理 tag）
> - (b) 仅 3 个：flammable / conductive / wet（最小集，Phase 6 实施时再扩）
> - (c) 上表 8 个 + 用户补充

---

## 4. seed 文件格式

新建 `apps/scene_server/priv/catalogs/attribute_catalog_v1.exs`：

```elixir
%{
  catalog_version: 1,
  definitions: [
    %{
      id: 1,
      name: "temperature",
      unit: "°C",
      value_type: :fixed32,
      default_value: 1_310_720,         # 20.0 in Q16.16
      min_value: -17_904_824,           # -273.15
      max_value: 327_680_000,           # 5000.0
      merge_rule: :add_delta,
      dynamic: true
    },
    # ... 其他 4 个 attribute
  ]
}
```

新建 `apps/scene_server/priv/catalogs/tag_catalog_v1.exs`：

```elixir
%{
  catalog_version: 1,
  definitions: [
    %{id: 1, name: "flammable"},
    %{id: 2, name: "conductive"},
    # ... 其他 6 个 tag
  ]
}
```

> **决策点 C-4**：seed 文件格式？
> - (a) **`.exs` Elixir 字面量**（推荐，与项目其他 seed 一致，type-safe load）
> - (b) JSON：跨工具支持但需要 string→atom 转换
> - (c) Erlang term binary：紧凑但不易读

---

## 5. in-memory catalog runtime

### 5.1 `SceneServer.Voxel.AttributeCatalog` GenServer

```elixir
defmodule SceneServer.Voxel.AttributeCatalog do
  use GenServer
  
  # ETS table: attribute_id (int) → %AttributeDefinition{}
  # 第二 ETS / hash: attribute_name (string) → attribute_id
  
  # API:
  # - lookup_by_id(id) :: {:ok, %AttributeDefinition{}} | {:error, :not_found}
  # - lookup_by_name(name) :: {:ok, id, %AttributeDefinition{}} | {:error, :not_found}
  # - current_snapshot() :: %AttributeCatalogSnapshot{}
  # - catalog_version() :: u64
  
  # 启动 init/1: 加载 priv/catalogs/attribute_catalog_v1.exs → 校验 → 填 ETS
end
```

### 5.2 `SceneServer.Voxel.TagCatalog` GenServer（对称结构）

> **决策点 C-5**：catalog runtime 用 GenServer + ETS 还是纯 ETS public table?
> - (a) **GenServer 持 private ETS**（推荐，唯一 writer，避免 race）
> - (b) Public ETS table + 模块函数 wrapper（更快但无 update protection）

> **决策点 C-6**：catalog 加载时机？
> - (a) **OTP supervision 启动时 `init/1`**（推荐，确保上层依赖时 catalog 已就绪）
> - (b) Lazy load on first lookup
> - (c) Application start hook

### 5.3 `Storage.put_attribute_for_cell` 高层 API

```elixir
def put_attribute_for_cell(storage, macro_index, attr_name_or_id, value)
# 内部：
#   1. AttributeCatalog.lookup → 拿到 id + value_type + min/max
#   2. 校验 value 在 [min, max]
#   3. 构造 %AttributeEntry{key_id: id, value_type: ..., value: ...}
#   4. 构造或扩展 %AttributeSet{entries: [...]}
#   5. Storage.intern_attribute_set/2 拿到 ref
#   6. 更新 cell 的 attribute_set_ref
```

> **决策点 C-7**：是否在 Phase 5.C 引入"按 attr_name 写入"的高层 API？
> - (a) **是**（推荐，简化测试 / Phase 5.D / Phase 5.F 等下游调用方）
> - (b) 否，下游 caller 必须先 `AttributeCatalog.lookup_by_name` 拿到 id 再用 Phase 1.2 低层 API

---

## 6. Elixir 模块结构

```text
apps/scene_server/
├── priv/catalogs/
│   ├── attribute_catalog_v1.exs        # seed 文件
│   └── tag_catalog_v1.exs              # seed 文件
└── lib/scene_server/voxel/
    ├── attribute_catalog.ex            # GenServer + ETS (lookup + current_snapshot)
    └── tag_catalog.ex                  # GenServer + ETS（对称）
```

加挂入 `apps/scene_server/lib/scene_server/application.ex` 监督树。

---

## 7. Test plan（TDD）

新建 `apps/scene_server/test/scene_server/voxel/attribute_catalog_test.exs`：

1. seed 加载：5 个 attribute 全部加载成功
2. `lookup_by_id` / `lookup_by_name` 命中
3. `lookup_by_id(999)` 未命中返回 `:not_found`
4. `current_snapshot` 与 seed 一致
5. `Storage.put_attribute_for_cell("temperature", 25.0)` 写入 → cell.attribute_set_ref ≠ 0 → 反查得到 25.0
6. value 超出 [min, max] raise

新建 `apps/scene_server/test/scene_server/voxel/tag_catalog_test.exs`：
- 对称的 8 个 tag 加载 + lookup 测试

---

## 8. 实施顺序

依赖：5.A + 5.B 已落地。

1. **C-1..C-8 决策**：用户复核
2. 新建 seed 文件（priv/catalogs/）
3. 新建 `attribute_catalog.ex` + `tag_catalog.ex` GenServer + ETS
4. 新建 catalog 测试
5. 改 `storage.ex` 加 `put_attribute_for_cell` 高层 API
6. 改 `application.ex` 监督树
7. 跑测试（520 baseline 不回归）
8. 同步文档（README + 主线进度文档）
9. commit `phase5c: first batch attribute/tag catalog seed + in-memory runtime`

---

## 9. 风险

- **catalog id 一旦写入 wire 即冻结**：Phase 5.C 决定 temperature=id 1，wire 一旦有 attribute_set 引用 id 1 = temperature，未来不能改。
- **seed 文件 version=1，未来升级**：当 attribute schema 演进时通过 Phase 1.4 CatalogPatch envelope 发出增量；catalog_version 单调。
- **Catalog 持久化推到 5.C.2**：本 commit 内存 catalog 每次启动重建。集群多节点必须 seed 一致（priv 文件本地相同即可）。5.C.2 持久化将让 catalog 能从 DataService 恢复（支持 hot-reload）。
- **`Storage.put_attribute_for_cell` 阻断式 GenServer call**：每次写 attribute 都 call AttributeCatalog GenServer。性能上预期可接受（catalog 不在 hot path），如果出现 hot path 性能问题可改 ETS public read。
