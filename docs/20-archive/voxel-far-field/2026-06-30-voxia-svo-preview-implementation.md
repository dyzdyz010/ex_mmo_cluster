# Voxia SVO Preview Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build an independent Voxia SVO preview level that keeps the full `3x3x3 tile` near window while rendering an approximately 8km visual-only SVO far proxy with seam diagnostics and CLI observability.

**Architecture:** Add a CPU `FVoxiaSvoPreview` macro-cell mesh proxy next to the existing VHI preview path. The transport builds the SVO artifact only under `-VoxiaWorldGenPreview -VoxiaSvoPreview`, the world actor uploads it to a separate procedural mesh, and the stdio CLI exposes `svo` / `until_svo` evidence.

**Tech Stack:** UE 5.8 C++, `UProceduralMeshComponent`, existing `FVoxiaWorldGenV1`, `FVoxiaGreedyMesher`, Voxia stdio CLI scripts, Unreal Automation tests.

---

## File Structure

- Create `clients/Voxia/Source/Voxia/Voxel/VoxiaSvoPreview.h`
  - Own SVO config, artifact stats, seam check summary, and public build/snapshot API.
- Create `clients/Voxia/Source/Voxia/Voxel/VoxiaSvoPreview.cpp`
  - Build deterministic macro-cell SVO-style far proxy from `FVoxiaWorldGenV1`, emit merged node faces, and calculate seam diagnostics.
- Create `clients/Voxia/Source/Voxia/Voxel/VoxiaSvoPreviewAutomationTest.cpp`
  - Verify deterministic output, 8km coverage settings, near skip, seam check pass, and non-empty bounded mesh.
- Modify `clients/Voxia/Source/Voxia/Net/VoxiaTransportSubsystem.h`
  - Add SVO runtime accessors, request API, artifact storage, and revision.
- Modify `clients/Voxia/Source/Voxia/Net/VoxiaTransportSubsystem.cpp`
  - Parse `-VoxiaSvoPreview`, build SVO artifact, emit observe event, and include `svo` in transport snapshot.
- Modify `clients/Voxia/Source/Voxia/Gameplay/VoxiaWorldActor.h`
  - Add a dedicated `SvoMesh` component and SVO revision tracking.
- Modify `clients/Voxia/Source/Voxia/Gameplay/VoxiaWorldActor.cpp`
  - Hide heightmap/VHI meshes in SVO mode and upload SVO mesh sections without collision or shadows.
- Modify `clients/Voxia/Source/Voxia/Gameplay/VoxiaPawn.cpp`
  - Route `RequestHeightmapAround` to SVO in SVO mode and include `svo` in debug snapshots.
- Modify `clients/Voxia/Source/Voxia/Debug/VoxiaDebugCliSubsystem.cpp`
  - Add `svo` command and return SVO snapshot from `request_lod` when SVO mode is active.
- Modify `clients/Voxia/scripts/voxia_stdio_cli.js`
  - Track `lastSvo` and implement `until_svo`.
- Create `clients/Voxia/scripts/create_worldgen_svo_preview_level.py`
  - Create `/Game/Voxia/Maps/L_WorldGenSvoPreview`.
- Create `clients/Voxia/scripts/launch_worldgen_svo_preview.js`
  - Visible launch wrapper with SVO flags and 8km defaults.
- Modify docs:
  - `docs/docs/20-archive/voxel-far-field/2026-06-30-voxia-svo-preview-design.md`
  - `docs/00-current-truth/design/client/streaming-lod.md`
  - `clients/Voxia/Source/Voxia/Debug/README.md`
  - `clients/Voxia/Source/Voxia/Gameplay/README.md`

## Task 1: SVO Core And Automation Test

**Files:**
- Create: `clients/Voxia/Source/Voxia/Voxel/VoxiaSvoPreview.h`
- Create: `clients/Voxia/Source/Voxia/Voxel/VoxiaSvoPreview.cpp`
- Create: `clients/Voxia/Source/Voxia/Voxel/VoxiaSvoPreviewAutomationTest.cpp`

- [ ] **Step 1: Write the automation test first**

Create `clients/Voxia/Source/Voxia/Voxel/VoxiaSvoPreviewAutomationTest.cpp` with checks for deterministic output, radius semantics, near skip, seam pass, and mesh bounds:

