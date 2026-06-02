import {
  AmbientLight,
  BackSide,
  Color,
  DirectionalLight,
  Float32BufferAttribute,
  Group,
  HemisphereLight,
  Mesh,
  MeshBasicMaterial,
  SphereGeometry,
  Vector3,
} from "three";
import type { BufferAttribute } from "three";

const SKY_RADIUS = 9000;
const DAY_NIGHT_CYCLE_SECONDS = 180;
const CELESTIAL_DISTANCE = 3800;

export interface SkyAtmosphere {
  group: Group;
  ambient: AmbientLight;
  hemisphere: HemisphereLight;
  sunLight: DirectionalLight;
  moonLight: DirectionalLight;
  fogColor: Color;
  backgroundColor: Color;
  update: (dtSecs: number, center: Vector3) => void;
  dispose: () => void;
}

export function createSkyAtmosphere(): SkyAtmosphere {
  const group = new Group();
  group.name = "voxel-sky-atmosphere";

  const skyGeometry = new SphereGeometry(SKY_RADIUS, 32, 16);
  const skyMaterial = new MeshBasicMaterial({
    side: BackSide,
    vertexColors: true,
    depthWrite: false,
    depthTest: false,
    fog: false,
  });
  const skyDome = new Mesh(skyGeometry, skyMaterial);
  skyDome.name = "voxel-sky-gradient-dome";
  skyDome.renderOrder = -1000;
  group.add(skyDome);

  const sunMaterial = new MeshBasicMaterial({ color: 0xfff1b8, fog: false });
  const moonMaterial = new MeshBasicMaterial({ color: 0xd8e8ff, fog: false });
  const sunMesh = new Mesh(new SphereGeometry(95, 16, 8), sunMaterial);
  const moonMesh = new Mesh(new SphereGeometry(70, 16, 8), moonMaterial);
  sunMesh.name = "voxel-sun-disc";
  moonMesh.name = "voxel-moon-disc";
  group.add(sunMesh, moonMesh);

  const ambient = new AmbientLight(0xffffff, 0.22);
  const hemisphere = new HemisphereLight(0xbfe2ff, 0x1a1210, 0.55);
  const sunLight = new DirectionalLight(0xfff2d1, 1.2);
  const moonLight = new DirectionalLight(0xaec9ff, 0.08);
  group.add(ambient, hemisphere, sunLight, sunLight.target, moonLight, moonLight.target);

  let timeOfDay = 0.19;
  const fogColor = new Color(0x9fc3e8);
  const backgroundColor = new Color(0x6fa9e6);

  const update = (dtSecs: number, center: Vector3) => {
    group.position.copy(center);
    timeOfDay = (timeOfDay + Math.max(0, dtSecs) / DAY_NIGHT_CYCLE_SECONDS) % 1;
    const phase = timeOfDay * Math.PI * 2;
    const sunDirection = new Vector3(
      Math.cos(phase) * 0.35,
      Math.sin(phase),
      Math.cos(phase) * 0.82,
    );
    if (sunDirection.lengthSq() === 0) {
      sunDirection.set(0, 1, 0);
    }
    sunDirection.normalize();
    const moonDirection = sunDirection.clone().multiplyScalar(-1);
    const sunAltitude = sunDirection.y;
    const moonAltitude = moonDirection.y;
    const dayAmount = smoothstep(-0.08, 0.45, sunAltitude);
    const twilightAmount = 1 - Math.min(1, Math.abs(sunAltitude) / 0.32);

    const top = mixColors(0x10172b, 0x5fb4ff, dayAmount).lerp(
      new Color(0xff935f),
      twilightAmount * 0.22,
    );
    const horizon = mixColors(0x1b2742, 0xc7e9ff, dayAmount).lerp(
      new Color(0xffb36b),
      twilightAmount * 0.55,
    );
    const bottom = mixColors(0x0d111a, 0xeff7ff, dayAmount).lerp(
      new Color(0xffd7a0),
      twilightAmount * 0.25,
    );
    writeSkyDomeColors(skyGeometry, top, horizon, bottom);

    fogColor.copy(horizon).lerp(new Color(0x151c2f), Math.max(0, -sunAltitude) * 0.35);
    backgroundColor.copy(top).lerp(horizon, 0.35);
    ambient.intensity = 0.08 + dayAmount * 0.24 + Math.max(0, moonAltitude) * 0.04;
    hemisphere.intensity = 0.18 + dayAmount * 0.52;
    hemisphere.color.copy(mixColors(0x88a8ff, 0xccecff, dayAmount));
    hemisphere.groundColor.copy(mixColors(0x080912, 0x3a2a1d, dayAmount));
    sunLight.intensity = Math.max(0, sunAltitude) * 1.45;
    moonLight.intensity = Math.max(0, moonAltitude) * 0.34;

    sunMesh.position.copy(sunDirection).multiplyScalar(CELESTIAL_DISTANCE);
    moonMesh.position.copy(moonDirection).multiplyScalar(CELESTIAL_DISTANCE);
    sunLight.position.copy(sunDirection).multiplyScalar(CELESTIAL_DISTANCE * 0.18);
    moonLight.position.copy(moonDirection).multiplyScalar(CELESTIAL_DISTANCE * 0.18);
    sunMesh.visible = sunAltitude > -0.1;
    moonMesh.visible = moonAltitude > -0.1;
  };

  update(0, new Vector3());

  return {
    group,
    ambient,
    hemisphere,
    sunLight,
    moonLight,
    fogColor,
    backgroundColor,
    update,
    dispose(): void {
      skyGeometry.dispose();
      skyMaterial.dispose();
      sunMesh.geometry.dispose();
      sunMaterial.dispose();
      moonMesh.geometry.dispose();
      moonMaterial.dispose();
      group.clear();
    },
  };
}

function writeSkyDomeColors(
  geometry: SphereGeometry,
  top: Color,
  horizon: Color,
  bottom: Color,
): void {
  const position = geometry.getAttribute("position") as BufferAttribute;
  let color = geometry.getAttribute("color") as BufferAttribute | undefined;
  if (!color) {
    color = new Float32BufferAttribute(new Float32Array(position.count * 3), 3);
    geometry.setAttribute("color", color);
  }

  for (let i = 0; i < position.count; i += 1) {
    const normalizedY = position.getY(i) / SKY_RADIUS;
    const t = (normalizedY + 1) / 2;
    const mixed =
      t < 0.5 ? bottom.clone().lerp(horizon, t * 2) : horizon.clone().lerp(top, (t - 0.5) * 2);
    color.setXYZ(i, mixed.r, mixed.g, mixed.b);
  }
  color.needsUpdate = true;
}

function mixColors(a: number, b: number, amount: number): Color {
  return new Color(a).lerp(new Color(b), amount);
}

function smoothstep(edge0: number, edge1: number, value: number): number {
  const t = Math.max(0, Math.min(1, (value - edge0) / (edge1 - edge0)));
  return t * t * (3 - 2 * t);
}
