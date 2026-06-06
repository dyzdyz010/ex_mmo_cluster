# Voxel Phenomenon

This directory owns condition-triggered physical phenomena such as combustion.

Boundary:

- Field kernels evolve continuous fields such as temperature.
- Phenomenon rules read field values, voxel truth, and material profiles.
- Phenomenon rules return structured effects only.
- `ChunkProcess` remains the authority that accepts or rejects truth writes.

Combustion is the first implementation slice. It uses material ignition
thresholds plus dynamic voxel attributes for fuel, oxygen, stage, smoke,
carbonization, and structural integrity. Burn residue is expressed as either a
material transition, such as wood to charcoal, or a cell clear effect for
materials that burn away completely.