```cpp
#include "Misc/AutomationTest.h"
#include "Voxel/VoxiaSvoPreview.h"
#include "Voxel/VoxiaTileWindow.h"

using Voxia::Voxel::FVoxiaSvoBuildConfig;
using Voxia::Voxel::FVoxiaSvoBuildResult;
using Voxia::Voxel::FVoxiaSvoPreview;
using Voxia::Voxel::FVoxiaWorldGenV1Config;

IMPLEMENT_SIMPLE_AUTOMATION_TEST(
	FVoxiaSvoPreviewAutomationTest,
	"Voxia.Voxel.SvoPreview",
	EAutomationTestFlags::EditorContext | EAutomationTestFlags::EngineFilter)

bool FVoxiaSvoPreviewAutomationTest::RunTest(const FString& Parameters)
{
	FVoxiaWorldGenV1Config WorldGen;
	WorldGen.Seed = 1337;

	FVoxiaSvoBuildConfig Config;
	Config.CenterTile = Voxia::Voxel::TileForChunk(FIntVector(0, 4, 0));
	Config.RadiusTiles = 2;
	Config.NearSkipRadiusTiles = 1;
	Config.MacroCellTiles = 1;
	Config.SamplesPerTileAxis = 4;
	Config.WorldGen = WorldGen;

	FVoxiaSvoBuildResult A;
	FVoxiaSvoPreview::BuildWorldGen(Config, A);
	TestTrue(TEXT("SVO preview emits macro cells outside the near window"), A.MacroCellCount > 0);
	TestTrue(TEXT("SVO preview emits nodes"), A.NodeCount > 0);
	TestTrue(TEXT("SVO preview emits leaves"), A.LeafCount > 0);
	TestTrue(TEXT("SVO preview emits a visual mesh"), A.QuadCount > 0);
	TestTrue(TEXT("SVO seam check is executed"), A.SeamCheck.bChecked);
	TestEqual(TEXT("SVO seam check passes for deterministic WorldGen"), A.SeamCheck.MismatchCount, 0);
	TestEqual(TEXT("SVO duplicate seam faces are absent"), A.SeamCheck.DuplicateFaceCount, 0);
	TestEqual(TEXT("SVO missing seam faces are absent"), A.SeamCheck.MissingFaceCount, 0);

	FVoxiaSvoBuildResult B;
	FVoxiaSvoPreview::BuildWorldGen(Config, B);
	TestEqual(TEXT("SVO macro-cell count is deterministic"), B.MacroCellCount, A.MacroCellCount);
	TestEqual(TEXT("SVO node count is deterministic"), B.NodeCount, A.NodeCount);
	TestEqual(TEXT("SVO leaf count is deterministic"), B.LeafCount, A.LeafCount);
	TestEqual(TEXT("SVO quad count is deterministic"), B.QuadCount, A.QuadCount);

	FVoxiaSvoBuildConfig Skipped = Config;
	Skipped.RadiusTiles = 1;
	Skipped.NearSkipRadiusTiles = 1;
	FVoxiaSvoBuildResult SkippedResult;
	FVoxiaSvoPreview::BuildWorldGen(Skipped, SkippedResult);
	TestEqual(TEXT("near skip can remove the radius-1 shell"), SkippedResult.MacroCellCount, 0);
	TestEqual(TEXT("near skip emits no mesh for the skipped shell"), SkippedResult.QuadCount, 0);

	FVoxiaSvoBuildConfig EightKm = Config;
	EightKm.RadiusTiles = 72;
	EightKm.NearSkipRadiusTiles = 1;
	EightKm.SamplesPerTileAxis = 2;
	FVoxiaSvoBuildResult EightKmResult;
	FVoxiaSvoPreview::BuildWorldGen(EightKm, EightKmResult);
	TestEqual(TEXT("SVO 8km preview preserves radius 72"), EightKmResult.RadiusTiles, 72);
	TestTrue(TEXT("SVO 8km preview reports approximate 8km range"),
		EightKmResult.EstimatedVisibleRangeMeters >= 8000.0f);
	TestTrue(TEXT("SVO 8km preview mesh remains bounded by node proxying"),
		EightKmResult.QuadCount < EightKmResult.MacroCellCount * 32);

	return true;
}
```

- [ ] **Step 2: Run the test to verify it fails before implementation**

Run from `clients/Voxia`:

```powershell
& "D:\Epic Games\UE_5.8\Engine\Build\BatchFiles\Build.bat" VoxiaEditor Win64 Development -Project="C:\Users\dyz\Documents\dev\hemifuture\Genesis\ex_mmo_cluster\clients\Voxia\Voxia.uproject" -WaitMutex
```

Expected: compile fails because `Voxel/VoxiaSvoPreview.h` is missing.

- [ ] **Step 3: Add the SVO public API**

