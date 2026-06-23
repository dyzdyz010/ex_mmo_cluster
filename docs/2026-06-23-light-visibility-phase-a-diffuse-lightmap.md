# 光 → 可见度 · Phase A:弥漫光场 + 逐 cell 亮度调制(决策稿)

- 日期:2026-06-23
- 状态:**执行中**(决策稿先行;用户已拍板范围)
- 关联:`docs/2026-06-23-light-as-orthogonal-system.md`(光*场*正交系统 as-built:`:light`/`:light_color`
  权威场已建成)、玩法目标序列 [[gameplay-roadmap-and-construction-scope]](力学 ✅ → **光场(本稿)** → loop+zone → 建设)。
- 触发:用户 /goal「光决定可见度(暗处藏身/亮处暴露;洞穴要带光源)」。

## 0. 用户拍板的范围(2026-06-23)

- **分阶段**:**Phase A = 渲染 + 弥漫光场(本稿)**;Phase B = 服务端权威隐身(影响 AOI/复制,后续另立稿)。
- **阳光模型 = 静态天光 + 环境地板**:自顶向下静态天光(露天满亮、被遮/地下逐格衰减变暗)+ 一个低环境地板避免纯黑。**无昼夜循环**。

## 1. 目标(Phase A)

让**世界有明暗**:露天地表亮、洞穴/室内暗、光源(余烬/灯/熔岩…)照亮周围。客户端**逐 cell 光照调制场景亮度**,替换当前「固定全局环境光(Atmosphere IBL)把洞穴照得和地表一样亮」的错误观感。**不**改 gameplay 可见度/AOI(那是 Phase B)。

## 2. 关键架构事实(recon 结论,带出处)

- 客户端实时光照 = `DirectionalLight(RAW_SUNLIGHT)` + `Atmosphere` + `AtmosphereEnvironmentMapLight`(IBL 环境光),**全局均匀**,无逐 cell 调制(`app/mod.rs:398-421`)。**无 `AmbientLight`**(仅测试 harness 有)。「固定环境光」实指这套 IBL——它把洞穴填亮。
- chunk mesh 已带逐顶点 `ATTRIBUTE_COLOR`(材料色),材质 `StandardMaterial { base_color: WHITE, base_color_texture: mosaic, ... }`(**非 unlit**,顶点色调制反照率)(`chunk_render.rs:92-110, 391-406`)。→ **逐 cell 光照可烤进顶点色**(把光因子乘进材料色),无需新 mesh 属性。
- `:light`/`:light_color` 场当前是**独立叠加层**(发光 cell 处半透标记 cube),**不照亮地形本身**(`field_view.rs:399-434`)。
- 客户端持有整 chunk 占据(`AuthorityChunk.cells: Vec<CellState>`,O(1) 按 index 查 solid/empty)→ **天光可纯客户端从权威几何算**(`authority.rs:30-50`、`mesher.rs:264 occupies`)。
- chunk 脏时 `render_dirty_chunks` 调 `chunk_render_mesh` 重网格(`chunk_render.rs:168-213`,预算 8/帧)。

## 3. 设计

### 3.1 天光在客户端算(Phase A 决策,记档待用户否决)

Phase A 是**渲染**,**天光纯客户端从服务端权威几何派生**(自顶向下列高度图 + 衰减):
- **零 wire 成本**(不新增场下发);**确定**(权威几何的确定函数);**便宜**(O(chunk))。
- 服务端「补阳光」体现为:它下发的**权威几何**决定 sky 暴露;客户端据此算天光。**服务端权威天光/可见度计算**(隐身判定要的)是 **Phase B**——那时才需服务端自己算光场。
- 取舍:Phase A 不把天光做成下发的服务端场,因为渲染只需结果、客户端有权威几何、字节级一致由几何保证。若用户要 Phase A 即服务端算天光,可改(代价:dense 场 wire 或列高度图下发)。

### 3.2 天光 `Skylight`(纯计算,Layer-1 可测)

每 (x,z) 列:自 chunk 顶向下,遇第一个 solid/occupied cell 前的 cell = **满天光**(露天);其下逐格按遮挡/深度衰减;跌破地板取**环境地板**。v1 用列高度图近似(同 Minecraft 早期 skylight 思路):
- `sky[x][y][z] = 1.0`,若该列 y 之上无 occupied cell(露天);
- 一旦被遮:进入「室内/地下」,按离遮挡顶的深度乘衰减(每格 ×k,如 0.78)直到 floor;
- 全空 cell 也参与(空气透光);occupied cell 自身取其上表面光(渲染时只有暴露面着色)。
- **跨 chunk**:v1 chunk-local 近似(列只看本 chunk 顶;上方邻 chunk 的遮挡留 v2,同力学跨 chunk 折中)。

