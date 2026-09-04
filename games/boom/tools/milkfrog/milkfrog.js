/* =====================================================================
 * 奶蛙 MilkFrog · Three.js 精确重建（第一阶段：自然站立静态模型）
 * 唯一造型基准：assets/images/references/milk_frog_full_body_idle_cutout.png
 *  - 一体化连续梨形躯干（自定义 BufferGeometry，非球体拼接）
 *  - 自然站立、双手抱腹；禁止托腮/捂嘴/思考手势
 *  - 根节点 MilkFrog，Y 轴向上，+Z 为正脸，身高归一化 2，双脚 y=0
 * 大笑图仅用于理解身体结构（尾巴/手脚），默认表情为呆滞平静。
 * ===================================================================== */
import * as THREE from 'three';
import { OrbitControls } from 'three/addons/controls/OrbitControls.js';
import { GLTFExporter } from 'three/addons/exporters/GLTFExporter.js';
import { RoomEnvironment } from 'three/addons/environments/RoomEnvironment.js';

/* ---------------------------------------------------------------- utils */
function catmullRom(p0, p1, p2, p3, t) {
  const t2 = t * t, t3 = t2 * t;
  return 0.5 * ((2 * p1) + (-p0 + p2) * t +
    (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 +
    (-p0 + 3 * p1 - 3 * p2 + p3) * t3);
}

/* 对分段控制点 [v0, v1, ...] 做 Catmull-Rom 插值，v0 升序，u∈[0,1] 按弧长 */
/* 对分段控制点做向心(chordal α=0.5) Catmull-Rom 插值。
   PROFILE 的控制点间距很不均（y 从 0.17 跳到 0.03），均匀参数化会过冲、
   导致环序非单调、局部面片翻转（躯干变双层壳）。Barry-Goldman 重参数化根治。 */
function sampleCurve(points, u) {
  const dims = points[0].length;
  const n = points.length - 1;
  const seg = Math.min(Math.floor(u * n), n - 1);
  const t = u * n - seg;
  const i0 = Math.max(seg - 1, 0), i1 = seg, i2 = seg + 1, i3 = Math.min(seg + 2, n);
  const p0 = points[i0], p1 = points[i1], p2 = points[i2], p3 = points[i3];
  const dist = (a, b) => {
    let s = 0;
    for (let d = 0; d < dims; d++) { const e = a[d] - b[d]; s += e * e; }
    return Math.sqrt(s);
  };
  const t0 = 0;
  const t1 = t0 + Math.max(1e-6, Math.sqrt(dist(p0, p1)));
  const t2 = t1 + Math.max(1e-6, Math.sqrt(dist(p1, p2)));
  const t3 = t2 + Math.max(1e-6, Math.sqrt(dist(p2, p3)));
  const tt = t1 + (t2 - t1) * t;
  const lerpD = (a, b, w) => {
    const o = new Array(dims);
    for (let d = 0; d < dims; d++) o[d] = a[d] + (b[d] - a[d]) * w;
    return o;
  };
  const A0 = lerpD(p0, p1, (tt - t0) / (t1 - t0));
  const A1 = lerpD(p1, p2, (tt - t1) / (t2 - t1));
  const A2 = lerpD(p2, p3, (tt - t2) / (t3 - t2));
  const B0 = lerpD(A0, A1, (tt - t0) / (t2 - t0));
  const B1 = lerpD(A1, A2, (tt - t1) / (t3 - t1));
  return lerpD(B0, B1, (tt - t1) / (t2 - t1));
}

function capsule(rTop, rBot, len, radial = 20) {
  const g = new THREE.CapsuleGeometry(Math.max(rBot, rTop), Math.max(len - Math.abs(rTop - rBot), 0.001), 8, radial);
  return g;
}

/* 让沿 +Y 建模、已含真实长度的几何，从 from 指向 to（仅旋转+定位，不缩放） */
function orientBetween(mesh, from, to) {
  const dir = new THREE.Vector3().subVectors(to, from);
  const len = dir.length();
  mesh.position.copy(from).addScaledVector(dir, 0.5);
  mesh.quaternion.setFromUnitVectors(new THREE.Vector3(0, 1, 0), dir.clone().normalize());
  mesh.userData.segLen = len;
  return mesh;
}

/* ---------------------------------------------------------------- 材质 */
function gradientTexture(stops) {
  const c = document.createElement('canvas');
  c.width = 2; c.height = 512;
  const g = c.getContext('2d');
  const grad = g.createLinearGradient(0, 0, 0, 512);
  for (const [pos, col] of stops) grad.addColorStop(pos, col);
  g.fillStyle = grad;
  g.fillRect(0, 0, 2, 512);
  const tex = new THREE.CanvasTexture(c);
  tex.colorSpace = THREE.SRGBColorSpace;
  tex.wrapS = tex.wrapT = THREE.ClampToEdgeWrapping;
  tex.flipY = false;   // 身体 UV v=0 在头顶 → 画布顶部对应头
  return tex;
}

/* 参考图为高饱和蛋黄黄（柔光阵列下不压深，直接给饱和色） */
const SKIN_GRAD = [
  [0.00, '#f2b334'],   // 头顶
  [0.30, '#f7c245'],   // 上身：蛋黄黄
  [0.55, '#f4bb3f'],   // 腹部外围
  [0.80, '#eeb135'],
  [1.00, '#e6a52b'],   // 胯部：更深金黄
];

const M = {
  skin: new THREE.MeshPhysicalMaterial({
    map: gradientTexture(SKIN_GRAD),
    roughness: 0.82, metalness: 0.0,
    sheen: 0.35, sheenColor: new THREE.Color('#fff2c8'), sheenRoughness: 0.9,
    clearcoat: 0.04, clearcoatRoughness: 0.8,
    envMapIntensity: 0.55,
  }),
  belly: new THREE.MeshStandardMaterial({ color: '#e9d3a8', roughness: 0.88, metalness: 0.0, envMapIntensity: 0.55 }),
  hand: new THREE.MeshPhysicalMaterial({ color: '#9b8360', roughness: 0.8, metalness: 0.0, sheen: 0.25, sheenColor: new THREE.Color('#c9b795'), envMapIntensity: 0.55 }),
  foot: new THREE.MeshPhysicalMaterial({ color: '#a08560', roughness: 0.8, metalness: 0.0, sheen: 0.25, sheenColor: new THREE.Color('#cfbd9b'), envMapIntensity: 0.55 }),
  eyeShell: new THREE.MeshStandardMaterial({ color: '#dde6d8', roughness: 0.5, metalness: 0.0 }),
  pupil: new THREE.MeshStandardMaterial({ color: '#22201e', roughness: 0.35, metalness: 0.0 }),
  mouth: new THREE.MeshStandardMaterial({ color: '#5d4a33', roughness: 0.7, metalness: 0.0 }),
};

function mesh(geo, mat, name) {
  const m = new THREE.Mesh(geo, mat);
  m.name = name || 'mesh';
  m.castShadow = true;
  m.receiveShadow = true;
  return m;
}

/* =====================================================================
 * 躯干：连续梨形旋转面（头部较小、无肩颈分界、腹部前凸、背部后鼓）
 * 剖面为 X/Z 椭圆，椭圆中心随高度沿 S 曲线前后偏移（腰内收、腹前凸、臀后鼓）
 * ===================================================================== */
const BODY_TOP = 2.0, BODY_BOT = 0.40;

/* 控制点: [y, rx(半宽), rz(半深), centerZ(剖面中心前后偏移)] —— 按参考图比例测量
 * 上窄下宽的连续梨形：小头 → 无明显颈 → 腹部巨大前凸 → 胯内收（背/臀后鼓） */
const PROFILE = [
  [2.000, 0.0000, 0.0000, 0.002],
  [1.970, 0.0820, 0.0900, 0.010],
  [1.932, 0.1300, 0.1380, 0.016],
  [1.860, 0.1820, 0.1860, 0.016],
  [1.725, 0.2340, 0.2290, 0.006],  // 头最大处（小头、圆）
  [1.585, 0.2460, 0.2420, -0.010], // 下颌，仍与身连续
  [1.440, 0.2760, 0.2800, -0.030], // 肩/胸，背部向后鼓（centerZ 负）
  [1.280, 0.3480, 0.3680, -0.004],
  [1.110, 0.4480, 0.4860, 0.050],
  [0.950, 0.5120, 0.5560, 0.090],  // 腹部最大、向前突出
  [0.800, 0.5020, 0.5360, 0.070],
  [0.660, 0.4400, 0.4520, 0.010],
  [0.560, 0.3400, 0.3300, -0.055], // 胯内收，臀后鼓
  [0.500, 0.2350, 0.2200, -0.080],
  [0.460, 0.1400, 0.1250, -0.095],
  [0.432, 0.0550, 0.0450, -0.100], // 底部圆润收拢，无尖角
  [BODY_BOT, 0.0000, 0.0000, -0.102],
];

function profileAt(u) {
  const pts = sampleCurve(PROFILE, THREE.MathUtils.clamp(u, 0, 1));
  return { y: pts[0], rx: pts[1], rz: pts[2], cz: pts[3] };
}

function bodySurfaceY(y) { // 近似正面向前的半径（用于贴合放置）
  let best = PROFILE[0], bestD = 1e9;
  for (let i = 0; i < 160; i++) {
    const p = profileAt(i / 159);
    const d = Math.abs(p.y - y);
    if (d < bestD) { bestD = d; best = p; }
  }
  return best;
}

function buildBodyGeometry() {
  const RINGS = 96, SEGS = 96;
  const pos = [], uv = [], idx = [];
  for (let r = 0; r <= RINGS; r++) {
    const u = r / RINGS;
    const p = profileAt(u);
    for (let s = 0; s <= SEGS; s++) {
      const th = (s / SEGS) * Math.PI * 2;
      pos.push(p.rx * Math.cos(th), p.y, p.cz + p.rz * Math.sin(th));
      uv.push(s / SEGS, u);
    }
  }
  const row = SEGS + 1;
  for (let r = 0; r < RINGS; r++) {
    for (let s = 0; s < SEGS; s++) {
      const a = r * row + s, b = a + row;
      /* r 增大 → y 减小、θ 增大 → 从前视看为顺时针；
         必须用 (a,a+1,b)/(b,a+1,b+1) 才能得到朝外的 CCW 正面绕序 */
      idx.push(a, a + 1, b, b, a + 1, b + 1);
    }
  }
  const g = new THREE.BufferGeometry();
  g.setAttribute('position', new THREE.Float32BufferAttribute(pos, 3));
  g.setAttribute('uv', new THREE.Float32BufferAttribute(uv, 2));
  g.setIndex(idx);
  g.computeVertexNormals();
  return g;
}

/* 与躯干曲面共形的偏移壳（腹部奶油区/肚脐等贴面元素用） */
function shellGeometry(y0, y1, th0, th1, off, nY = 24, nT = 32) {
  const pos = [], uv = [], idx = [];
  /* 第一遍只生成位置，UV 留到按 x/y 平面椭圆映射 */
  for (let i = 0; i <= nY; i++) {
    const v = i / nY;
    // 由 y 反查 profile 的 u：沿控制表线性扫描
    const y = THREE.MathUtils.lerp(y0, y1, v);
    let pu = 0;
    for (let k = 0; k < 200; k++) {
      const uu = k / 199;
      if (profileAt(uu).y <= y) { pu = uu; break; }
      pu = uu;
    }
    const p = profileAt(pu);
    for (let j = 0; j <= nT; j++) {
      const th = THREE.MathUtils.lerp(th0, th1, j / nT);
      const rr = 1 + off / Math.max(0.05, Math.min(p.rx, p.rz));
      pos.push(p.rx * rr * Math.cos(th), y, p.cz + p.rz * rr * Math.sin(th));
      uv.push(0, 0); // 占位，下面重算
    }
  }
  /* UV：以贴片自身的 x/y 包围盒做椭圆映射，u 对应屏幕横向(-x→+x)，v 对应 y 由上向下
     （与 bellyGradientTexture 的 UV 像素行序一致：行0=v=0=顶部） */
  let minX = Infinity, maxX = -Infinity, minY = Infinity, maxY = -Infinity;
  for (let i = 0; i < pos.length; i += 3) {
    minX = Math.min(minX, pos[i]); maxX = Math.max(maxX, pos[i]);
    minY = Math.min(minY, pos[i + 1]); maxY = Math.max(maxY, pos[i + 1]);
  }
  for (let i = 0, k = 0; i < pos.length; i += 3, k++) {
    uv[k * 2] = (maxX - pos[i]) / (maxX - minX);
    uv[k * 2 + 1] = (maxY - pos[i + 1]) / (maxY - minY);
  }
  const row = nT + 1;
  for (let i = 0; i < nY; i++) {
    for (let j = 0; j < nT; j++) {
      const a = i * row + j, b = a + row;
      idx.push(a, b, a + 1, a + 1, b, b + 1);
    }
  }
  const g = new THREE.BufferGeometry();
  g.setAttribute('position', new THREE.Float32BufferAttribute(pos, 3));
  g.setAttribute('uv', new THREE.Float32BufferAttribute(uv, 2));
  g.setIndex(idx);
  g.computeVertexNormals();
  return g;
}

/* 腹部软渐变（奶油色大区域，中心实、边缘柔和渐隐）。
   直接按 UV 像素做椭圆距离衰减，不受"圆内切正方形"限制。 */
function bellyGradientTexture() {
  const S = 256;
  const c = document.createElement('canvas');
  c.width = c.height = S;
  const g = c.getContext('2d');
  const img = g.createImageData(S, S);
  for (let py = 0; py < S; py++) {
    /* alphaMap 采样绿色通道（NoColorSpace 线性），r=g=b=亮度 */
    const dy = (py / (S - 1) - 0.545) / 0.50;
    for (let px = 0; px < S; px++) {
      const dx = (px / (S - 1) - 0.5) / 0.5;
      const d = Math.sqrt(dx * dx + dy * dy);
      let a;
      if (d < 0.62) a = 250;
      else if (d >= 1.0) a = 0;
      else { const k = (1.0 - d) / 0.38; a = Math.round(250 * k * k * (3 - 2 * k)); } // smoothstep
      const i = (py * S + px) * 4;
      img.data[i] = img.data[i + 1] = img.data[i + 2] = a;
      img.data[i + 3] = 255;
    }
  }
  g.putImageData(img, 0, 0);
  const t = new THREE.CanvasTexture(c);
  t.colorSpace = THREE.NoColorSpace;
  return t;
}

/* =====================================================================
 * 组装 MilkFrog
 * ===================================================================== */
export function buildMilkFrog() {
  const root = new THREE.Group();
  root.name = 'MilkFrog';

  /* ---------------- Body：连续一体化梨形躯干 ---------------- */
  const body = mesh(buildBodyGeometry(), M.skin, 'Body');
  root.add(body);

  /* ---------------- Belly：大面积奶油色腹部，贴合曲面、边缘柔和 ---------------- */
  const belly = mesh(
    shellGeometry(0.745, 1.315, Math.PI * 0.20, Math.PI * 0.80, 0.0045),
    new THREE.MeshBasicMaterial({
      color: '#f2ddb0',   // 参考图腹部：比皮肤更浅的杏奶油（unlit 需压过受光皮肤亮度）
      alphaMap: bellyGradientTexture(),
      transparent: true, opacity: 0.95,
      depthWrite: false,
      /* 注意：不能用 polygonOffset——会把贴片深度拉向相机，导致背面正交视口透出贴片 */
    }),
    'Belly'
  );
  belly.renderOrder = 2;
  belly.receiveShadow = false;  // 装饰层不采样 shadow map：透明壳收影会产生脏斑
  belly.castShadow = false;
  root.add(belly);

  /* ---------------- Eyes / Pupils / Mouth：呆滞平静默认表情 ---------------- */
  const eyes = new THREE.Group(); eyes.name = 'Eyes';
  const pupils = new THREE.Group(); pupils.name = 'Pupils';
  const eyeGeo = new THREE.SphereGeometry(1, 28, 20);

  const faceP = bodySurfaceY(1.852);
  const eyeX = 0.058, eyeY = 1.842;
  [-1, 1].forEach((sx, i) => {
    const eye = mesh(eyeGeo, M.eyeShell, 'Eye' + (i ? 'R' : 'L'));
    const surf = bodySurfaceY(eyeY);
    eye.scale.set(0.070, 0.060, 0.044);           // 圆眼贴脸，不外凸出头廓
    eye.position.set(sx * eyeX, eyeY, surf.cz + surf.rz * 0.90);
    eye.rotation.y = sx * -0.28;                   // 微微外八字，朝 +Z 正脸
    eyes.add(eye);

    const pup = mesh(new THREE.SphereGeometry(1, 20, 14), M.pupil, 'Pupil' + (i ? 'R' : 'L'));
    pup.scale.set(0.026, 0.026, 0.020);
    pup.position.set(sx * (eyeX * 0.78), eyeY - 0.001, surf.cz + surf.rz * 0.90 + 0.039);
    pupils.add(pup);
  });
  root.add(eyes, pupils);

  const mouthP = bodySurfaceY(1.755);
  const mouth = mesh(new THREE.BoxGeometry(0.076, 0.013, 0.014), M.mouth, 'Mouth');
  mouth.position.set(-0.006, 1.752, mouthP.cz + mouthP.rz * 0.995 - 0.002); // 很短的平直嘴缝
  mouth.rotation.z = 0.02;
  root.add(mouth);

  /* ---------------- 手臂曲线：肩→肘→腕，自然下垂弯向腹部 ---------------- */
  const ARM = {
    // 肩埋入躯干内、肘外扩、腕落在腹面前方 —— 环抱姿态
    L: { s: [0.195, 1.500, 0.030], e: [0.378, 1.155, 0.175], w: [0.092, 0.944, 0.600], r0: 0.095, r1: 0.064, hand: 1 },
    R: { s: [-0.195, 1.500, 0.020], e: [-0.392, 1.170, 0.140], w: [-0.158, 1.012, 0.580], r0: 0.095, r1: 0.065, hand: -1 },
  };

  function taperedTube(a, b, c, r0, r1, name, mat) {
    const N = 40, R = 18;
    const curve = new THREE.CatmullRomCurve3([
      new THREE.Vector3(...a), new THREE.Vector3(...b), new THREE.Vector3(...c),
    ]);
    const frames = curve.computeFrenetFrames(N, false);
    const pos = [], idx = [], uv = [];
    for (let i = 0; i <= N; i++) {
      const t = i / N;
      const p = curve.getPointAt(t);
      const r = THREE.MathUtils.lerp(r0, r1, Math.pow(t, 0.85));
      for (let j = 0; j <= R; j++) {
        const th = (j / R) * Math.PI * 2;
        const nx = Math.cos(th), by = Math.sin(th);
        pos.push(
          p.x + frames.normals[i].x * nx * r + frames.binormals[i].x * by * r,
          p.y + frames.normals[i].y * nx * r + frames.binormals[i].y * by * r,
          p.z + frames.normals[i].z * nx * r + frames.binormals[i].z * by * r
        );
        uv.push(j / R, t);
      }
    }
    const row = R + 1;
    for (let i = 0; i < N; i++) {
      for (let j = 0; j < R; j++) {
        const a2 = i * row + j, b2 = a2 + row;
        /* 与 Body 同理：此顺序才能得到朝外的 CCW 正面绕序（端帽方向已单独正确，勿改） */
        idx.push(a2, a2 + 1, b2, b2, a2 + 1, b2 + 1);
      }
    }
    // 端帽
    const capStart = pos.length / 3;
    const p0 = curve.getPointAt(0), pN = curve.getPointAt(1);
    pos.push(p0.x, p0.y, p0.z); uv.push(0, 0);
    for (let j = 0; j < R; j++) idx.push(capStart, (j + 1), j);
    const capEnd = pos.length / 3;
    pos.push(pN.x, pN.y, pN.z); uv.push(0, 1);
    for (let j = 0; j < R; j++) idx.push(capEnd, N * row + j, N * row + j + 1);

    const g = new THREE.BufferGeometry();
    g.setAttribute('position', new THREE.Float32BufferAttribute(pos, 3));
    g.setAttribute('uv', new THREE.Float32BufferAttribute(uv, 2));
    g.setIndex(idx);
    g.computeVertexNormals();
    return mesh(g, mat || M.skin, name);
  }

  const arms = new THREE.Group(); arms.name = 'Arms';
  const hands = new THREE.Group(); hands.name = 'Hands';
  const fingers = new THREE.Group(); fingers.name = 'Fingers';
  root.add(arms, hands, fingers);

  ['L', 'R'].forEach((side) => {
    const A = ARM[side];
    arms.add(taperedTube(A.s, A.e, A.w, A.r0, A.r1, 'Arm' + side));

    /* 手掌：灰棕、明显贴覆在腹面（掌根在上、指尖朝下） */
    const palm = mesh(new THREE.SphereGeometry(1, 26, 18), M.hand, 'Palm' + side);
    palm.scale.set(0.072, 0.096, 0.040);
    const wrist = new THREE.Vector3(...A.w);
    palm.position.copy(wrist).add(new THREE.Vector3(-A.hand * 0.008, 0.034, 0.020));
    palm.rotation.y = A.hand * 0.50;          // 掌心朝内贴腹
    palm.rotation.z = A.hand * 0.46;          // 掌面向下内倾
    hands.add(palm);

    /* 四指：统一向下、向中线收拢并顺腹面内弯，指间自然扇开 */
    palm.scale.set(0.076, 0.100, 0.042);
    const knuck = palm.position.clone().add(new THREE.Vector3(-A.hand * 0.026, -0.060, 0.022));
    const fLen = [0.072, 0.082, 0.078, 0.062];   // 参考图：短粗手指
    const fRad = [0.0265, 0.0275, 0.0265, 0.0230];
    for (let f = 0; f < 4; f++) {
      const fan = (f - 1.5);                                // -1.5..1.5
      const r = fRad[f];
      const base = knuck.clone().add(new THREE.Vector3(-A.hand * fan * 0.024, -Math.abs(fan) * 0.004, 0.004 * fan));
      const dir = new THREE.Vector3(-A.hand * 0.30, -0.92, 0.25).normalize();
      const ax = new THREE.Vector3(0, 0, 1);                 // 绕前后轴扇开
      dir.applyAxisAngle(ax, fan * 0.10);
      const mid = base.clone().addScaledVector(dir, fLen[f] * 0.62);
      mid.z += 0.014;                                        // 中段贴腹鼓起
      const tip = mid.clone().addScaledVector(dir, fLen[f] * 0.5);
      tip.z -= 0.030;                                        // 指尖顺曲面内收
      tip.x -= A.hand * 0.010;
      fingers.add(taperedTube(base.toArray(), mid.toArray(), tip.toArray(),
        r, r * 0.78, 'Finger' + side + '_' + f, M.hand));
    }

    /* 拇指：掌内上缘，斜向外上，饱满清晰 */
    const tB = palm.position.clone().add(new THREE.Vector3(-A.hand * 0.034, 0.030, 0.012));
    const tM = palm.position.clone().add(new THREE.Vector3(-A.hand * 0.066, 0.060, 0.026));
    const tT = palm.position.clone().add(new THREE.Vector3(-A.hand * 0.080, 0.096, 0.026));
    fingers.add(taperedTube(tB.toArray(), tM.toArray(), tT.toArray(), 0.0245, 0.0205, 'Thumb' + side, M.hand));
  });

  /* ---------------- Legs / Feet / Toes：上粗下细、宽扁灰棕脚掌 ---------------- */
  const legs = new THREE.Group(); legs.name = 'Legs';
  const feet = new THREE.Group(); feet.name = 'Feet';
  const toes = new THREE.Group(); toes.name = 'Toes';
  root.add(legs, feet, toes);

  const LEG = {
    // 站姿不对称：左脚稍向前
    L: { hip: [0.170, 0.640, 0.030], knee: [0.192, 0.330, 0.092], ankle: [0.186, 0.075, 0.040], footZ: 0.090, footRotY: 0.16 },
    R: { hip: [-0.170, 0.640, 0.000], knee: [-0.208, 0.335, 0.030], ankle: [-0.198, 0.075, 0.000], footZ: 0.045, footRotY: -0.20 },
  };

  ['L', 'R'].forEach((side) => {
    const G = LEG[side];
    legs.add(taperedTube(G.hip, G.knee, G.ankle, 0.130, 0.060, 'Leg' + side));

    const foot = new THREE.Group();
    foot.name = 'Foot' + side;
    foot.position.set(G.ankle[0], 0, G.footZ);
    foot.rotation.y = G.footRotY;

    const sole = mesh(new THREE.SphereGeometry(1, 26, 18), M.foot, 'Sole' + side);
    sole.scale.set(0.086, 0.048, 0.130);
    sole.position.set(0, 0.046, 0.052);
    foot.add(sole);

    const heel = mesh(new THREE.SphereGeometry(1, 20, 14), M.foot, 'Heel' + side);
    heel.scale.set(0.070, 0.052, 0.060);
    heel.position.set(0, 0.052, -0.032);
    foot.add(heel);

    const ankleBall = mesh(new THREE.SphereGeometry(1, 20, 14), M.skin, 'Ankle' + side);
    ankleBall.scale.set(0.062, 0.060, 0.062);
    ankleBall.position.set(0, 0.085, -0.005);
    foot.add(ankleBall);

    /* 脚趾：清晰但不夸张，4 根、微张 */
    const TOE = [
      [0.054, 0.040, 0.186], [0.006, 0.042, 0.202],
      [-0.042, 0.038, 0.188], [-0.080, 0.033, 0.168],
    ];
    TOE.forEach((t, i) => {
      const toe = mesh(new THREE.SphereGeometry(1, 16, 12), M.foot, 'Toe' + side + i);
      const s = [0.043, 0.046, 0.042, 0.035][i];
      toe.scale.set(s, s * 0.58, s * 1.5);
      toe.position.set(t[0], t[1] * 0.85, t[2]);
      toe.rotation.y = (i - 1.5) * 0.16;
      toes.add(toe);
      toe.position.x += G.ankle[0];
      toe.position.z += G.footZ;
    });

    feet.add(foot);
  });

  /* ---------------- Tail：臀部后下方很短的小鼓包（圆锥截面的高光不自然，用椭球） ---------------- */
  const tailP = bodySurfaceY(0.60);
  const tail = mesh(new THREE.SphereGeometry(1, 20, 14), M.skin, 'Tail');
  tail.scale.set(0.060, 0.052, 0.072);
  tail.position.set(0.045, 0.575, tailP.cz - tailP.rz * 0.93);
  root.add(tail);

  /* ---------------- 归一化：高度 2、脚底 y=0 ---------------- */
  const box = new THREE.Box3().setFromObject(root);
  const h = box.max.y - box.min.y;
  root.scale.setScalar(2 / h);
  root.position.y = -box.min.y * (2 / h);
  root.updateMatrixWorld(true);
  return root;
}

/* =====================================================================
 * 展示场景：白背景、软阴影、五视口评审界面
 * ===================================================================== */
export function createShowcase(container) {
  const renderer = new THREE.WebGLRenderer({ antialias: true });
  renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
  renderer.setSize(container.clientWidth, container.clientHeight);
  renderer.shadowMap.enabled = true;
  renderer.shadowMap.type = THREE.PCFSoftShadowMap;
  renderer.outputColorSpace = THREE.SRGBColorSpace;
  /* 参考图是均匀受光的 2D 风格插画；ACES 会把金黄压灰、腹部吹白。
     用 NoToneMapping + 低强度柔光阵列还原参考色彩。 */
  renderer.toneMapping = THREE.NoToneMapping;
  renderer.autoClear = false;
  container.appendChild(renderer.domElement);

  const scene = new THREE.Scene();
  scene.background = new THREE.Color('#ffffff');

  const pmrem = new THREE.PMREMGenerator(renderer);
  scene.environment = pmrem.fromScene(new RoomEnvironment(), 0.04).texture;

  const frog = buildMilkFrog();
  scene.add(frog);

  /* 灯光：评审用多向柔光阵列。
     躯干腹部为陡前凸曲面，法线方向敏感；单侧主光会在四正交视口各出现暗带，
     故用高半球光为基 + 前主光 + 左右补光 + 背补光，保证五个视口受光都均匀。 */
  scene.add(new THREE.HemisphereLight(0xffffff, 0xece4d4, 0.62));
  const key = new THREE.DirectionalLight(0xfff3df, 0.72);
  key.position.set(2.5, 6, 6.5);
  key.castShadow = true;
  key.shadow.mapSize.set(2048, 2048);
  key.shadow.camera.left = -3; key.shadow.camera.right = 3;
  key.shadow.camera.top = 4; key.shadow.camera.bottom = -1;
  key.shadow.bias = -0.0005;
  key.shadow.radius = 4;
  scene.add(key);
  const fillL = new THREE.DirectionalLight(0xffffff, 0.3);
  fillL.position.set(-5, 2.5, 4.5);
  scene.add(fillL);
  const fillR = new THREE.DirectionalLight(0xffffff, 0.24);
  fillR.position.set(5, 1.5, 3.5);
  scene.add(fillR);
  const rimBack = new THREE.DirectionalLight(0xfff0dd, 0.38);
  rimBack.position.set(-1, 4, -6);
  scene.add(rimBack);

  /* 地面：接收柔和阴影 */
  const ground = new THREE.Mesh(
    new THREE.CircleGeometry(6, 64),
    new THREE.ShadowMaterial({ opacity: 0.16 })
  );
  ground.rotation.x = -Math.PI / 2;
  ground.position.y = 0.0001;
  ground.receiveShadow = true;
  scene.add(ground);

  /* ---------------- 视口布局 ---------------- */
  const C = new THREE.Vector3(0, 1.0, 0);
  function ortho(dir, size) {
    const cam = new THREE.OrthographicCamera(-size, size, size * 1.5, -size * 1.5, 0.1, 60);
    cam.position.copy(C).addScaledVector(dir, 16);
    cam.lookAt(C);
    return cam;
  }
  const views = [
    { name: 'front', label: '正面（正交）', cam: ortho(new THREE.Vector3(0, 0.06, 1), 0.66) },
    { name: 'left',  label: '左侧面（正交）', cam: ortho(new THREE.Vector3(1, 0.06, 0), 0.66) },
    { name: 'back',  label: '背面（正交）', cam: ortho(new THREE.Vector3(0, 0.06, -1), 0.66) },
    { name: 'threeq', label: '三分之四视角（参考构图）', cam: ortho(new THREE.Vector3(-0.78, 0.16, 0.60), 0.66) },
    { name: 'persp', label: '自由旋转（透视 · 拖拽 / 滚轮）', cam: null },
  ];

  const persp = new THREE.PerspectiveCamera(34, 1, 0.1, 100);
  persp.position.set(2.9, 2.1, 3.6);
  views[4].cam = persp;

  const controls = new OrbitControls(persp, renderer.domElement);
  controls.target.copy(C);
  controls.enableDamping = true;
  controls.dampingFactor = 0.06;
  controls.minDistance = 2;
  controls.maxDistance = 12;
  controls.autoRotate = true;
  controls.autoRotateSpeed = 1.1;

  /* 网格布局：上排四格正交（front/left/back/threeq），底部整行透视
   * 注意 three.js 视口 y 原点在下，故正交放上方用 y=perspH */
  const rects = []; // {x,y,w,h} 像素
  function layout() {
    const W = container.clientWidth, H = container.clientHeight;
    renderer.setSize(W, H);
    rects.length = 0;
    const perspH = H * 0.42;                 // 底部透视区高度
    const orthoH = H - perspH;
    const cw = W / 4;
    for (let i = 0; i < 4; i++) rects[i] = { x: i * cw, y: perspH, w: cw, h: orthoH };
    rects[4] = { x: 0, y: 0, w: W, h: perspH };
  }
  layout();

  function fitAspect(rect, cam) {
    const a = rect.w / Math.max(rect.h, 1);
    if (cam.isOrthographicCamera) {
      cam.left = -cam.top * a; cam.right = cam.top * a;
    } else {
      cam.aspect = a;
    }
    cam.updateProjectionMatrix();
  }

  addEventListener('resize', layout);

  function renderFrame() {
    renderer.setScissorTest(true);
    for (let i = 0; i < views.length; i++) {
      const r = rects[i], v = views[i];
      renderer.setViewport(r.x, r.y, r.w, r.h);
      renderer.setScissor(r.x, r.y, r.w, r.h);
      renderer.setClearColor(0xffffff, 1);
      renderer.clear();
      fitAspect(r, v.cam);
      renderer.render(scene, v.cam);
    }
    renderer.setScissorTest(false);
  }

  /* 分隔线：用 CSS 覆盖层实现，避免额外渲染通道 */
  const overlay = document.createElement('div');
  overlay.style.cssText = 'position:absolute;inset:0;pointer-events:none;z-index:5';
  const lines = [];
  function mkLine(c) {
    const d = document.createElement('div');
    d.style.cssText = 'position:absolute;background:#e4e0d8;' + c;
    overlay.appendChild(d); lines.push(d); return d;
  }
  const labels = [];
  function mkLabel() {
    const d = document.createElement('div');
    d.className = 'vlabel';
    overlay.appendChild(d); labels.push(d); return d;
  }
  views.forEach(() => mkLabel());

  function syncOverlay() {
    const H = container.clientHeight;
    rects.forEach((r, i) => {
      const cssTop = H - r.y - r.h;
      labels[i].style.left = r.x + 10 + 'px';
      labels[i].style.top = cssTop + 8 + 'px';
      labels[i].textContent = views[i].label;
    });
    lines.forEach(l => l.remove()); lines.length = 0;
    const cw = rects[0].w;
    for (let i = 1; i < 4; i++) mkLine(`left:${i * cw}px;top:0;width:1px;height:${rects[0].h}px`);
    mkLine(`left:0;top:${rects[0].h}px;width:100%;height:1px`);
  }

  (function loop() {
    requestAnimationFrame(loop);
    controls.update();
    renderFrame();
    syncOverlay();
  })();

  container.appendChild(overlay);

  /* ---------------- 工具：线框开关 ---------------- */
  let wire = false;
  const btnWire = document.getElementById('btnWire');
  btnWire.onclick = () => {
    wire = !wire;
    btnWire.classList.toggle('active', wire);
    frog.traverse(o => { if (o.isMesh && 'wireframe' in o.material) o.material.wireframe = wire; });
  };

  const btnRot = document.getElementById('btnRot');
  btnRot.onclick = () => {
    controls.autoRotate = !controls.autoRotate;
    btnRot.classList.toggle('active', controls.autoRotate);
  };

  /* ---------------- 工具：GLB 导出 ---------------- */
  const status = document.getElementById('status');
  document.getElementById('btnGLB').onclick = () => {
    const exporter = new GLTFExporter();
    exporter.parse(
      frog,
      (buffer) => {
        const blob = new Blob([buffer], { type: 'model/gltf-binary' });
        const a = document.createElement('a');
        a.href = URL.createObjectURL(blob);
        a.download = 'MilkFrog.glb';
        a.click();
        setTimeout(() => URL.revokeObjectURL(a.href), 4000);
        status.textContent = '已导出 ' + (buffer.byteLength / 1024).toFixed(0) + ' KB';
      },
      (err) => { status.textContent = '导出失败: ' + err; },
      { binary: true }
    );
  };

  /* 自检信息 */
  const box = new THREE.Box3().setFromObject(frog);
  status.textContent =
    'MilkFrog ✓  高度 ' + (box.max.y - box.min.y).toFixed(3) +
    '  脚底 y=' + box.min.y.toFixed(3) +
    '  深度 ' + (box.max.z - box.min.z).toFixed(2);
  return { renderer, scene, frog };
}