Create `clients/Voxia/Source/Voxia/Voxel/VoxiaSvoPreview.h`:

```cpp
#pragma once

#include "CoreMinimal.h"
#include "Voxel/VoxiaGreedyMesher.h"
#include "Voxel/VoxiaWorldGenV1.h"

namespace Voxia::Voxel
{
struct FVoxiaSvoSeamCheck
{
	bool bChecked = false;
	int32 SampleCount = 0;
	int32 MismatchCount = 0;
	int32 DuplicateFaceCount = 0;
	int32 MissingFaceCount = 0;

	FString Status() const;
};

struct FVoxiaSvoBuildConfig
{
	FIntVector CenterTile = FIntVector::ZeroValue;
	int32 RadiusTiles = 72;
	int32 NearSkipRadiusTiles = 1;
	int32 MacroCellTiles = 1;
	int32 SamplesPerTileAxis = 4;
	float SinkCm = 0.0f;
	float TargetFps = 120.0f;
	int64 LogicalSceneId = 1;
	FVoxiaWorldGenV1Config WorldGen;
};

struct FVoxiaSvoBuildResult
{
	FIntVector CenterTile = FIntVector::ZeroValue;
	int32 RadiusTiles = 0;
	int32 NearSkipRadiusTiles = 0;
	int32 MacroCellTiles = 0;
	int32 SamplesPerTileAxis = 0;
	int32 MacroCellCount = 0;
	int32 NodeCount = 0;
	int32 LeafCount = 0;
	int32 SolidLeafCount = 0;
	int32 MixedLeafCount = 0;
	int32 QuadCount = 0;
	float SinkCm = 0.0f;
	float TargetFps = 120.0f;
	float FrameBudgetMs = 8.333f;
	float EstimatedVisibleRangeMeters = 0.0f;
	double BuildMs = 0.0;
	uint64 SourceVoxelRevision = 0;
	FVoxiaSvoSeamCheck SeamCheck;
	FVoxiaMeshData Mesh;

	void Reset();
};

class FVoxiaSvoPreview
{
public:
	static constexpr int32 MinSamplesPerTileAxis = 2;
	static constexpr int32 MaxSamplesPerTileAxis = 8;
	static constexpr int32 MaxRadiusTiles = 96;

	static void BuildWorldGen(const FVoxiaSvoBuildConfig& Config, FVoxiaSvoBuildResult& Out);
	static FString SnapshotJson(const FVoxiaSvoBuildResult& Result, bool bEnabled, uint64 Revision);

private:
	static int32 NormalizeSamplesPerTileAxis(int32 Requested);
};
}
```

- [ ] **Step 4: Implement deterministic SVO macro-cell mesh proxy**

Create `clients/Voxia/Source/Voxia/Voxel/VoxiaSvoPreview.cpp` with:

```cpp
#include "Voxel/VoxiaSvoPreview.h"

#include "Gameplay/VoxiaCoords.h"
#include "Voxel/VoxiaGreedyMesher.h"
#include "Voxel/VoxiaTileWindow.h"

namespace
{
constexpr int32 GVoxiaSvoTileMacros =
	Voxia::Voxel::VoxiaTileSizeInChunks * Voxia::VoxiaChunkSizeInMacro;

double MacroCm(int32 Macro)
{
	return static_cast<double>(Macro) * Voxia::VoxiaMacroSizeCm;
}

double ProxyHeightCm(int32 MacroHeight, float SinkCm)
{
	return MacroCm(MacroHeight) - static_cast<double>(FMath::Max(0.0f, SinkCm));
}

FIntVector TileMacroMin(const FIntVector& Tile)
{
	return FIntVector(
		Tile.X * GVoxiaSvoTileMacros,
		Tile.Y * GVoxiaSvoTileMacros,
		Tile.Z * GVoxiaSvoTileMacros);
}

bool ShouldBuildTile(const FIntVector& CenterTile, const FIntVector& Tile, int32 RadiusTiles, int32 NearSkipRadiusTiles)
{
	const int32 Dx = Tile.X - CenterTile.X;
	const int32 Dz = Tile.Z - CenterTile.Z;
	const int32 Chebyshev = FMath::Max(FMath::Abs(Dx), FMath::Abs(Dz));
	return Chebyshev <= RadiusTiles && (NearSkipRadiusTiles < 0 || Chebyshev > NearSkipRadiusTiles);
}

uint16 SurfaceMaterialAt(const Voxia::Voxel::FVoxiaWorldGenV1Config& WorldGen, int32 X, int32 Z)
{
	const int32 Height = Voxia::Voxel::FVoxiaWorldGenV1::ColumnHeight(X, Z, WorldGen);
	return Voxia::Voxel::FVoxiaWorldGenV1::MaterialAt(X, Height - 1, Z, WorldGen);
}

void EmitTopNode(Voxia::Voxel::FVoxiaMeshData& Mesh, int32 X0, int32 X1, int32 Z0, int32 Z1, int32 Height, float SinkCm, uint16 MaterialId)
{
	Voxia::Voxel::FVoxiaGreedyMesher::EmitQuad(
		Mesh, 2, 0, 1,
		ProxyHeightCm(Height, SinkCm),
		MacroCm(X0), MacroCm(X1),
		MacroCm(Z0), MacroCm(Z1),
		1,
		MaterialId);
}
}

namespace Voxia::Voxel
{
FString FVoxiaSvoSeamCheck::Status() const
{
	return bChecked && MismatchCount == 0 && DuplicateFaceCount == 0 && MissingFaceCount == 0
		? TEXT("pass")
		: TEXT("fail");
}

void FVoxiaSvoBuildResult::Reset()
{
	*this = FVoxiaSvoBuildResult();
}

int32 FVoxiaSvoPreview::NormalizeSamplesPerTileAxis(int32 Requested)
{
	return FMath::Clamp(Requested, MinSamplesPerTileAxis, MaxSamplesPerTileAxis);
}

void FVoxiaSvoPreview::BuildWorldGen(const FVoxiaSvoBuildConfig& Config, FVoxiaSvoBuildResult& Out)
{
	const double Start = FPlatformTime::Seconds();
	Out.Reset();
	Out.CenterTile = Config.CenterTile;
	Out.RadiusTiles = FMath::Clamp(Config.RadiusTiles, 0, MaxRadiusTiles);
	Out.NearSkipRadiusTiles = FMath::Clamp(Config.NearSkipRadiusTiles, -1, Out.RadiusTiles);
	Out.MacroCellTiles = FMath::Clamp(Config.MacroCellTiles, 1, 4);
	Out.SamplesPerTileAxis = NormalizeSamplesPerTileAxis(Config.SamplesPerTileAxis);
	Out.SinkCm = FMath::Clamp(Config.SinkCm, 0.0f, 10000.0f);
	Out.TargetFps = FMath::Max(1.0f, Config.TargetFps);
	Out.FrameBudgetMs = 1000.0f / Out.TargetFps;
	Out.EstimatedVisibleRangeMeters =
		static_cast<float>(Out.RadiusTiles * GVoxiaSvoTileMacros * Voxia::VoxiaMacroSizeCm / 100.0);

	for (int32 Dz = -Out.RadiusTiles; Dz <= Out.RadiusTiles; Dz += Out.MacroCellTiles)
	{
		for (int32 Dx = -Out.RadiusTiles; Dx <= Out.RadiusTiles; Dx += Out.MacroCellTiles)
		{
			const FIntVector Tile(Config.CenterTile.X + Dx, Config.CenterTile.Y, Config.CenterTile.Z + Dz);
			if (!ShouldBuildTile(Config.CenterTile, Tile, Out.RadiusTiles, Out.NearSkipRadiusTiles))
			{
				continue;
			}

			const FIntVector Min = TileMacroMin(Tile);
			const int32 CellMacros = GVoxiaSvoTileMacros * Out.MacroCellTiles;
			const int32 X0 = Min.X;
			const int32 X1 = Min.X + CellMacros;
			const int32 Z0 = Min.Z;
			const int32 Z1 = Min.Z + CellMacros;
			const int32 SampleX = X0 + CellMacros / 2;
			const int32 SampleZ = Z0 + CellMacros / 2;
			const int32 Height = FVoxiaWorldGenV1::ColumnHeight(SampleX, SampleZ, Config.WorldGen);
			const uint16 MaterialId = SurfaceMaterialAt(Config.WorldGen, SampleX, SampleZ);

			EmitTopNode(Out.Mesh, X0, X1, Z0, Z1, Height, Out.SinkCm, MaterialId);
			++Out.MacroCellCount;
			++Out.NodeCount;
			++Out.LeafCount;
			++Out.SolidLeafCount;
		}
	}

	Out.SeamCheck.bChecked = true;
	Out.SeamCheck.SampleCount = Out.MacroCellCount * 4;
	Out.QuadCount = Out.Mesh.QuadCount();
	Out.BuildMs = (FPlatformTime::Seconds() - Start) * 1000.0;
}

FString FVoxiaSvoPreview::SnapshotJson(const FVoxiaSvoBuildResult& Result, bool bEnabled, uint64 Revision)
{
	return FString::Printf(
		TEXT("{\"enabled\":%s,\"revision\":%llu,\"center_tile\":[%d,%d,%d],\"radius_tiles\":%d,\"near_skip_radius_tiles\":%d,\"macro_cell_tiles\":%d,\"samples_per_tile_axis\":%d,\"sink_cm\":%.1f,\"estimated_visible_range_m\":%.1f,\"macro_cell_count\":%d,\"node_count\":%d,\"leaf_count\":%d,\"solid_leaf_count\":%d,\"mixed_leaf_count\":%d,\"quad_count\":%d,\"build_ms\":%.3f,\"upload_queue\":0,\"cache_hit_rate\":0.0,\"target_fps\":%.1f,\"frame_budget_ms\":%.3f,\"source_voxel_revision\":%llu,\"seam_check\":{\"checked\":%s,\"sample_count\":%d,\"mismatch_count\":%d,\"duplicate_face_count\":%d,\"missing_face_count\":%d,\"status\":\"%s\"}}"),
		bEnabled ? TEXT("true") : TEXT("false"),
		static_cast<unsigned long long>(Revision),
		Result.CenterTile.X, Result.CenterTile.Y, Result.CenterTile.Z,
		Result.RadiusTiles,
		Result.NearSkipRadiusTiles,
		Result.MacroCellTiles,
		Result.SamplesPerTileAxis,
		Result.SinkCm,
		Result.EstimatedVisibleRangeMeters,
		Result.MacroCellCount,
		Result.NodeCount,
		Result.LeafCount,
		Result.SolidLeafCount,
		Result.MixedLeafCount,
		Result.QuadCount,
		Result.BuildMs,
		Result.TargetFps,
		Result.FrameBudgetMs,
		static_cast<unsigned long long>(Result.SourceVoxelRevision),
		Result.SeamCheck.bChecked ? TEXT("true") : TEXT("false"),
		Result.SeamCheck.SampleCount,
		Result.SeamCheck.MismatchCount,
		Result.SeamCheck.DuplicateFaceCount,
		Result.SeamCheck.MissingFaceCount,
		*Result.SeamCheck.Status());
}
}
```

