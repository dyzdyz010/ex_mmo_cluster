# Voxia Far Render Governance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. The current session does not authorize subagents. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 Voxia 唯一 `production_all_features` 根中消除远景静止/移动闪烁，建立清晰自然的单主光体素层次，并在 RTX 4060/5060 级 1080p 默认档保留 120 FPS 设计余量。

**Architecture:** 保持 canonical XYZ、surface artifact 和 presentation 单向数据流；新增只读渲染诊断、确定性表面光照派生、环境/阴影/质量策略三个正交边界。hidden component 仍分帧创建与注册，但 replacement 在目标位置保持不可见，最终在同一 GameThread 帧完成旧 hide / 新 show；远景正确性不依赖全距离 Lumen/HWRT/VSM。

**Tech Stack:** Unreal Engine 5.8、C++20、`UDynamicMeshComponent` / GeometryFramework、DefaultLit UE Material、VSM、TSR、Node.js 内置模块、UE Automation、Voxia stdio CLI / `.demo/observe/`。

## Global Constraints

- 只开发 `clients/Voxia`；`clients/web_client` 与 `clients/bevy_client` 不读取、不修改、不验证。
- wire、opcode、body、服务端 app、confirmed truth、baseline/H gate 与完整 XYZ 空间合同保持不变。
- 默认 near 为 `3×3×3 tiles = 27 tiles = 9261 chunks`；不得引入 XZ column、有限 Y band 或 `Y=0`。
- 只保留一个 `production_all_features` / `AVoxiaUnifiedVoxelWorldActor` 正式根；quality 是同根策略，不是新 GameMode、地图或 actor 根。
- 默认 `performance_natural`：RTX 4060/5060 级、1920×1080、TSR 77%；`frame p95 <= 8.33ms`、`p99 <= 11.11ms`、`GameThread p95 <= 3.5ms`、GPU p95 `<= 6.0ms`。
- 远景相对同根 debug-only far-hidden 基线的 GPU p95 增量 `<= 2.0ms`；单帧 visibility commit 的 GameThread 增量 `<= 1.0ms`。
- 中午、晨昏、夜晚三个锚点及连续太阳移动必须共用同一 artifact/mesh；本轮不实现天气。
- 不恢复 raymarch，不用雾、非互补 dither 或屏幕噪声隐藏 gap/seam，不把 Lumen/HWRT 当作远景正确性依赖。
- 所有新增 C++ 注释使用中文；稳定新目录必须有中文 `README.md`。
- 每个 RG 阶段先红测试、后最小实现、再 fresh 验证和独立提交；若单变量假设未被证实，停止该修复并返回 RG0，不叠加猜测。

---

## File Structure

### 新增边界

- `clients/Voxia/Source/Voxia/Rendering/README.md`：现役远景渲染策略、质量档、诊断与所有权关系。
- `clients/Voxia/Source/Voxia/Rendering/VoxiaFarRenderDiagnostics.h/.cpp`：只读采样 UE CVar、far DynamicMesh flags 与环境状态，输出稳定 JSON。
- `clients/Voxia/Source/Voxia/Rendering/VoxiaFarRenderDiagnosticsAutomationTest.cpp`：诊断 schema、缺世界和 far component 汇总回归。
- `clients/Voxia/Source/Voxia/Rendering/VoxiaEnvironmentLightingPolicy.h/.cpp`：中午/晨昏/夜晚锚点、单主光、天空/雾/曝光的纯策略值。
- `clients/Voxia/Source/Voxia/Rendering/VoxiaEnvironmentLightingPolicyAutomationTest.cpp`：锚点、插值与“太阳移动不改变 artifact identity”回归。
- `clients/Voxia/Source/Voxia/Rendering/VoxiaEnvironmentLightingComponent.h/.cpp`：自维护锚点/sweep 活性并拥有环境组件引用的 GameMode component。
- `clients/Voxia/Source/Voxia/Rendering/VoxiaEnvironmentLightingComponentAutomationTest.cpp`：锚点切换、sweep 活性和无逐帧 sky recapture 回归。
- `clients/Voxia/Source/Voxia/Rendering/VoxiaFarShadowPolicy.h/.cpp`：只根据 patch nearest ring 与冻结 max ring 决定投影。
- `clients/Voxia/Source/Voxia/Rendering/VoxiaFarRenderQualityPolicy.h/.cpp`：`performance_natural` / `quality_natural` 的唯一策略表。
- `clients/Voxia/Source/Voxia/Rendering/VoxiaFarRenderQualityPolicyAutomationTest.cpp`：默认档、无效配置和 shadow ring 合同。
- `clients/Voxia/Source/Voxia/FarField/VoxiaVoxelSurfaceLightingArtifact.h/.cpp`：从 resolved occupancy sampler 派生 per-corner AO / local sky visibility。
- `clients/Voxia/Source/Voxia/FarField/VoxiaVoxelSurfaceLightingArtifactAutomationTest.cpp`：角点遮蔽、missing、跨页与确定性测试。
- `clients/Voxia/Source/Voxia/Presentation/VoxiaVoxelPresentationVisibilityPlan.h/.cpp`：旧/新 patch 列表到单帧 visibility operation 的纯计划。
- `clients/Voxia/Source/Voxia/Presentation/VoxiaVoxelPresentationVisibilityPlanAutomationTest.cpp`：retained/replaced/removed 与全量 teleport 计划回归。
- `clients/Voxia/scripts/voxia_far_render_metrics.js`：无第三方依赖的解码后帧序列亮度/边缘时间差计算。
- `clients/Voxia/scripts/voxia_far_render_metrics.test.js`：纯像素 fixture 测试。
- `clients/Voxia/scripts/run_far_render_governance.js`：唯一根 RG 路线、A/B、性能与产物索引。

### 主要修改点

- `clients/Voxia/Source/Voxia/Debug/VoxiaDebugCommandContract.cpp`：追加 `far_render_state`、`far_lighting_anchor`、`far_lighting_sweep`。
- `clients/Voxia/Source/Voxia/Debug/VoxiaDebugCommandRouterAutomationTest.cpp`：更新 production 命令计数与领域断言。
- `clients/Voxia/Source/Voxia/Debug/VoxiaDebugCliSubsystem.h/.cpp`：frame ring 追加 RT/RHI/GPU；EnginePerf handler 只转发 Rendering façade。
- `clients/Voxia/Source/Voxia/Gameplay/VoxiaVoxelPresentationSceneHost.h/.cpp`：目标位置 hidden stage、单帧 visibility commit、真实 fence 后退休。
- `clients/Voxia/Source/Voxia/Gameplay/VoxiaVoxelPresentationResourceSetAutomationTest.cpp`：原子提交与旧 live 保留回归。
- `clients/Voxia/Source/Voxia/Voxel/VoxiaFarMeshData.h/.cpp`：compact mesh 新增每顶点 AO/sky 逻辑通道并加固结构校验。
- `clients/Voxia/Source/Voxia/FarField/VoxiaFarFieldDynamicMesh.h/.cpp`：UV0 读取现有 rebased face coordinate；UV1 携带 lighting channels；提升算法版本。
- `clients/Voxia/Source/Voxia/FarField/VoxiaVoxelShellResolvedSurfaceStager.h/.cpp`：surface 与 lighting artifact 同批全有或全无发布、复用和统计。
- `clients/Voxia/Source/Voxia/FarField/VoxiaVoxelShellArtifactReuse.h`：lighting artifact immutable ref/cache fingerprint。
- `clients/Voxia/Source/Voxia/Gameplay/VoxiaCanonicalVoxelShellSceneBuilder.h/.cpp`：传递 lighting artifact、ring/shadow tier，并把 Pure3D UV 从 `ConstantCenter` 切回 `Source`。
- `clients/Voxia/Source/Voxia/Gameplay/VoxiaClientRuntimeConfig.h/.cpp`：冻结 `-VoxiaFarRenderQuality=`，无效值显式失败。
- `clients/Voxia/Source/Voxia/Gameplay/VoxiaClientGameMode.h/.cpp`：组合环境策略；删除四盏补光；不再散读新增命令行。
- `clients/Voxia/Source/Voxia/FarField/VoxiaFarFieldMeshComponentDesc.h/.cpp`：按 patch shadow policy 应用 cast flag；修正与实现不一致的 mobility 注释。
- `clients/Voxia/scripts/create_voxel_world_aligned_material.py`：生成单次 UV0 采样、UV1 AO/sky、距离微纹理衰减的 DefaultLit opaque 材质。
- `clients/Voxia/Content/Voxia/Materials/M_VoxelWorldAligned.uasset`：由上述脚本确定性重建并提交。
- `clients/Voxia/Source/Voxia/FarField/VoxiaVoxelWorldAlignedMaterialAutomationTest.cpp`：新 material graph 合同。
- `clients/Voxia/Config/DefaultEngine.ini`：只保存 RG0/RG5 证实的默认 CVar；不写散乱实验值。

---