形式属性(单测守):① 露天列全满;② 单遮挡下方单调衰减;③ 深处 = floor;④ 确定(无随机);⑤ 全空 chunk 全满。

### 3.3 块光融合 + 烤进 mesh(逐 cell lightmap)

重网格时,每个**暴露面顶点**的光因子 =
```
light = max(skylight_at_cell, block_light_at_cell, ambient_floor)
```
- `skylight_at_cell`:§3.2。
- `block_light_at_cell`:采样服务端 `:light` 场(该 chunk 的最近 region 快照),归一 0..1。**这让洞穴里的火把真照亮周围地形**(否则降了全局环境光后,洞穴即便有火把也只剩叠加层的发光标记、墙仍黑)。
- `ambient_floor`:低保(如 0.12),避免纯黑不可辨。
把 `material_color × light` 烤进顶点 `ATTRIBUTE_COLOR`(乘法压暗)。

**mesh × field 耦合**:重网格需读该 chunk 的 `:light` 场;故**块光场变更也要触发该 chunk 重网格**(在 field 脏时标 chunk 脏)。无 field 时 block_light=0,退化为纯天光(安全)。

### 3.4 全局环境光下调(让洞穴真黑)

把 `AtmosphereEnvironmentMapLight` / IBL 环境贡献**调低**(或加一个低 `AmbientLight` 兜底),使**未被天光/块光照到的面**(洞穴深处)真的暗下来;`DirectionalLight` 太阳保留给露天面形体感。烤进顶点色的 light 成为主照明项。具体强度按 Layer-3 像素反馈调(洞穴 cell 显著暗于地表 cell、火把邻近 cell 显著亮于无光洞穴 cell)。

### 3.5 不动的部分

- `:light_color` 彩色叠加层、photo_sensor 反应、力学/化学等**不动**(Phase A 只加「地形受光场调制」这一渲染层)。
- 块光的**彩色**烤进地形留 v2(Phase A 先用强度);现彩色仍由叠加层呈现。

## 4. 效率 / MMO 适配

- 天光 O(chunk),仅重网格时算(事件驱动,同现重网格预算 8/帧)。零新增 wire。
- 块光复用现成稀疏 `:light` 场(无新流量)。
- lightmap 烤进现有顶点色属性(无新 GPU 资源、无新 draw)。
- 跨 chunk 天光遮挡 v1 近似(留 v2)。

## 5. v1 局限(记档)

① 天光 chunk-local(不跨 chunk 遮挡);② 静态(无昼夜);③ 块光烤进地形用强度(彩色留 v2);④ 纯客户端天光(服务端权威天光/可见度 = Phase B);⑤ 列高度图近似(非逐 cell 光传播,无绕角软阴影)。

## 6. 逐 step 计划

1. **step1**:决策稿(本文件)。
2. **step2**:`Skylight` 纯计算模块(列高度图天光)+ 形式属性单测(5 条)。
3. **step3**:lightmap 烤进 mesh——mesher 产逐顶点光因子(天光 + 块光采样 + 地板),烤进顶点色;chunk_render 接 `:light` 场采样 + field 脏触发 chunk 重网格。单测(被遮 cell 顶点色暗于露天)。
4. **step4**:全局环境光下调 + 调参(洞穴暗、地表亮、火把照亮);非 layer3 build 绿。
5. **step5**:Layer-3 像素 showcase + 断言(洞穴 cell 暗于地表 cell;火把邻近亮于无光洞穴;PNG)。

每 step 一 commit(co-author `Claude Opus 4.8 (1M context)`)。

## 7. 测试策略

- 单元:`Skylight` 5 不变量(露天满/遮挡衰减/深处地板/确定/全空满);mesh lightmap(被遮顶点暗)。
- Layer-3 像素(RTX 5060,`--test-threads=1`):洞穴 vs 地表亮度、火把照亮洞穴、showcase PNG。
- 回归:bevy 非 layer3 全套 + layer3 全套;`--voxel-headless` boot exit 0。

## 8. 后续(Phase B / 增量,本稿外)

服务端权威天光/可见度(暗处对他人隐身、AOI/复制按光照裁剪)——反作弊级,另立稿。块光彩色烤进地形;跨 chunk 天光;昼夜循环。