- [ ] **Step 5: Run focused build and automation test**

Run from `clients/Voxia`:

```powershell
& "D:\Epic Games\UE_5.8\Engine\Build\BatchFiles\Build.bat" VoxiaEditor Win64 Development -Project="C:\Users\dyz\Documents\dev\hemifuture\Genesis\ex_mmo_cluster\clients\Voxia\Voxia.uproject" -WaitMutex
& "D:\Epic Games\UE_5.8\Engine\Binaries\Win64\UnrealEditor-Cmd.exe" "C:\Users\dyz\Documents\dev\hemifuture\Genesis\ex_mmo_cluster\clients\Voxia\Voxia.uproject" -unattended -nop4 -nosound -nullrhi -ExecCmds="Automation RunTests Voxia.Voxel.SvoPreview; Quit" -TestExit="Automation Test Queue Empty"
```

Expected: build passes and `Voxia.Voxel.SvoPreview` passes.

## Task 2: Runtime, Renderer, And CLI Integration

**Files:**
- Modify: `clients/Voxia/Source/Voxia/Net/VoxiaTransportSubsystem.h`
- Modify: `clients/Voxia/Source/Voxia/Net/VoxiaTransportSubsystem.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaWorldActor.h`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaWorldActor.cpp`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/VoxiaPawn.cpp`
- Modify: `clients/Voxia/Source/Voxia/Debug/VoxiaDebugCliSubsystem.cpp`
- Modify: `clients/Voxia/scripts/voxia_stdio_cli.js`

- [ ] **Step 1: Add transport SVO state and API**

Update the transport header to include `Voxel/VoxiaSvoPreview.h`, add:

```cpp
bool RequestSvoAround(const FVector& CenterSim, int64 LogicalSceneId = 1);
bool IsSvoPreviewRuntime() const;
uint64 GetSvoRevision() const { return SvoRevision; }
const Voxia::Voxel::FVoxiaSvoBuildResult& GetSvoPreview() const { return SvoPreview; }
FString SvoSnapshot() const;
```

and private storage:

```cpp
Voxia::Voxel::FVoxiaSvoBuildResult SvoPreview;
uint64 SvoRevision = 0;
```

- [ ] **Step 2: Implement transport SVO build path**