### Task 1（RG0）：建立远景渲染诊断与可复现基线

**Files:**
- Create: `clients/Voxia/Source/Voxia/Rendering/README.md`
- Create: `clients/Voxia/Source/Voxia/Rendering/VoxiaFarRenderDiagnostics.h`
- Create: `clients/Voxia/Source/Voxia/Rendering/VoxiaFarRenderDiagnostics.cpp`
- Create: `clients/Voxia/Source/Voxia/Rendering/VoxiaFarRenderDiagnosticsAutomationTest.cpp`
- Create: `clients/Voxia/scripts/voxia_far_render_metrics.js`
- Create: `clients/Voxia/scripts/voxia_far_render_metrics.test.js`
- Create: `clients/Voxia/scripts/run_far_render_governance.js`
- Modify: `clients/Voxia/Source/Voxia/Debug/VoxiaDebugCommandContract.cpp`
- Modify: `clients/Voxia/Source/Voxia/Debug/VoxiaDebugCommandRouterAutomationTest.cpp`
- Modify: `clients/Voxia/Source/Voxia/Debug/VoxiaDebugCliSubsystem.h`
- Modify: `clients/Voxia/Source/Voxia/Debug/VoxiaDebugCliSubsystem.cpp`
- Modify: `clients/Voxia/Source/Voxia/Debug/README.md`

**Interfaces:**
- Consumes: `UWorld*`、`UDynamicMeshComponent` flags、`RHIGetGPUFrameCycles()`、`GRenderThreadTime`、`GRHIThreadTime`、现有 `voxel_world_root_state` / `frame_perf`。
- Produces: `Voxia::Rendering::FVoxiaFarRenderDiagnostics::Capture(UWorld*) -> FVoxiaFarRenderDiagnosticSnapshot`、CLI `far_render_state`、扩展后的 `frame_perf`、`computeTemporalMetrics(decodedFrames)`。

- [ ] **Step 1: 写诊断 schema 与像素指标红测试**

```cpp
IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FVoxiaFarRenderDiagnosticsAutomationTest,
	"Voxia.Rendering.FarRenderDiagnostics",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FVoxiaFarRenderDiagnosticsAutomationTest::RunTest(const FString& Parameters)
{
	using namespace Voxia::Rendering;
	FVoxiaFarRenderDiagnosticSnapshot Snapshot;
	Snapshot.bRealRhi = true;
	Snapshot.ScreenPercentage = 77.0f;
	Snapshot.AntiAliasingMethod = 4;
	Snapshot.FarComponentCount = 53;
	Snapshot.VisibleFarComponentCount = 53;
	Snapshot.ShadowCastingFarComponentCount = 53;
	const FString Json = Snapshot.SnapshotJson();
	TestTrue(TEXT("schema 固定"), Json.Contains(TEXT("voxia_far_render_diagnostics_v1")));
	TestTrue(TEXT("完整 XYZ 远景组件统计可读"), Json.Contains(TEXT("\"far_components\"")));
	TestTrue(TEXT("TSR 配置可读"), Json.Contains(TEXT("\"screen_percentage\":77.000")));
	return true;
}
```

```javascript
const test = require("node:test");
const assert = require("node:assert/strict");
const { computeTemporalMetrics } = require("./voxia_far_render_metrics");

test("identical decoded frames have zero temporal energy", () => {
  const frame = { width: 2, height: 1, channels: 3, pixels: Buffer.from([10, 20, 30, 40, 50, 60]) };
  const result = computeTemporalMetrics([frame, frame]);
  assert.equal(result.mean_abs_luma_delta, 0);
  assert.equal(result.flicker_pixel_ratio_over_3, 0);
});
```

- [ ] **Step 2: 运行红测试并确认缺少新接口**

Run:

```powershell
$ue58 = 'C:\Program Files\Epic Games\UE_5.8'
& "$ue58\Engine\Binaries\Win64\UnrealEditor-Cmd.exe" "$PWD\Voxia.uproject" `
  -unattended -nop4 -nosplash -NullRHI `
  -ExecCmds="Automation RunTests Voxia.Rendering.FarRenderDiagnostics;Quit" `
  -TestExit="Automation Test Queue Empty"
node --test scripts/voxia_far_render_metrics.test.js
```

Expected: C++ 编译因 `VoxiaFarRenderDiagnostics.h` 不存在而失败；Node 因模块不存在而失败。

- [ ] **Step 3: 实现只读诊断 snapshot 与生产命令目录**

```cpp
namespace Voxia::Rendering
{
struct FVoxiaFarRenderDiagnosticSnapshot
{
	bool bRealRhi = false;
	float ScreenPercentage = -1.0f;
	int32 AntiAliasingMethod = -1;
	int32 VirtualShadowEnabled = -1;
	int32 LumenScreenTraces = -1;
	int32 FarComponentCount = 0;
	int32 VisibleFarComponentCount = 0;
	int32 ShadowCastingFarComponentCount = 0;
	int32 LumenContributingFarComponentCount = 0;
	int32 RayTracingVisibleFarComponentCount = 0;
	FString SnapshotJson() const;
};

class FVoxiaFarRenderDiagnostics
{
public:
	static FVoxiaFarRenderDiagnosticSnapshot Capture(UWorld* World);
};
}
```

在 `FVoxiaDebugCommandContract::Specs()` 的 EnginePerf 组追加：

```cpp
{ TEXT("far_render_state"), TEXT("far_render_state"), EnginePerf, Production, {}, true },
```

`ExecuteEnginePerfCommand` 只做 façade 转发：

```cpp
if (Command == TEXT("far_render_state"))
{
	return Voxia::Rendering::FVoxiaFarRenderDiagnostics::Capture(World).SnapshotJson();
}
```

将 router automation 的 production 数量从 `107` 更新为 `108`，并显式断言该 token 路由到 `EnginePerf`。

- [ ] **Step 4: 扩展 frame ring 的 RT/RHI/GPU 分位数**

在 `UVoxiaDebugCliSubsystem` 增加三条固定容量数组：

```cpp
TArray<float> FramePerfRenderThreadMs;
TArray<float> FramePerfRhiThreadMs;
TArray<float> FramePerfGpuMs;
```

每帧写入：

```cpp
FramePerfRenderThreadMs[FramePerfWriteIndex] =
	static_cast<float>(FPlatformTime::ToMilliseconds(GRenderThreadTime));
FramePerfRhiThreadMs[FramePerfWriteIndex] =
	static_cast<float>(FPlatformTime::ToMilliseconds(GRHIThreadTime));
FramePerfGpuMs[FramePerfWriteIndex] =
	static_cast<float>(FPlatformTime::ToMilliseconds(RHIGetGPUFrameCycles()));