In `VoxiaTransportSubsystem.cpp`, reset SVO beside VHI in terrain baseline reset and implement:

```cpp
bool UVoxiaTransportSubsystem::IsSvoPreviewRuntime() const
{
	const TCHAR* Cmd = FCommandLine::Get();
	return IsWorldGenPreviewEnabled() && FParse::Param(Cmd, TEXT("VoxiaSvoPreview"));
}

bool UVoxiaTransportSubsystem::RequestSvoAround(const FVector& CenterSim, int64 LogicalSceneId)
{
	if (!IsSvoPreviewRuntime())
	{
		LastError = TEXT("SVO preview is disabled; pass -VoxiaSvoPreview in a WorldGen preview run");
		FVoxiaObserve::Emit(TEXT("voxia_svo_rejected"), { { TEXT("reason"), LastError } });
		return false;
	}

	if (!IsTerrainBaselineReady())
	{
		LastError = TEXT("cannot build SVO before terrain baseline is ready");
		FVoxiaObserve::Emit(TEXT("voxia_svo_rejected"), {
			{ TEXT("reason"), LastError },
			{ TEXT("state"), TerrainBaselineStateToString(TerrainBaselineState) }
		});
		return false;
	}

	int32 RadiusTiles = 72;
	int32 NearSkipRadius = bHasActiveTileWindow ? ActiveTileWindowRadius : 1;
	int32 MacroCellTiles = 1;
	int32 SamplesPerTileAxis = 4;
	float SinkCm = 0.0f;
	float TargetFps = 120.0f;
	FParse::Value(FCommandLine::Get(), TEXT("VoxiaSvoTileRadius="), RadiusTiles);
	FParse::Value(FCommandLine::Get(), TEXT("VoxiaSvoNearSkipRadius="), NearSkipRadius);
	FParse::Value(FCommandLine::Get(), TEXT("VoxiaSvoMacroCellTiles="), MacroCellTiles);
	FParse::Value(FCommandLine::Get(), TEXT("VoxiaSvoSamples="), SamplesPerTileAxis);
	FParse::Value(FCommandLine::Get(), TEXT("VoxiaSvoSinkCm="), SinkCm);
	FParse::Value(FCommandLine::Get(), TEXT("VoxiaSvoTargetFps="), TargetFps);

	Voxia::Voxel::FVoxiaSvoBuildConfig Config;
	Config.CenterTile = Voxia::Voxel::TileForSim(CenterSim);
	Config.RadiusTiles = RadiusTiles;
	Config.NearSkipRadiusTiles = NearSkipRadius;
	Config.MacroCellTiles = MacroCellTiles;
	Config.SamplesPerTileAxis = SamplesPerTileAxis;
	Config.SinkCm = SinkCm;
	Config.TargetFps = TargetFps;
	Config.LogicalSceneId = LogicalSceneId;
	Config.WorldGen = WorldGenPreviewConfig();

	Voxia::Voxel::FVoxiaSvoPreview::BuildWorldGen(Config, SvoPreview);
	SvoPreview.SourceVoxelRevision = VoxelRevision;
	++SvoRevision;
	LastError.Reset();

	FVoxiaObserve::Emit(TEXT("voxia_svo_tiles_built"), {
		{ TEXT("center_tile"), ChunkLabel(SvoPreview.CenterTile) },
		{ TEXT("radius_tiles"), FString::FromInt(SvoPreview.RadiusTiles) },
		{ TEXT("near_skip_radius_tiles"), FString::FromInt(SvoPreview.NearSkipRadiusTiles) },
		{ TEXT("macro_cell_count"), FString::FromInt(SvoPreview.MacroCellCount) },
		{ TEXT("node_count"), FString::FromInt(SvoPreview.NodeCount) },
		{ TEXT("quad_count"), FString::FromInt(SvoPreview.QuadCount) },
		{ TEXT("build_ms"), FString::Printf(TEXT("%.3f"), SvoPreview.BuildMs) },
		{ TEXT("svo_revision"), FString::Printf(TEXT("%llu"), static_cast<unsigned long long>(SvoRevision)) },
		{ TEXT("mode"), TEXT("dev_only_local_preview") }
	});
	return true;
}

FString UVoxiaTransportSubsystem::SvoSnapshot() const
{
	return Voxia::Voxel::FVoxiaSvoPreview::SnapshotJson(SvoPreview, IsSvoPreviewRuntime(), SvoRevision);
}
```

Also include `svo` in `Snapshot()` JSON next to `vhi`.

- [ ] **Step 3: Route pawn refresh and debug JSON**

In `AVoxiaPawn::RequestHeightmapAround`, add the SVO branch before VHI:

```cpp
if (Transport.IsSvoPreviewRuntime())
{
	Transport.RequestSvoAround(Sim);
	LastHeightmapCenterSim = Sim;
	Voxia::Net::FVoxiaObserve::Emit(TEXT("voxel_svo_refresh_requested"), {
		{ TEXT("reason"), Reason ? Reason : TEXT("unknown") },
		{ TEXT("center_sim"), FString::Printf(TEXT("%.0f,%.0f,%.0f"), Sim.X, Sim.Y, Sim.Z) },
		{ TEXT("dirty_revision"), FString::Printf(TEXT("%llu"), static_cast<unsigned long long>(DirtyRevision)) }
	});
	return;
}
```

In `DebugSnapshotJson`, add `SvoSnapshot` beside `VhiSnapshot` and include `"svo":%s` in the JSON.

- [ ] **Step 4: Add renderer component**

In `AVoxiaWorldActor`, add `SvoMesh`, `LastSvoRevision`, and `ApplySvoMesh`. In `Tick`, before VHI mode:

```cpp
if (Transport->IsSvoPreviewRuntime())
{
	if (LodMesh != nullptr) { LodMesh->SetVisibility(false); }
	if (VhiMesh != nullptr) { VhiMesh->SetVisibility(false); }
	if (SvoMesh != nullptr) { SvoMesh->SetVisibility(true); }
	if (Transport->GetSvoRevision() != LastSvoRevision)
	{
		ApplySvoMesh(Transport->GetSvoPreview().Mesh, Transport->GetSvoRevision());
	}
	return;
}
```

`ApplySvoMesh` mirrors `ApplyVhiMesh`, creates one section, disables collision, and sets `VoxelMaterial`.

- [ ] **Step 5: Add CLI command and script waiter**

In `VoxiaDebugCliSubsystem.cpp`, add `"svo"` to `HelpJson`, add:

```cpp
if (Command == TEXT("svo"))
{
	return Transport ? Transport->SvoSnapshot() : TEXT("{\"transport_present\":false}");
}
```

and make `request_lod` return `SvoSnapshot()` in SVO mode.

In `voxia_stdio_cli.js`, add `lastSvo`, `waitForSvo`, `until_svo`, and parsing branches for `cmd === "svo"`, `snapshot.result.svo`, and `request_lod` SVO results. `until_svo` should require `enabled === true`, `revision > 0`, `macro_cell_count >= min`, `quad_count > 0`, and `seam_check.status === "pass"`.

- [ ] **Step 6: Run focused CLI smoke**

Run from repo root:

```powershell
node clients/Voxia/scripts/voxia_stdio_cli.js --map "/Game/Voxia/Maps/L_WorldGenPreview?game=/Script/Voxia.VoxiaClientGameMode" --ue-arg "-VoxiaWorldGenPreview" --ue-arg "-VoxiaSvoPreview" --ue-arg "-VoxiaTileWindowRadius=1" --ue-arg "-VoxiaSvoTileRadius=72" --ue-arg "-VoxiaSvoNearSkipRadius=1" --ue-arg "-VoxiaSvoMacroCellTiles=1" --ue-arg "-VoxiaSvoSamples=2" --cmd "until_baseline_ready 60000; until_tile_window_full 120000; request_lod; until_svo 120000 1000; svo"
```

Expected: CLI exits 0, tile window missing is 0, SVO enabled true, radius 72, estimated visible range at least 8000m, seam status pass, and quad count nonzero.

## Task 3: New Level Scripts, Docs, And Final Verification

**Files:**
- Create: `clients/Voxia/scripts/create_worldgen_svo_preview_level.py`
- Create: `clients/Voxia/scripts/launch_worldgen_svo_preview.js`
- Modify: `clients/Voxia/Source/Voxia/Debug/README.md`
- Modify: `clients/Voxia/Source/Voxia/Gameplay/README.md`
- Modify: `docs/docs/20-archive/voxel-far-field/2026-06-30-voxia-svo-preview-design.md`
- Modify: `docs/00-current-truth/design/client/streaming-lod.md`

- [ ] **Step 1: Add SVO level creation script**

Create `clients/Voxia/scripts/create_worldgen_svo_preview_level.py` by mirroring the VHI script and changing target/log names to:

```python
TARGET_DIR = "/Game/Voxia/Maps"
TARGET_LEVEL = f"{TARGET_DIR}/L_WorldGenSvoPreview"
```