```

复用一个接收 `TArray<double>` 的 percentile helper，向 JSON 追加 `render_thread_ms`、`rhi_thread_ms`、`gpu_ms` 的 p50/p95/p99/max；GPU 全零时额外输出 `gpu_timing_available=false`，不能伪造通过。

- [ ] **Step 5: 实现帧序列指标与 RG0 runner**

`computeTemporalMetrics` 使用 BT.709 luma：

```javascript
function luma(r, g, b) {
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

function computeTemporalMetrics(frames) {
  if (frames.length < 2) throw new Error("at least two decoded frames are required");
  const first = frames[0];
  let deltaSum = 0;
  let compared = 0;
  let overThree = 0;
  for (let index = 1; index < frames.length; index += 1) {
    const frame = frames[index];
    if (frame.width !== first.width || frame.height !== first.height || frame.channels !== first.channels) {
      throw new Error("frame dimensions must match");
    }
    for (let offset = 0; offset < frame.pixels.length; offset += frame.channels) {
      const previous = frames[index - 1].pixels;
      const delta = Math.abs(
        luma(frame.pixels[offset], frame.pixels[offset + 1], frame.pixels[offset + 2]) -
        luma(previous[offset], previous[offset + 1], previous[offset + 2])
      );
      deltaSum += delta;
      compared += 1;
      if (delta > 3) overThree += 1;
    }
  }
  return {
    mean_abs_luma_delta: Number((deltaSum / compared).toFixed(6)),
    flicker_pixel_ratio_over_3: Number((overThree / compared).toFixed(6)),
  };
}
```

runner 必须依次产生 `static_frozen`、`camera_translate`、`camera_rotate`、`generation_crossing` 四条 route；每条都请求 `performance_runtime_barrier`、`far_render_state`、`voxel_world_root_state`、`frame_perf reset/snapshot`。RG0 A/B 使用独立进程，仅改变一个 launch CVar：默认、screen percentage 100、VSM off、far cast-shadow off、Lumen screen traces off；索引写入 `.demo/observe/voxia_far_render_<run-id>/index.json`。

- [ ] **Step 6: 运行 RG0 focused 验证与真实基线**

Run:

```powershell
$ue58 = 'C:\Program Files\Epic Games\UE_5.8'
& "$ue58\Engine\Build\BatchFiles\Build.bat" VoxiaEditor Win64 Development `
  "-Project=$PWD\Voxia.uproject" -WaitMutex -NoUBA -MaxParallelActions=2
& "$ue58\Engine\Binaries\Win64\UnrealEditor-Cmd.exe" "$PWD\Voxia.uproject" `
  -unattended -nop4 -nosplash -NullRHI `
  -ExecCmds="Automation RunTests Voxia.Rendering.FarRenderDiagnostics+Voxia.Debug.CommandContract+Voxia.Debug.CommandRouter;Quit" `
  -TestExit="Automation Test Queue Empty"
node --test scripts/voxia_far_render_metrics.test.js
node scripts/run_far_render_governance.js --real-rhi --phase rg0 --res 1920x1080
```

Expected: build exit 0；三项 Automation Success；Node tests pass；runner 生成五个独立 A/B session、无 `LogVoxia: Error`，并把 H1–H5 标成 `supported` 或 `rejected`，不输出未归因的“fixed”。

- [ ] **Step 7: 提交 RG0**

```powershell
git add Source/Voxia/Rendering Source/Voxia/Debug scripts/voxia_far_render_metrics.js `
  scripts/voxia_far_render_metrics.test.js scripts/run_far_render_governance.js
git commit -m "feat(rendering): establish far render diagnostics"
```

---

### Task 2（RG1）：把跨帧 patch 换代改成单帧原子可见提交

**Files:**
- Create: `clients/Voxia/Source/Voxia/Presentation/VoxiaVoxelPresentationVisibilityPlan.h`
- Create: `clients/Voxia/Source/Voxia/Presentation/VoxiaVoxelPresentationVisibilityPlan.cpp`
- Create: `clients/Voxia/Source/Voxia/Presentation/VoxiaVoxelPresentationVisibilityPlanAutomationTest.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaVoxelPresentationSceneHost.h`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaVoxelPresentationSceneHost.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaVoxelPresentationResourceSetAutomationTest.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/README.md`

**Interfaces:**
- Consumes: old/new `TMap<FIntVector, TArray<UDynamicMeshComponent*>>`、现有 resource coordinator real fence。
- Produces: `FVoxiaVoxelPresentationVisibilityPlan::Build(oldCounts, newCounts, retainedKeys)`、scene host contract `voxel_presentation_scene_host_v8`、单次 `ApplyVisibilitySwap`。

- [ ] **Step 1: 写 retained/replaced/removed 单帧计划红测试**

```cpp
TMap<FIntVector, int32> OldCounts{{FIntVector(0,0,0), 2}, {FIntVector(1,0,0), 1}};
TMap<FIntVector, int32> NewCounts{{FIntVector(0,0,0), 2}, {FIntVector(2,0,0), 3}};
TSet<FIntVector> RetainedKeys{FIntVector(0,0,0)};
FVoxiaVoxelPresentationVisibilityPlan Plan;
FString Error;
TestTrue(TEXT("计划成功"), FVoxiaVoxelPresentationVisibilityPlan::Build(OldCounts, NewCounts, RetainedKeys, Plan, Error));
TestEqual(TEXT("retained 不切换"), Plan.RetainedPatchCount, 1);
TestEqual(TEXT("旧 removed 一次隐藏"), Plan.HidePatchKeys, TArray<FIntVector>{FIntVector(1,0,0)});
TestEqual(TEXT("新 replacement 一次显示"), Plan.ShowPatchKeys, TArray<FIntVector>{FIntVector(2,0,0)});
TestTrue(TEXT("计划声明单帧"), Plan.bRequiresSingleFrameCommit);
```

- [ ] **Step 2: 运行红测试**

Run Automation `Voxia.Presentation.VoxelPresentationVisibilityPlan`。

Expected: FAIL，类型不存在。

- [ ] **Step 3: 实现纯 visibility plan**

```cpp
struct FVoxiaVoxelPresentationVisibilityPlan
{
	TArray<FIntVector> HidePatchKeys;
	TArray<FIntVector> ShowPatchKeys;
	int32 RetainedPatchCount = 0;
	int32 HideComponentCount = 0;
	int32 ShowComponentCount = 0;
	bool bRequiresSingleFrameCommit = true;
	FString Error;
	bool IsReady() const { return Error.IsEmpty(); }

	static bool Build(
		const TMap<FIntVector, int32>& OldComponentCounts,
		const TMap<FIntVector, int32>& NewComponentCounts,
		const TSet<FIntVector>& RetainedPatchKeys,
		FVoxiaVoxelPresentationVisibilityPlan& OutPlan,
		FString& OutError);
};
```

scene host 先用现有 `SameComponents` 得到 `RetainedPatchKeys`；纯计划必须排序 XYZ key、拒绝负 component count、拒绝 retained key 缺失于任一侧。相同 key 但不在 retained 集合中就是 replacement，必须同时进入 hide/show；count 只用于预算，绝不能冒充 UObject identity。

- [ ] **Step 4: 在目标位置隐藏 stage，并在一个调用内完成所有 show/hide**

`CreateHiddenComponent` 改成：

```cpp
Voxia::FarField::FVoxiaFarFieldMeshComponentDesc::TerrainVisual(false).ApplyTo(Component);
Component->SetMobility(EComponentMobility::Movable);
Component->SetMeshDrawPath(EDynamicMeshDrawPath::StaticDraw);
Component->SetGenerateOverlapEvents(false);
Component->SetMaterial(0, PresentationMaterial.Get());
Component->SetMaterial(1, TranslucentPresentationMaterial.Get());
Component->SetMaterial(2, EmissivePresentationMaterial.Get());
Component->SetMesh(MoveTemp(Mesh));
Component->SetWorldLocation(WorldOriginCm, false, nullptr, ETeleportType::TeleportPhysics);
Component->SetVisibility(false, false);
```

删除 `NextPatchIndex` 与每 Tick 单 patch transform。`BeginVisibilitySwap` 只构建并预校验纯计划，不改变 live 可见性；`ResourceCoordinator.TryCommit` 成功回调只调用一次 `ApplyVisibilitySwap`：

```cpp
for (const FIntVector& Key : VisibilityPlan.HidePatchKeys)
{
	SetPatchVisibility(OldSet, Key, false);
}
for (const FIntVector& Key : VisibilityPlan.ShowPatchKeys)
{
	SetPatchVisibility(NewSet, Key, true);
}
HideChangedNear(OldSet, NewSet);
ShowChangedNear(NewSet, OldSet);
VisibilitySwap.bApplied = true; // TryCommit 回调内唯一写入点
```

所有 component 指针、target generation 与 retained identity 必须在调用 `TryCommit` 前全部校验；回调开始后只做不会失败的 `SetVisibility` 和 owner 转移。所有 helper 不再把组件搬到 `HiddenParkingWorldLocation()`；retained component 不触发可见性或 transform 更新。记录 `changed_patches/hide_components/show_components/commit_ms/atomic=true`。

- [ ] **Step 5: 加固失败与退休 fence**

若任一 component 为空、target generation 漂移或 `TryCommit` 拒绝：新组件保持 hidden、旧 live 保持 visible、`ResourceCoordinator.MarkFailed`；只有 callback 被执行时才原子切换可见性并转交 retained owner，随后以现有 retirement fence 回收旧 replacement。不得在错误分支先隐藏旧 live。

- [ ] **Step 6: focused + RG1 Real-RHI 验证**

Run:

```powershell
Automation RunTests Voxia.Presentation.VoxelPresentationVisibilityPlan
Automation RunTests Voxia.Gameplay.VoxelPresentationResourceSet
node scripts/run_far_render_governance.js --real-rhi --phase rg1 --res 1920x1080
```

Expected: `visibility_swap.atomic=true`；generation crossing 每帧 `mixed_generation=0/gap=0/overlap=0`；adjacent 与 teleport 均只出现一次 commit；commit p95 `<=1.0ms`；H4 被独立确认消除或被 RG0 数据拒绝。

- [ ] **Step 7: 提交 RG1**

```powershell
git add Source/Voxia/Presentation/VoxiaVoxelPresentationVisibilityPlan* `
  Source/Voxia/Gameplay/VoxiaVoxelPresentationSceneHost.* `
  Source/Voxia/Gameplay/VoxiaVoxelPresentationResourceSetAutomationTest.cpp `
  Source/Voxia/Gameplay/README.md
git commit -m "fix(rendering): commit far visibility atomically"
```

---

### Task 3（RG2）：恢复稳定面向 UV、正确 mip 与远距频率衰减

**Files:**
- Modify: `clients/Voxia/Source/Voxia/FarField/VoxiaFarFieldDynamicMesh.h`
- Modify: `clients/Voxia/Source/Voxia/FarField/VoxiaFarFieldDynamicMesh.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaCanonicalVoxelShellSceneBuilder.cpp`
- Modify: `clients/Voxia/Source/Voxia/FarField/VoxiaFarFieldPatchUploaderAutomationTest.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaCanonicalVoxelShellSceneBuilderAutomationTest.cpp`
- Modify: `clients/Voxia/scripts/create_voxel_world_aligned_material.py`
- Modify: `clients/Voxia/Content/Voxia/Materials/M_VoxelWorldAligned.uasset`
- Modify: `clients/Voxia/Source/Voxia/FarField/VoxiaVoxelWorldAlignedMaterialAutomationTest.cpp`

**Interfaces:**
- Consumes: 已验证的 `FVoxiaFarMesher::PrimaryUvForVertex` / `FVoxiaTerrainUv::ProjectFaceWorldCentimeters`。
- Produces: `voxia_far_dynamic_mesh_v3_source_uv`、UV0 单次采样材质、`MicroFadeStartCm=150000` / `MicroFadeEndCm=600000`。

- [ ] **Step 1: 写 Source UV 与 material graph 红测试**

在 uploader test 构造 +8km 与 -8km quad，断言四个 UV 顶点保留 `0/1` 相位而不是全为 `0.5`；在 material automation 断言：

```cpp
TestEqual(TEXT("只保留一次主纹理采样"), TextureSampleCount, 1);
TestTrue(TEXT("读取 UV0"), HasTextureCoordinate0);
TestFalse(TEXT("纹理坐标不再来自世界位置三轴采样"), bWorldPositionFeedsTextureCoordinates);
TestTrue(TEXT("远距微纹理起点存在"), ScalarParameters.Contains(TEXT("MicroFadeStartCm")));
TestTrue(TEXT("远距微纹理终点存在"), ScalarParameters.Contains(TEXT("MicroFadeEndCm")));
```

- [ ] **Step 2: 运行红测试**

Expected: current Pure3D build 使用 `ConstantCenter`，UV 断言失败；material 有三次 texture sample，graph 断言失败。

- [ ] **Step 3: Pure3D scene builder 改用既有 Source UV 合同并提升 cache fingerprint**

```cpp
inline const TCHAR* VoxiaFarFieldDynamicMeshAlgorithmVersion()
{
	return TEXT("voxia_far_dynamic_mesh_v3_source_uv");
}

inline constexpr uint64 VoxiaFarFieldDynamicMeshAlgorithmFingerprint()
{
	return 0x5646444d45534833ULL;
}
```

两个 production `BuildOptions` 都设置：

```cpp
BuildOptions.PrimaryUvMode = EVoxiaFarFieldPrimaryUvMode::Source;
```

legacy probe 的显式 clean/compatibility 开关不借本任务改写。

- [ ] **Step 4: 确定性重建单采样材质资产**

Python graph 使用 `MaterialExpressionTextureCoordinate` index 0 直接连接唯一 `TextureSample`；用 `CameraPositionWS`、`WorldPosition` 只计算距离因子，不参与纹理坐标：

```python
uv0 = lib.create_material_expression(material, unreal.MaterialExpressionTextureCoordinate, -900, -80)
uv0.set_editor_property("coordinate_index", 0)
sample = lib.create_material_expression(material, unreal.MaterialExpressionTextureSample, -650, -80)
sample.set_editor_property("texture", texture)
_connect(lib, uv0, sample, "", "UV0 -> TextureSample.Coordinates")

fade_start = _scalar_parameter(lib, material, "MicroFadeStartCm", 150000.0, -650, 180)
fade_end = _scalar_parameter(lib, material, "MicroFadeEndCm", 600000.0, -650, 260)
distance_factor = _camera_distance_factor(lib, material, fade_start, fade_end)
micro = _lerp(lib, material, sample, _constant3(lib, material, 1.0, 1.0, 1.0), distance_factor)
base_color = _multiply(lib, material, micro, vertex_color, 420, 20, "MicroTimesVertexColor")
```

脚本必须补齐并单测这些确定性 helper：`_scalar_parameter` 创建命名标量参数；`_constant3` 创建 `MaterialExpressionConstant3Vector`；`_camera_distance_factor` 严格构建 `saturate((distance(CameraPositionWS, WorldPosition)-start)/(end-start))`；`_lerp` 创建 `MaterialExpressionLinearInterpolate`。每次 node 创建、属性设置和 pin 连接失败都抛 `RuntimeError`，不允许静默生成残缺 asset。

运行脚本并保存 asset：

```powershell
$ue58 = 'C:\Program Files\Epic Games\UE_5.8'
& "$ue58\Engine\Binaries\Win64\UnrealEditor-Cmd.exe" "$PWD\Voxia.uproject" `
  -ExecutePythonScript="$PWD\scripts\create_voxel_world_aligned_material.py" `
  -unattended -nop4 -nosplash
```

- [ ] **Step 5: focused + RG2 A/B**

Run `Voxia.Voxel.FarMeshData`、`Voxia.FarField.FarFieldPatchUploader`、`Voxia.Gameplay.CanonicalVoxelShellSceneBuilder`、`Voxia.FarField.WorldAlignedMaterialContract`，再运行：

```powershell
node scripts/run_far_render_governance.js --real-rhi --phase rg2 --res 1920x1080
```

Expected: ±8km UV 相位一致；三轴纹理采样降为单次；TSR 77% 静止序列达到 `abs(Δluma)>3/255` 像素比例 p95 `<=0.1%`，且无需 100% screen percentage 才稳定。若 RG2 后仍不达门槛，阶段标红并返回 RG0；本提交不顺带改 ring/span。

- [ ] **Step 6: 提交 RG2**

```powershell
git add Source/Voxia/FarField/VoxiaFarFieldDynamicMesh.* `
  Source/Voxia/FarField/VoxiaFarFieldPatchUploaderAutomationTest.cpp `
  Source/Voxia/FarField/VoxiaVoxelWorldAlignedMaterialAutomationTest.cpp `
  Source/Voxia/Gameplay/VoxiaCanonicalVoxelShellSceneBuilder* `
  scripts/create_voxel_world_aligned_material.py `
  Content/Voxia/Materials/M_VoxelWorldAligned.uasset
git commit -m "fix(rendering): stabilize far material sampling"
```

---

### Task 4（RG3a）：派生确定性体素 AO 与局部天空可见度

**Files:**
- Create: `clients/Voxia/Source/Voxia/FarField/VoxiaVoxelSurfaceLightingArtifact.h`
- Create: `clients/Voxia/Source/Voxia/FarField/VoxiaVoxelSurfaceLightingArtifact.cpp`
- Create: `clients/Voxia/Source/Voxia/FarField/VoxiaVoxelSurfaceLightingArtifactAutomationTest.cpp`
- Modify: `clients/Voxia/Source/Voxia/Voxel/VoxiaFarMeshData.h`
- Modify: `clients/Voxia/Source/Voxia/Voxel/VoxiaFarMeshData.cpp`
- Modify: `clients/Voxia/Source/Voxia/FarField/VoxiaFarFieldDynamicMesh.cpp`
- Modify: `clients/Voxia/Source/Voxia/FarField/VoxiaVoxelSurfaceMeshAdapter.h`
- Modify: `clients/Voxia/Source/Voxia/FarField/VoxiaVoxelSurfaceMeshAdapter.cpp`
- Modify: `clients/Voxia/Source/Voxia/FarField/VoxiaVoxelShellResolvedSurfaceStager.h`
- Modify: `clients/Voxia/Source/Voxia/FarField/VoxiaVoxelShellResolvedSurfaceStager.cpp`
- Modify: `clients/Voxia/Source/Voxia/FarField/VoxiaVoxelShellArtifactReuse.h`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaCanonicalVoxelShellSceneBuilder.cpp`

**Interfaces:**
- Consumes: `FVoxiaVoxelSurfaceArtifact`、现有 `FVoxiaVoxelResolvedMaterialSampler`、surface dependency fingerprint。
- Produces: `FVoxiaVoxelSurfaceLightingArtifactRef`、compact mesh `VertexLighting`（AO, sky）、DynamicMesh UV1。

- [ ] **Step 1: 写角点遮蔽和 missing 红测试**

```cpp
TSet<FIntVector> Blocked;
const FIntVector SideU(1, 0, 1);
const FIntVector SideV(0, 1, 1);
const FIntVector Corner(1, 1, 1);
const FVoxiaVoxelSurfaceArtifact Surface = MakeSingleTopFaceSurface(FIntVector::ZeroValue);
FVoxiaVoxelSurfaceLightingArtifact Lighting;
const auto Sampler = [&Blocked](const FIntVector& Coord, FVoxiaVoxelResolvedMaterialSample& Out, FString& Error)
{
	if (Coord == FIntVector(99,99,99)) { Error = TEXT("fixture_missing"); return false; }
	Out.bResolved = true;
	Out.MaterialId = Blocked.Contains(Coord) ? 2 : 0;
	return true;
};
TestTrue(TEXT("无邻接遮挡为全亮"), FVoxiaVoxelSurfaceLightingArtifactBuilder::Build(Surface, Sampler, 7, Lighting));
TestEqual(TEXT("四角数量守恒"), Lighting.VertexLighting.Num(), Surface.Quads.Num() * 4);
TestEqual(TEXT("全亮 AO"), Lighting.VertexLighting[0].X, 1.0f);
Blocked = TSet<FIntVector>{SideU, SideV, Corner};
TestTrue(TEXT("三遮挡可构建"), FVoxiaVoxelSurfaceLightingArtifactBuilder::Build(Surface, Sampler, 8, Lighting));
TestEqual(TEXT("两侧同时遮挡使用最暗档"), Lighting.VertexLighting[0].X, 0.45f);
```

另加 sampler 返回 false 时 `Build=false`、artifact 输出为空、error 保留 `fixture_missing`。

- [ ] **Step 2: 运行红测试**

Expected: FAIL，lighting artifact 类型不存在。

- [ ] **Step 3: 实现独立 lighting artifact**

```cpp
struct FVoxiaVoxelSurfaceLightingArtifact
{
	Voxia::Voxel::FVoxiaVoxelBrickId Id;
	TArray<FVector2f> VertexLighting;
	uint64 DependencyFingerprint = 0;
	bool bBuilt = false;
	FString Error;
	bool IsReadyFor(const Voxia::Voxel::FVoxiaVoxelSurfaceArtifact& Surface) const;
};

class FVoxiaVoxelSurfaceLightingArtifactBuilder
{
public:
	static constexpr uint64 AlgorithmFingerprint = 0x56584c4947485431ULL;
	static bool Build(
		const Voxia::Voxel::FVoxiaVoxelSurfaceArtifact& Surface,
		const Voxia::Voxel::FVoxiaVoxelResolvedMaterialSampler& Sampler,
		uint64 SurfaceDependencyFingerprint,
		FVoxiaVoxelSurfaceLightingArtifact& OutArtifact);
};
```

每个 corner 在 air side 采 `sideU`、`sideV`、`corner`；`sideU && sideV` 时 occlusion level 固定 3，否则为三项和。AO 表固定为 `{1.00f, 0.80f, 0.62f, 0.45f}`；local sky visibility 固定为 `FaceUp ? 1.00f : FaceSide ? 0.72f : 0.45f`，再乘 `FMath::Lerp(0.70f, 1.0f, AO)`。算法不读取太阳、相机或 UObject。

- [ ] **Step 4: 把 lighting 与 surface 同批发布和复用**

`FVoxiaVoxelShellResolvedSurfaceStageResult` 新增：

```cpp
TMap<Voxia::Voxel::FVoxiaVoxelBrickId, FVoxiaVoxelSurfaceLightingArtifactRef> LightingArtifacts;
int32 BuiltLightingCount = 0;
int32 ReusedLightingCount = 0;
```

surface 构建成功后、离开现有 resolved sampler 生命周期前构建 lighting；任一 lighting 失败则 candidate surfaces/lighting 都不写入 `OutResult`。reuse key 必须混入 `SurfaceDependencyFingerprint` 与 `AlgorithmFingerprint`。

- [ ] **Step 5: 传递到 compact mesh UV1**

`FVoxiaFarMeshData` 新增：

```cpp
TArray<FVector2f> VertexLighting; // 4/quad，X=AO，Y=local sky visibility
```

`EmitQuad` 每加入四个位置先同步填四个 `(1,1)`，canonical adapter 随后用同 ID lighting artifact 覆盖；这样 legacy compatibility 数据结构保持有效，但现役 canonical adapter 缺 lighting 时仍显式失败。`IsStructurallyValid()` 要求数量严格等于 positions；`FVoxiaVoxelSurfaceMeshAdapter::Build` 接收同 ID lighting artifact；DynamicMesh compact 路径 `UvLayerCount` 返回 2，UV1 读取 `VertexLighting`。

- [ ] **Step 6: focused 验证与 worker 成本比较**

Run:

```powershell
Automation RunTests Voxia.FarField.VoxelSurfaceLightingArtifact
Automation RunTests Voxia.FarField.VoxelShellResolvedSurfaceStager
Automation RunTests Voxia.Voxel.FarMeshData
Automation RunTests Voxia.Gameplay.CanonicalVoxelShellSceneBuilder
node scripts/run_far_render_governance.js --real-rhi --phase rg3a --res 1920x1080
```

Expected: missing/identity/halo 任一失败零发布；相邻 generation lighting reuse 与 surface reuse 同步；worker p95 不比 RG2 增加超过 10%，steady GT/GPU 不增加超过 0.2ms。

- [ ] **Step 7: 提交 RG3a**

```powershell
git add Source/Voxia/FarField/VoxiaVoxelSurfaceLightingArtifact* `
  Source/Voxia/FarField/VoxiaVoxelShellResolvedSurfaceStager.* `
  Source/Voxia/FarField/VoxiaVoxelShellArtifactReuse.h `
  Source/Voxia/FarField/VoxiaVoxelSurfaceMeshAdapter.* `
  Source/Voxia/FarField/VoxiaFarFieldDynamicMesh.cpp `
  Source/Voxia/Voxel/VoxiaFarMeshData.* `
  Source/Voxia/Gameplay/VoxiaCanonicalVoxelShellSceneBuilder.cpp
git commit -m "feat(rendering): derive stable voxel ambient lighting"
```

---

### Task 5（RG3b）：收敛单主光环境与距离分层阴影

**Files:**
- Create: `clients/Voxia/Source/Voxia/Rendering/VoxiaEnvironmentLightingPolicy.h`
- Create: `clients/Voxia/Source/Voxia/Rendering/VoxiaEnvironmentLightingPolicy.cpp`
- Create: `clients/Voxia/Source/Voxia/Rendering/VoxiaEnvironmentLightingPolicyAutomationTest.cpp`
- Create: `clients/Voxia/Source/Voxia/Rendering/VoxiaEnvironmentLightingComponent.h`
- Create: `clients/Voxia/Source/Voxia/Rendering/VoxiaEnvironmentLightingComponent.cpp`
- Create: `clients/Voxia/Source/Voxia/Rendering/VoxiaEnvironmentLightingComponentAutomationTest.cpp`
- Create: `clients/Voxia/Source/Voxia/Rendering/VoxiaFarShadowPolicy.h`
- Create: `clients/Voxia/Source/Voxia/Rendering/VoxiaFarShadowPolicy.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaClientGameMode.h`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaClientGameMode.cpp`
- Modify: `clients/Voxia/Source/Voxia/Debug/VoxiaDebugCommandContract.cpp`
- Modify: `clients/Voxia/Source/Voxia/Debug/VoxiaDebugCommandRouterAutomationTest.cpp`
- Modify: `clients/Voxia/Source/Voxia/Debug/VoxiaDebugCliSubsystem.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaCanonicalVoxelShellSceneBuilder.h`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaCanonicalVoxelShellSceneBuilder.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaVoxelPresentationSceneHost.h`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaVoxelPresentationSceneHost.cpp`
- Modify: `clients/Voxia/Source/Voxia/FarField/VoxiaFarFieldMeshComponentDesc.h`
- Modify: `clients/Voxia/Source/Voxia/FarField/VoxiaFarFieldMeshComponentDesc.cpp`

**Interfaces:**
- Consumes: UDS actor directional/sky components、cube-shell `RingIndex`、RG0 VSM invalidation evidence。
- Produces: `FVoxiaEnvironmentLightingPolicy::ForAnchor`、`UVoxiaEnvironmentLightingComponent` 自维护 CLI anchor/sweep、patch `NearestRingIndex`、`FVoxiaFarShadowPolicy::ShouldCastShadow`。

- [x] **Step 1: 写环境锚点与阴影 tier 红测试**

```cpp
const FVoxiaEnvironmentLightingState Noon = FVoxiaEnvironmentLightingPolicy::ForAnchor(EVoxiaLightingAnchor::Noon);
const FVoxiaEnvironmentLightingState Dusk = FVoxiaEnvironmentLightingPolicy::ForAnchor(EVoxiaLightingAnchor::Dusk);
const FVoxiaEnvironmentLightingState Night = FVoxiaEnvironmentLightingPolicy::ForAnchor(EVoxiaLightingAnchor::Night);
TestEqual(TEXT("中午太阳俯角"), Noon.PrimaryRotation.Pitch, -58.0f);
TestEqual(TEXT("晨昏太阳俯角"), Dusk.PrimaryRotation.Pitch, -8.0f);
TestEqual(TEXT("夜晚只有一个主方向光"), Night.MaxShadowCastingDirectionalLights, 1);
TestTrue(TEXT("三个锚点 artifact identity 不变"), Noon.ArtifactPolicyFingerprint == Dusk.ArtifactPolicyFingerprint && Dusk.ArtifactPolicyFingerprint == Night.ArtifactPolicyFingerprint);
TestTrue(TEXT("性能档 ring0 投影"), FVoxiaFarShadowPolicy::ShouldCastShadow(0, 0));
TestFalse(TEXT("性能档 ring1 不投影"), FVoxiaFarShadowPolicy::ShouldCastShadow(1, 0));
```

- [x] **Step 2: 实现纯策略值与连续插值**

```cpp
enum class EVoxiaLightingAnchor : uint8 { Noon, Dusk, Night };

struct FVoxiaEnvironmentLightingState
{
	FRotator PrimaryRotation;
	float PrimaryIntensityScale = 1.0f;
	FLinearColor PrimaryColor = FLinearColor::White;
	float SkyIntensity = 1.0f;
	FLinearColor LowerHemisphereColor = FLinearColor(0.05f, 0.06f, 0.08f);
	float FogDensity = 5.0e-7f;
	float FogStartDistanceCm = 400000.0f;
	float ExposureEv100 = 1.0f;
	int32 MaxShadowCastingDirectionalLights = 1;
	uint64 ArtifactPolicyFingerprint = 0x56454e564c495431ULL;
};
```

固定锚点：Noon `(-58,-35)` / sun scale `1.0` / sky `1.0`；Dusk `(-8,-35)` / sun scale `0.35` / sky `0.55`；Night `(18,-35)` / primary scale `0.08` / sky `0.18`。`Interpolate(A,B,Alpha)` 只插 lighting state，不改变 artifact fingerprint。

`FVoxiaFarShadowPolicy::ShouldCastShadow(NearestRingIndex, MaxShadowCastingRing)` 在 max ring 小于零时恒 false，否则仅对 `0 <= ring <= max` 返回 true；RG3b 的冻结默认值为 0，RG5 再由统一 quality policy 提供该值。

- [x] **Step 3: GameMode 删除 fill rig 并只组合一套环境**

新增 `UVoxiaEnvironmentLightingComponent : UActorComponent`，由 `AVoxiaClientGameMode` constructor 创建默认子对象。它持有 primary directional、SkyLight、fog 的弱引用，拥有 current anchor、sweep active、normalized time、last recapture frame，并在自身 `TickComponent` 中维持连续太阳运动；公开 `BindEnvironment(...)`、`ApplyAnchor(...)`、`StartSweep()`、`StopSweep()`、`SnapshotJson()`。`SetupEnvironment` 只负责发现/生成 UE 组件并绑定，不能自己保存另一份时间状态。

删掉 `VoxiaFill`、`VoxiaFallbackFill`、三 lateral 与 up fill spawn。UDS 和 fallback 均由同一 policy component 应用：最强 active directional 为 primary 且投影；其余 directional 不投影；SkyLight intensity 使用 policy；fallback sun 必须 `SetCastShadows(true)`。固定环境时只 `RecaptureSky()` 一次，连续 sweep 不逐帧 recapture。

所有本次触及的英文环境注释改为中文；不修改未触及文件的历史注释。

- [x] **Step 4: 传播 patch ring 并应用 shadow policy**

`FVoxiaVoxelPresentationFarPatchStage` 新增 `int32 NearestRingIndex = MAX_int32`；scene builder 从 plan cell 建立 page ID→ring map，group 取最小 ring。`FPendingComponentCreation` 携带 `bCastShadow`，创建前设置：

```cpp
FVoxiaFarFieldMeshComponentDesc Desc = FVoxiaFarFieldMeshComponentDesc::TerrainVisual(false);
Desc.bCastShadow = Creation.bCastShadow;
Desc.ApplyTo(Component);
```

`FVoxiaCanonicalVoxelShellSceneBuildConfig` 新增 `MaxShadowCastingRing=0`；scene builder 和 host 只消费该冻结字段。RG3b 不增加临时命令行散读；shadow-off A/B 继续使用 RG0 的 VSM/CastShadow 诊断注入，RG5 再把质量档解析结果写入同一 build config。

- [x] **Step 5: 追加 anchor/sweep CLI 与结构化状态**

```cpp
{ TEXT("far_lighting_anchor"), TEXT("far_lighting_anchor noon|dusk|night"), EnginePerf, Production, {}, true },
{ TEXT("far_lighting_sweep"), TEXT("far_lighting_sweep start|stop|state"), EnginePerf, Production, {}, true },
```

`far_render_state.environment` 输出 anchor、sun rotation、active shadow caster count、sky intensity、last recapture frame、sweep active；设置失败返回 `expected_noon_dusk_or_night`，不静默保留旧值并报成功。

- [x] **Step 6: RG3b Real-RHI 验证**

Run focused automation 与：

```powershell
node scripts/run_far_render_governance.js --real-rhi --phase rg3b --res 1920x1080
```

Expected: 三锚点 `shadow_casting_directional_lights=1`；无 fill actors；连续 sweep 中 generation、source/artifact/mesh fingerprint 不变；static VSM-on 与 VSM-off A/B 能归因 H2；default shadow caster patch 只来自 nearest ring 0；GPU p95 不高于 RG2。

- [x] **Step 7: 提交 RG3b**

```powershell
git add Source/Voxia/Rendering/VoxiaEnvironmentLighting* `
  Source/Voxia/Rendering/VoxiaFarShadowPolicy* `
  Source/Voxia/Gameplay/VoxiaClientGameMode.* `
  Source/Voxia/Gameplay/VoxiaCanonicalVoxelShellSceneBuilder.* `
  Source/Voxia/Gameplay/VoxiaVoxelPresentationSceneHost.* `
  Source/Voxia/FarField/VoxiaFarFieldMeshComponentDesc.* `
  Source/Voxia/Debug/VoxiaDebugCommandContract.cpp `
  Source/Voxia/Debug/VoxiaDebugCommandRouterAutomationTest.cpp `
  Source/Voxia/Debug/VoxiaDebugCliSubsystem.cpp
git commit -m "feat(rendering): apply natural environment and shadow tiers"
```

---

### Task 6（RG4）：让 DefaultLit 材质消费 AO/天空可见度并形成克制纵深

**Files:**
- Modify: `clients/Voxia/scripts/create_voxel_world_aligned_material.py`
- Modify: `clients/Voxia/Content/Voxia/Materials/M_VoxelWorldAligned.uasset`
- Modify: `clients/Voxia/Source/Voxia/FarField/VoxiaVoxelWorldAlignedMaterialAutomationTest.cpp`
- Modify: `clients/Voxia/Source/Voxia/FarField/VoxiaFarFieldDynamicMesh.h`
- Modify: `clients/Voxia/Source/Voxia/Rendering/README.md`

**Interfaces:**
- Consumes: UV0 stable face coordinate；UV1.X AO；UV1.Y local sky visibility；vertex RGB material tint。
- Produces: `M_VoxelWorldAligned` contract `voxia_far_natural_material_v1`；roughness `0.88`；AO=min(UV1.X, UV1.Y)。

- [x] **Step 1: 写材质输入合同红测试**

```cpp
TestTrue(TEXT("读取 UV1 lighting"), TextureCoordinateIndices.Contains(1));
TestTrue(TEXT("AO 接入材质属性"), ConnectedProperties.Contains(MP_AmbientOcclusion));
TestEqual(TEXT("粗糙度参数默认值"), ScalarParameters.FindChecked(TEXT("Roughness")), 0.88f);
TestEqual(TEXT("材质合同"), ContractParameter, FString(TEXT("voxia_far_natural_material_v1")));
TestFalse(TEXT("不含 dither temporal AA"), bHasDitherTemporalAa);
```

- [x] **Step 2: 运行红测试**

Expected: current asset 未读取 UV1，AO property 未连接。

- [x] **Step 3: 更新 material graph**

```python
uv1 = lib.create_material_expression(material, unreal.MaterialExpressionTextureCoordinate, -180, 320)
uv1.set_editor_property("coordinate_index", 1)
ao = _mask(lib, material, uv1, "r", 40, 300)
sky_visibility = _mask(lib, material, uv1, "g", 40, 390)
ambient_visibility = _min(lib, material, ao, sky_visibility, 260, 340, "AmbientVisibility")
if not lib.connect_material_property(ambient_visibility, "", unreal.MaterialProperty.MP_AMBIENT_OCCLUSION):
    raise RuntimeError("connect(AmbientVisibility -> AmbientOcclusion) failed")

roughness = _scalar_parameter(lib, material, "Roughness", 0.88, 580, 260)
contract = _scalar_parameter(lib, material, "VoxiaFarNaturalMaterialV1", 1.0, 580, 360)
```

`_min` 必须创建 `MaterialExpressionMin`，把 AO 接 A、sky visibility 接 B，并在任一连接失败时抛 `RuntimeError`；材质合同测试同时断言该节点确实位于 UV1 与 `MP_AmbientOcclusion` 之间。

BaseColor 只乘 vertex RGB 与 RG2 的单采样/距离 fade；不再用四盏 fill 抬亮暗面。AO 只进入 indirect occlusion，不乘死太阳直射；emissive/translucent 继续使用既有 slot，不回退 opaque。

- [x] **Step 4: 重建 asset 并运行三锚点视觉/指标门槛**

Run material script、material automation、RG4 runner。Expected：中午暗面可读但保持方向性；晨昏长明暗层次连续；夜晚不黑屏；静止像素门槛通过；没有 gap/overlap；GPU p95 增量相对 RG3b `<=0.2ms`。

- [x] **Step 5: 提交 RG4**

```powershell
git add scripts/create_voxel_world_aligned_material.py `
  Content/Voxia/Materials/M_VoxelWorldAligned.uasset `
  Source/Voxia/FarField/VoxiaVoxelWorldAlignedMaterialAutomationTest.cpp `
  Source/Voxia/FarField/VoxiaFarFieldDynamicMesh.h `
  Source/Voxia/Rendering/README.md
git commit -m "feat(rendering): add natural far material depth"
```

---

### Task 7（RG5）：冻结同根质量策略与 120 FPS 门禁

**Files:**
- Create: `clients/Voxia/Source/Voxia/Rendering/VoxiaFarRenderQualityPolicy.h`
- Create: `clients/Voxia/Source/Voxia/Rendering/VoxiaFarRenderQualityPolicy.cpp`
- Create: `clients/Voxia/Source/Voxia/Rendering/VoxiaFarRenderQualityPolicyAutomationTest.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaClientRuntimeConfig.h`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaClientRuntimeConfig.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaClientRuntimeConfigAutomationTest.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaClientGameMode.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaCanonicalVoxelShellSceneBuilder.h`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaCanonicalVoxelShellSceneBuilder.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaPure3DVoxelWorldActor.cpp`
- Modify: `clients/Voxia/Config/DefaultEngine.ini`
- Modify: `clients/Voxia/scripts/run_far_render_governance.js`

**Interfaces:**
- Consumes: frozen runtime config、RG0–RG4 metrics、environment/shadow/material parameters。
- Produces: `EVoxiaFarRenderQuality::PerformanceNatural|QualityNatural`、唯一默认 `performance_natural`、硬性能结论。

- [x] **Step 1: 写默认档与无效值红测试**

```cpp
const FVoxiaClientRuntimeConfig Default = FVoxiaClientRuntimeConfig::Parse(TEXT(""));
TestEqual(TEXT("默认高刷新档"), Default.Far.RenderQuality, EVoxiaFarRenderQuality::PerformanceNatural);
TestTrue(TEXT("默认配置有效"), Default.Far.bRenderQualityValid);
const FVoxiaClientRuntimeConfig Invalid = FVoxiaClientRuntimeConfig::Parse(TEXT("-VoxiaFarRenderQuality=cinematic"));
TestFalse(TEXT("未知档显式失败"), Invalid.Far.bRenderQualityValid);
TestEqual(TEXT("失败原因稳定"), Invalid.Far.RenderQualityError, FString(TEXT("unsupported_far_render_quality")));
```

- [x] **Step 2: 实现冻结 quality policy**

```cpp
enum class EVoxiaFarRenderQuality : uint8
{
	PerformanceNatural,
	QualityNatural
};

struct FVoxiaFarRenderQualityPolicy
{
	EVoxiaFarRenderQuality Quality = EVoxiaFarRenderQuality::PerformanceNatural;
	int32 MaxShadowCastingRing = 0;
	int32 GlobalIlluminationQuality = 1;
	int32 ReflectionQuality = 1;
	float ScreenPercentage = 77.0f;
	float MicroFadeStartCm = 150000.0f;
	float MicroFadeEndCm = 600000.0f;
	static FVoxiaFarRenderQualityPolicy Resolve(EVoxiaFarRenderQuality Quality);
};
```

`quality_natural` 只把 shadow ring 提到 1、GI/reflection quality 提到 2、micro fade 调为 250000/900000；presentation、truth、root、artifact 算法不变。

- [x] **Step 3: 由 RuntimeConfig 唯一解析并应用**

`FVoxiaClientFarRuntimeConfig` 增加 enum、valid/error；GameMode `InitGame` 在 invalid 时设置 `bStartupRejected=true` 与稳定 reason。GameMode 通过 policy façade 设置 `sg.GlobalIlluminationQuality`、`sg.ReflectionQuality`、`r.ScreenPercentage`；Pure3D actor 从同一 frozen policy 构造 `FVoxiaCanonicalVoxelShellSceneBuildConfig.MaxShadowCastingRing`，scene builder/host 不再读取任何原始文本。

`DefaultEngine.ini` 保留：

```ini
r.AntiAliasingMethod=4
r.ScreenPercentage=77
t.MaxFPS=130
```

RG0 中被证实无收益或导致闪烁的实验 CVar 从默认段删除，只允许 runner 以 `-ExecCmds` 单次 A/B。

- [x] **Step 4: 将 runner 门槛写成不可放宽断言**

```javascript
assert.ok(frame.frame_ms.p95 <= 8.33, `frame p95 ${frame.frame_ms.p95}ms exceeds 8.33ms`);
assert.ok(frame.frame_ms.p99 <= 11.11, `frame p99 ${frame.frame_ms.p99}ms exceeds 11.11ms`);
assert.ok(frame.game_thread_ms.p95 <= 3.5, `GT p95 ${frame.game_thread_ms.p95}ms exceeds 3.5ms`);
assert.ok(frame.gpu_timing_available, "GPU timing must be available in Real-RHI");
assert.ok(frame.gpu_ms.p95 <= 6.0, `GPU p95 ${frame.gpu_ms.p95}ms exceeds 6.0ms`);
assert.ok(temporal.flicker_pixel_ratio_over_3 <= 0.001, "static flicker ratio exceeds 0.1%");
```

raw DXGI/D3D12 stalls与 attributed metrics 同时写入 index；不得删除 raw frame、截短采样或把外部 stall 改写成 pass。

- [x] **Step 5: RG5 完整默认档与 quality 对照**

Run：

```powershell
node scripts/run_far_render_governance.js --real-rhi --phase rg5 --quality performance_natural --res 1920x1080
node scripts/run_far_render_governance.js --real-rhi --phase rg5 --quality quality_natural --res 1920x1080
```

Expected: performance 全门槛通过；quality 只报告、不约束 120 FPS；两者 root contract 都是 `production_all_features`，snapshot/source/generation 语义一致。

- [x] **Step 6: 提交 RG5**

```powershell
git add Source/Voxia/Rendering/VoxiaFarRenderQualityPolicy* `
  Source/Voxia/Gameplay/VoxiaClientRuntimeConfig* `
  Source/Voxia/Gameplay/VoxiaClientGameMode.cpp `
  Source/Voxia/Gameplay/VoxiaCanonicalVoxelShellSceneBuilder.* `
  Source/Voxia/Gameplay/VoxiaPure3DVoxelWorldActor.cpp `
  Config/DefaultEngine.ini scripts/run_far_render_governance.js
git commit -m "feat(rendering): enforce high-refresh far quality policy"
```

---

### Task 8（RG6）：唯一生产根联合验收、文档收口、提交推送与 CI

**Files:**
- Modify: `clients/Voxia/README.md`
- Modify: `clients/Voxia/Source/Voxia/FarField/README.md`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/README.md`
- Modify: `clients/Voxia/Source/Voxia/Debug/README.md`
- Modify: `clients/Voxia/Source/Voxia/Rendering/README.md`
- Modify: `docs/10-active/voxel-far-field/2026-07-21-voxia-far-render-governance-design.md`
- Modify: `docs/10-active/voxel-far-field/2026-07-21-voxia-far-render-governance-implementation-plan.md`
- Modify: `docs/00-current-truth/design/client/streaming-lod.md`
- Modify: `docs/00-current-truth/impl/README.md`
- Modify: `docs/00-current-truth/impl/known_gaps.md`
- Modify: `docs/00-current-truth/source_index.md`
- Modify: `docs/10-active/cross-cutting/_session-handoff.md`
- Modify: outer repository `clients/Voxia` submodule pointer

**Interfaces:**
- Consumes: RG0–RG5 fresh commits and observe artifacts。
- Produces: one client closeout commit、one outer docs/submodule commit、pushed branches、GitHub CI status。

- [ ] **Step 1: fresh Development build 与全量 Automation**

```powershell
$ue58 = 'C:\Program Files\Epic Games\UE_5.8'
& "$ue58\Engine\Build\BatchFiles\Build.bat" VoxiaEditor Win64 Development `
  "-Project=$PWD\Voxia.uproject" -WaitMutex -NoUBA -MaxParallelActions=2
& "$ue58\Engine\Binaries\Win64\UnrealEditor-Cmd.exe" "$PWD\Voxia.uproject" `
  -unattended -nop4 -nosplash -NullRHI `
  -ExecCmds="Automation RunTests Voxia;Quit" `
  -TestExit="Automation Test Queue Empty"
node --test scripts/voxia_far_render_metrics.test.js
```

Expected: UBT exit 0；全部 Voxia tests Success，0 failed/not-run；Node pass。

- [ ] **Step 2: Null-RHI、短 Real-RHI、RG 全矩阵**

```powershell
node scripts/run_phase1_world_lifecycle_smoke.js --null-rhi --res 1920x1080
node scripts/run_phase1_world_lifecycle_smoke.js --real-rhi --res 1920x1080
node scripts/run_far_render_governance.js --real-rhi --phase rg6 --quality performance_natural --res 1920x1080
```

Expected: 所有 production routes pass；`wire_fixture_changed=false`、`production_root_count=1`、完整 XYZ；静止/移动/跨 tile/三锚点/太阳 sweep 全通过；无 `LogVoxia: Error`。

- [ ] **Step 3: 30 分钟默认 GC soak**

```powershell
node scripts/run_phase1_world_lifecycle_smoke.js --real-rhi --performance-only --res 1920x1080 --soak-minutes 30
node scripts/run_far_render_governance.js --real-rhi --phase rg6 --quality performance_natural --res 1920x1080 --soak-minutes 30
```

Expected: 无 renderer-owned `growing_keys`；pending release 最终归零；raw/GT/RT/RHI/GPU 指标完整；性能门槛不因默认 GC 被关闭。

- [ ] **Step 4: 更新代码旁 README 与 current truth**

只把 fresh 证据写成当前事实；历史补光、三轴世界采样、跨帧 visibility swap 与旧数值移入 archive 或标成被取代。Mermaid 图显示：canonical→surface→lighting→mesh→atomic host→unique root。`known_gaps` 只保留天气、在线 provider 和低端硬件分档，不把已关闭闪烁继续列为缺口。

- [ ] **Step 5: 客户端最终提交**

```powershell
git status --short
git diff --check
git add README.md Source/Voxia/FarField/README.md Source/Voxia/Gameplay/README.md `
  Source/Voxia/Debug/README.md Source/Voxia/Rendering/README.md
git commit -m "docs(rendering): close far render governance"
```

Expected: client worktree clean；`git log` 显示 RG0、RG1、RG2、RG3a、RG3b、RG4、RG5、RG6 顺序提交。

- [ ] **Step 6: 外层文档、submodule pointer 与最终提交**

```powershell
git add clients/Voxia docs/10-active/voxel-far-field `
  docs/00-current-truth/design/client/streaming-lod.md `
  docs/00-current-truth/impl/README.md `
  docs/00-current-truth/impl/known_gaps.md `
  docs/00-current-truth/source_index.md `
  docs/10-active/cross-cutting/_session-handoff.md
git diff --cached --check
git commit -m "docs(voxia): close far render governance"
```

- [ ] **Step 7: 推送两个仓库并检查 CI**

```powershell
git -C clients/Voxia push -u origin codex/voxia-render-governance
git push -u origin codex/voxia-render-governance
gh run list --branch codex/voxia-render-governance --limit 20
```

对两个仓库分别用 `gh pr view --head codex/voxia-render-governance --json number` 查 PR；不存在时创建 draft PR，再以具体 PR 号执行 `gh pr checks <number> --watch --fail-fast`。仓库 owner/name 必须先从各自 `git remote get-url origin` 解析，不能硬编码。如果 workflow 只在 `main/master` 或 PR 触发，创建 draft PR 后观察 checks；没有 workflow 时明确报告“未触发/未配置”，不能写成 CI 通过。

---

## Plan Self-Review

- Spec coverage：RG0 诊断、RG1 原子提交、RG2 采样、RG3a AO、RG3b 环境/阴影、RG4 材质纵深、RG5 预算、RG6 根级闭环均有独立任务与提交。
- Type consistency：lighting 统一使用 `FVoxiaVoxelSurfaceLightingArtifact` / `FVoxiaVoxelSurfaceLightingArtifactRef`；quality 统一使用 `EVoxiaFarRenderQuality`；CLI 统一归 `EnginePerf`。
- Boundary consistency：新增渲染状态均为 derived snapshot；没有服务端、wire、confirmed store、XZ/高度图或第二 root 修改。
- Evidence discipline：移动路线不以相邻帧像素差直接判错；严格像素门槛只用于固定环境静止序列；外部 D3D stall 始终保留。
- Execution choice：用户已要求后续自主决定且不要再提问；协作规则也不允许未获请求时派生 subagent，因此执行时固定使用 `superpowers:executing-plans` 内联推进。

---

## Execution Progress

截至 2026-07-21，客户端分支 `codex/voxia-render-governance` 已按顺序完成并独立提交：

- RG0 `7534507 feat(rendering): establish far render diagnostics`：五组单变量、四路线、120 张截图；证据 `.demo/observe/voxia_far_render_2026-07-20T17-32-17-827Z/`。
- RG1 `c527526 fix(rendering): commit far visibility atomically`：generation 2 原子切换 `0.122ms`，gap/overlap/stale 为零；证据 `.demo/observe/voxia_far_render_2026-07-20T17-49-56-763Z/`。
- RG2 `959a45a fix(rendering): stabilize far material sampling`：Source UV v3、单次 UV0 采样、77% 与 100% 对照均过静止门槛；证据 `.demo/observe/voxia_far_render_2026-07-20T18-08-29-383Z/`。
- RG3a `9987d83 feat(rendering): derive stable voxel ambient lighting`：surface 与 AO/sky lighting 同批发布、复用并写入 compact UV1，SVO cache v6；89/89 UE Automation、18/18 Node 测试通过。最终 Real-RHI 证据 `.demo/observe/voxia_far_render_2026-07-20T18-36-06-609Z/` 为 complete：33752/33752 lighting，静止闪烁比 `0.000092`，worker 相对 RG2 最坏 `1.030095×`，稳态 GT/GPU p50 最大增量 `0.018ms` / `0.011ms`，frame p95 `5.569–6.205ms`，gap/overlap/stale 为零。
- RG3b `fb58c4c feat(rendering): unify environment lighting and shadow tiers`：唯一环境组件持续维护 noon/dusk/night 与连续太阳、单主投影和天空/雾状态；旧四盏 fill rig 已删除；far patch 只让最近 ring 0 投影。91/91 UE Automation、20/20 Node 测试通过。最终 Real-RHI 证据 `.demo/observe/voxia_far_render_2026-07-20T18-57-11-372Z/` 为 complete：UDS 两盏方向光仅一盏投影、独立方向光 actor 为 0，818 个 far component 中 70 个投影；六组固定锚点最坏静态变化率 `0.000082`，frame p95 `5.322–5.713ms`，默认 GPU p95 `4.652–5.178ms`，VSM GPU p95 均值增量 `0.280333ms`，gap/overlap/stale 为零。
- RG4 `e46cbf4 feat(rendering): add natural far material depth`：确定性材质图用 UV1.R / UV1.G 的最小值驱动 DefaultLit Ambient Occlusion，保持单次 UV0 主纹理采样、无时序 dither，并新增空间亮度可读性指标。91/91 UE Automation、23/23 Node 测试通过，材质脚本二次运行 `changed=false`。最终 Real-RHI 证据 `.demo/observe/voxia_far_render_2026-07-20T19-09-55-861Z/` 为 complete：三锚点最坏静态变化率 `0.000096`，frame p95 `4.801–4.866ms`，GT p95 `1.635–1.718ms`，GPU p95 `4.110–4.151ms`，相对 RG3b 最坏增量 `-0.542ms`；夜间 mean luma `12.279216`、可读像素覆盖 `0.717534`、压黑像素 `0.073914`，gap/overlap/stale 为零。
- RG5 `b3d40d4 feat(rendering): enforce high-refresh far quality policy`：冻结 `performance_natural|quality_natural`，未知值在唯一根生成前以 `unsupported_far_render_quality` 失败；GI/反射、77% TSR、shadow ring、micro fade 与 TSR 时域稳定参数由同一 policy 应用并可回读。旧散落的云、Lumen、VSM 与 TSR CVar 已从 `DefaultEngine.ini` 清除。首轮无 TSR policy 的诊断证据 `.demo/observe/voxia_far_render_2026-07-20T19-24-13-854Z/` 因静止变化率 `0.003780` 被正确拒绝；最小 TSR 合同进入 policy 后，性能档证据 `.demo/observe/voxia_far_render_2026-07-20T19-29-07-592Z/` 为 complete：静止变化率 `0.000134`，最坏 frame p95/p99 `4.768/6.250ms`、GT p95 `1.800ms`、GPU p95 `4.002ms`，70/818 远景组件投影。质量档报告 `.demo/observe/voxia_far_render_2026-07-20T19-30-40-927Z/` 为 complete：静止变化率 `0.000084`，最坏 frame p95/p99 `5.152/6.584ms`、GT p95 `1.862ms`、GPU p95 `4.316ms`，105/818 组件投影。92/92 UE Automation、25/25 Node 测试通过；两档 generation crossing 均为 generation 2，gap/overlap/stale 为零，全程只使用客户端本地 WorldGen。

当前下一项是 RG6：执行唯一生产根联合验收、更新 current truth 与 handoff、提交并推送客户端/外层文档分支，随后只检查这两条分支对应的 CI；继续不启动、修改或验证服务端。