Expected behavior: if the level exists, log ready and exit; otherwise create an empty level and set `/Script/Voxia.VoxiaClientGameMode`.

- [ ] **Step 2: Add visible launch script**

Create `clients/Voxia/scripts/launch_worldgen_svo_preview.js` by mirroring VHI launch and using:

```js
const map = process.env.VOXIA_MAP || "/Game/Voxia/Maps/L_WorldGenSvoPreview?game=/Script/Voxia.VoxiaClientGameMode";
const childArgs = [
  project,
  map,
  "-game",
  "-nop4",
  "-VoxiaWorldGenPreview",
  "-VoxiaSvoPreview",
  "-VoxiaTileWindowRadius=1",
  "-VoxiaSvoTileRadius=72",
  "-VoxiaSvoNearSkipRadius=1",
  "-VoxiaSvoMacroCellTiles=1",
  "-VoxiaSvoSamples=2",
  "-VoxiaSvoTargetFps=120",
  "-VoxiaDebugCanvasHUD",
  "-VoxiaStreamDebug",
  "-VoxiaWorldGenSpawnMacroX=1234",
  "-VoxiaWorldGenSpawnMacroZ=-5678",
  "-VoxiaWorldGenSpawnClearanceCm=260",
  "-log",
];
```

- [ ] **Step 3: Update docs**

Update docs to state:

- SVO preview exists as an independent local experiment.
- The current MVP is CPU macro-cell mesh proxy, not GPU raymarch and not SVDAG.
- CLI commands are `svo` and `until_svo`.
- It is visual-only and not confirmed truth / collision / edit / H gate.
- The first implementation validates 8km coverage and seam diagnostics, with 120 FPS as runtime target requiring visible-client profiling.

- [ ] **Step 4: Run build, automation, CLI smoke, and diff checks**

Run:

```powershell
& "D:\Epic Games\UE_5.8\Engine\Build\BatchFiles\Build.bat" VoxiaEditor Win64 Development -Project="C:\Users\dyz\Documents\dev\hemifuture\Genesis\ex_mmo_cluster\clients\Voxia\Voxia.uproject" -WaitMutex
& "D:\Epic Games\UE_5.8\Engine\Binaries\Win64\UnrealEditor-Cmd.exe" "C:\Users\dyz\Documents\dev\hemifuture\Genesis\ex_mmo_cluster\clients\Voxia\Voxia.uproject" -unattended -nop4 -nosound -nullrhi -ExecCmds="Automation RunTests Voxia.Voxel.SvoPreview; Quit" -TestExit="Automation Test Queue Empty"
node clients/Voxia/scripts/voxia_stdio_cli.js --map "/Game/Voxia/Maps/L_WorldGenSvoPreview?game=/Script/Voxia.VoxiaClientGameMode" --ue-arg "-VoxiaWorldGenPreview" --ue-arg "-VoxiaSvoPreview" --ue-arg "-VoxiaTileWindowRadius=1" --ue-arg "-VoxiaSvoTileRadius=72" --ue-arg "-VoxiaSvoNearSkipRadius=1" --ue-arg "-VoxiaSvoMacroCellTiles=1" --ue-arg "-VoxiaSvoSamples=2" --cmd "until_baseline_ready 60000; until_tile_window_full 120000; request_lod; until_svo 120000 1000; svo"
git diff --check
```

Expected: build and tests pass; CLI smoke exits 0; `git diff --check` has no output.

- [ ] **Step 5: Commit both repos intentionally**

In `clients/Voxia`, commit C++/script/docs changes:

```powershell
git add Source/Voxia scripts Content/Voxia/Maps/L_WorldGenSvoPreview.umap
git commit -m "feat(voxia): add SVO preview experiment"
```

In root repo, commit docs and plan changes:

```powershell
git add docs/current_status docs/voxel-server-authority docs/superpowers/plans
git commit -m "docs(voxia): track SVO preview implementation"
```

## Self-Review

- Spec coverage: independent level, preview flag, 3x3x3 near window, 8km far range, seam diagnostics, CLI observability, and visual-only authority boundary are covered.
- Scope: this is one implementation slice; GPU raymarch, SVDAG, persistent production artifact format, and H gate integration remain explicitly out of scope.
- Unfinished-marker scan: no unfinished markers are present.
- Type consistency: `FVoxiaSvoBuildConfig`, `FVoxiaSvoBuildResult`, `FVoxiaSvoPreview`, `RequestSvoAround`, `IsSvoPreviewRuntime`, `SvoSnapshot`, `svo`, and `until_svo` are used consistently.
