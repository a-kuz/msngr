float sdRoundedBox2(vec2 p, vec2 b, float r) {
  vec2 q = abs(p) - b + r;
  return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - r;
}

const float STUD_GRID  = 0.155;
const float STUD_R     = 0.046;
const float STUD_H     = 0.034;
const float PLATE_H    = 0.062;
const float WALL       = 0.020;
const float FLOOR_H    = 0.062;
const float TUBE_R     = 0.074;
const float TUBE_RI    = STUD_R + 0.010;
const float LOGO_EXTENT = 2.0 * STUD_GRID + 0.022;

const float DOT_R      = STUD_R * 1.5;
const float DOT_H      = STUD_H * 1.1;

const float BAR_GAP    = 0.005;
const float BAR_HALF_W = STUD_GRID * 0.5 - BAR_GAP * 0.5;
const float BAR_LIP    = 0.012;

const float ANTI_R     = 0.030;
const float ANTI_DEP   = 0.040;

float logoOuter2(vec2 uv) {
  return sdRoundedBox2(uv, vec2(LOGO_EXTENT, LOGO_EXTENT), 0.024);
}

float opExtrude(float d2, float pz, float h) {
  vec2 w = vec2(d2, abs(pz) - h);
  return min(max(w.x, w.y), 0.0) + length(max(w, 0.0));
}

vec2  gTilt;
float gSpinZ;
vec3  gBarFall;

vec3 rotX(vec3 p, float a) {
  float c = cos(a), s = sin(a);
  return vec3(p.x, c * p.y - s * p.z, s * p.y + c * p.z);
}
vec3 rotY(vec3 p, float a) {
  float c = cos(a), s = sin(a);
  return vec3(c * p.x + s * p.z, p.y, -s * p.x + c * p.z);
}
vec3 applyTilt(vec3 p) {
  return rotX(rotY(p, gSpinZ + gTilt.y), gTilt.x);
}

const ivec2 DOT_CELL = ivec2(0, 1);

float bb2(vec2 p, vec2 b) {
  return length(max(abs(p) - b, 0.0));
}
float legoText(vec2 uv) {
  uv *= vec2(2.4, 2.2);
  uv.x += uv.y * -0.1;
  float oldx = uv.x;
  uv.x = fract(uv.x) - 0.5;
  if (abs(oldx) > 2.0) return 0.0;
  float l;
  if (oldx < 0.0) {
    float e0 = bb2(uv - vec2(-0.15, 0.0), vec2(0.20, 0.0));
    if (oldx > -1.0) uv.y = -abs(uv.y); else e0 = 1.0;
    float l0 = bb2(uv - vec2(0.0, -0.75), vec2(0.35, 0.0));
    float l1 = bb2(uv - vec2(-0.35, 0.0), vec2(0.0, 0.75));
    l0 = min(l0, e0);
    l  = min(l0, l1);
  } else {
    l = abs(bb2(uv, vec2(0.20, 0.60)) - 0.15);
    if (oldx < 1.0) {
      if (uv.x > 0.0 && uv.y > 0.0 && uv.y < 0.5)
        l = bb2(uv - vec2(0.35, 0.60), vec2(0.0, 0.1));
      float e0 = bb2(uv - vec2(0.2, 0.0), vec2(0.15, 0.0));
      l = min(l, e0);
    }
  }
  return smoothstep(0.18, 0.05, l);
}

float sdOneStud(vec3 p, int cx, int cy) {
  vec2 center = (vec2(float(cx), float(cy)) + 0.5) * vec2(STUD_GRID);
  vec2 local = p.xy - center;
  bool isDot = (cx == DOT_CELL.x && cy == DOT_CELL.y);
  float r = isDot ? DOT_R : STUD_R;
  float h = isDot ? DOT_H : STUD_H;
  float zc = p.z - (PLATE_H + h * 0.5);
  vec2 d2 = vec2(length(local) - r, abs(zc) - h * 0.5);
  return min(max(d2.x, d2.y), 0.0) + length(max(d2, 0.0));
}

float sdAllStuds(vec3 p) {
  vec2 grid = vec2(STUD_GRID);
  vec2 cellId = floor(p.xy / grid);
  int cx = int(cellId.x);
  int cy = int(cellId.y);
  float d = 1e9;
  if (cx >= -2 && cx <= 1 && cy >= -2 && cy <= 1) {
    d = sdOneStud(p, cx, cy);
  }
  d = min(d, sdOneStud(p, DOT_CELL.x, DOT_CELL.y));
  return d;
}

const float CAV_ZTOP = PLATE_H - FLOOR_H;
const float CAV_ZBOT = -PLATE_H - 0.02;

float sdBoxSDF(float d2, float pz, float zCenter, float zHalf) {
  vec2 w = vec2(d2, abs(pz - zCenter) - zHalf);
  return min(max(w.x, w.y), 0.0) + length(max(w, 0.0));
}
float sdCavity(vec3 p) {
  float cav2 = logoOuter2(p.xy) + WALL;
  float zC = (CAV_ZTOP + CAV_ZBOT) * 0.5;
  float zH = (CAV_ZTOP - CAV_ZBOT) * 0.5;
  return sdBoxSDF(cav2, p.z, zC, zH);
}
float sdHollowPlate(vec3 p) {
  float outer = opExtrude(logoOuter2(p.xy), p.z, PLATE_H);
  return max(outer, -sdCavity(p));
}
float sdCappedCylZ(vec3 p, vec2 cxy, float r, float zc, float hz) {
  vec2 local = p.xy - cxy;
  float d = length(local) - r;
  float h = abs(p.z - zc) - hz;
  return min(max(d, h), 0.0) + length(max(vec2(d, h), 0.0));
}
float sdTube(vec3 p, vec2 cxy) {
  float zC = (CAV_ZTOP + CAV_ZBOT) * 0.5;
  float zH = (CAV_ZTOP - CAV_ZBOT) * 0.5;
  float outer = sdCappedCylZ(p, cxy, TUBE_R, zC, zH);
  float innerTop = CAV_ZTOP;
  float innerBot = CAV_ZBOT - 0.05;
  float innerZC  = (innerTop + innerBot) * 0.5;
  float innerZH  = (innerTop - innerBot) * 0.5;
  float inner = sdCappedCylZ(p, cxy, TUBE_RI, innerZC, innerZH);
  return max(outer, -inner);
}
float sdAllTubes(vec3 p) {
  float tubes = 1e9;
  for (int j = -1; j <= 1; j++) {
    for (int i = -1; i <= 1; i++) {
      vec2 c = vec2(float(i), float(j)) * STUD_GRID;
      tubes = min(tubes, sdTube(p, c));
    }
  }
  return max(tubes, sdCavity(p));
}

float sdAllAntiStuds(vec3 p) {
  float dimples = 1e9;
  float dTop = CAV_ZTOP + ANTI_DEP;
  float dBot = CAV_ZTOP - 0.005;
  float zC = (dTop + dBot) * 0.5;
  float hz = (dTop - dBot) * 0.5;
  for (int j = -2; j <= 1; j++) {
    for (int i = -2; i <= 1; i++) {
      vec2 c = (vec2(float(i), float(j)) + 0.5) * STUD_GRID;
      dimples = min(dimples, sdCappedCylZ(p, c, ANTI_R, zC, hz));
    }
  }
  return dimples;
}

float sdOneBar(vec3 p, float cx, float yC, float yH, float fallProgress) {
  float zBot = PLATE_H;
  float zTop = PLATE_H + STUD_H + BAR_LIP;
  float zC = (zTop + zBot) * 0.5;
  float zH = (zTop - zBot) * 0.5;

  vec3 q = p - vec3(cx, yC, zC);

  float fp = max(fallProgress, 0.0);
  if (fp > 0.9) return 1e9;
  float tumble = fp * 3.5;
  float zOff = fp * 0.9 + fp * fp * 0.4;
  float yDrop = fp * fp * 0.4;
  float xDrift = fp * 0.10 * sin(cx * 5.0);

  q -= vec3(xDrift, -yDrop, zOff);
  float c = cos(tumble), s = sin(tumble);
  q = vec3(q.x, c * q.y - s * q.z, s * q.y + c * q.z);

  vec3 b = vec3(BAR_HALF_W, yH, zH);
  vec3 d = abs(q) - b;
  return min(max(d.x, max(d.y, d.z)), 0.0) + length(max(d, 0.0));
}

float sdBars(vec3 p) {
  float bot  = -2.0 * STUD_GRID;
  float top1 = bot + 1.0 * STUD_GRID;
  float top2 = bot + 2.0 * STUD_GRID;
  float top3 = bot + 3.0 * STUD_GRID;
  float yC1 = (bot + top1) * 0.5;
  float yC2 = (bot + top2) * 0.5;
  float yC3 = (bot + top3) * 0.5;
  float yH1 = (top1 - bot) * 0.5;
  float yH2 = (top2 - bot) * 0.5;
  float yH3 = (top3 - bot) * 0.5;

  float cx1 = -0.5 * STUD_GRID;
  float cx2 =  0.5 * STUD_GRID;
  float cx3 =  1.5 * STUD_GRID;

  float b1 = sdOneBar(p, cx1, yC1, yH1, gBarFall.x);
  float b2 = sdOneBar(p, cx2, yC2, yH2, gBarFall.y);
  float b3 = sdOneBar(p, cx3, yC3, yH3, gBarFall.z);
  return min(min(b1, b2), b3);
}

float map(vec3 worldP) {
  vec3 p = applyTilt(worldP);
  float plate   = max(sdHollowPlate(p), -sdAllAntiStuds(p));
  float studs   = sdAllStuds(p);
  float tubes   = sdAllTubes(p);
  float bars    = sdBars(p);
  return min(min(min(plate, studs), tubes), bars);
}

float matId(vec3 worldP) {
  vec3 p = applyTilt(worldP);
  float plate = max(sdHollowPlate(p), -sdAllAntiStuds(p));
  float studs = sdAllStuds(p);
  float tubes = sdAllTubes(p);
  float bars  = sdBars(p);

  float d = plate; float id = 0.0;
  if (tubes < d) { d = tubes; id = 0.0; }
  if (bars  < d) { d = bars;  id = 2.0; }
  if (studs < d) {
    float dotD = sdOneStud(p, DOT_CELL.x, DOT_CELL.y);
    if (abs(dotD - studs) < 0.0001) {
      id = 3.0;
    } else {
      id = 1.0;
    }
    d = studs;
  }
  return id;
}

vec3 calcNormal(vec3 p) {
  vec2 e = vec2(0.0015, 0.0);
  return normalize(vec3(
    map(p + e.xyy) - map(p - e.xyy),
    map(p + e.yxy) - map(p - e.yxy),
    map(p + e.yyx) - map(p - e.yyx)
  ));
}

float softShadow(vec3 ro, vec3 rd) {
  float res = 1.0;
  float t = 0.01;
  for (int i = 0; i < 24; i++) {
    float h = map(ro + rd * t);
    if (h < 0.001) return 0.3;
    res = min(res, 18.0 * h / t);
    t += clamp(h, 0.01, 0.1);
    if (t > 3.0) break;
  }
  return clamp(res, 0.3, 1.0);
}

float ao(vec3 p, vec3 n) {
  float occ = 0.0;
  float sca = 1.0;
  for (int i = 0; i < 5; i++) {
    float h = 0.01 + 0.04 * float(i);
    float d = map(p + n * h);
    occ += (h - d) * sca;
    sca *= 0.85;
  }
  return clamp(1.0 - 1.5 * occ, 0.0, 1.0);
}

float raymarch(vec3 ro, vec3 rd) {
  float t = 0.0;
  for (int i = 0; i < 80; i++) {
    vec3 p = ro + rd * t;
    float d = map(p);
    if (d < 0.0006) return t;
    if (t > 4.0) break;
    t += d * 0.75;
  }
  return -1.0;
}

mat3 lookAt(vec3 eye, vec3 target, vec3 up) {
  vec3 f = normalize(target - eye);
  vec3 r = normalize(cross(f, up));
  vec3 u = cross(r, f);
  return mat3(r, u, f);
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
  vec2 mousePx = iMouse.xy;
  vec2 mouseN = mousePx == vec2(0.0)
    ? vec2(0.0)
    : (mousePx - iResolution.xy * 0.5) /
      (min(iResolution.x, iResolution.y) * 0.5);

  float t = iTime;
  float idleX = sin(t * 0.6) * 0.08;
  float idleY = cos(t * 0.45) * 0.06;
  float targetX =  mouseN.y * 0.6 + idleX;
  float targetY = -mouseN.x * 3.2 + idleY;
  gTilt   = vec2(targetX, targetY);
  gSpinZ  = 0.0;
  gBarFall = vec3(0.0);

  vec2 uv = (fragCoord - iResolution.xy * 0.5) /
            min(iResolution.x, iResolution.y);

  vec3 ro = vec3(mouseN.x * 0.08, mouseN.y * 0.08, 1.7);
  vec3 ta = vec3(0.0, 0.0, 0.0);
  mat3 cam = lookAt(ro, ta, vec3(0.0, 1.0, 0.0));
  vec3 rd = cam * normalize(vec3(uv, 0.82));

  float dist = raymarch(ro, rd);

  vec4 col = vec4(0.0);
  if (dist > 0.0) {
    vec3 p = ro + rd * dist;
    vec3 n = calcNormal(p);
    float mat = matId(p);

    vec3 cPlate    = vec3(0.45, 0.32, 0.78);
    vec3 cBgStud   = cPlate;
    vec3 cGlyph    = vec3(0.92, 0.92, 0.95);
    vec3 cDotStud  = vec3(0.95, 0.28, 0.70);
    vec3 baseCol = cPlate;
    if      (mat > 2.5) baseCol = cDotStud;
    else if (mat > 1.5) baseCol = cGlyph;
    else if (mat > 0.5) baseCol = cBgStud;

    if (mat > 0.5) {
      vec3 pObj = applyTilt(p);
      vec2 cellId = floor(pObj.xy / vec2(STUD_GRID));
      vec2 center = (cellId + 0.5) * vec2(STUD_GRID);
      vec2 local  = (pObj.xy - center) / STUD_R;
      float topZ = PLATE_H + STUD_H;
      float onTop = smoothstep(0.004, 0.0, abs(pObj.z - topZ));
      float ink = legoText(local) * onTop;
      baseCol = mix(baseCol, baseCol * 0.78, ink);
    }

    vec3 L1 = normalize(vec3(0.6, -0.4, 1.2));
    vec3 L2 = normalize(vec3(-0.8, 0.3, 0.6));
    float diff1 = max(dot(n, L1), 0.0);
    float diff2 = max(dot(n, L2), 0.0) * 0.5;
    float sha = softShadow(p + n * 0.005, L1);
    float occ = ao(p, n);

    vec3 V = -rd;
    vec3 H1 = normalize(L1 + V);
    float spec = pow(max(dot(n, H1), 0.0), 60.0) * sha;

    vec3 lit = baseCol * (0.18 + diff1 * 0.62 * sha + diff2 * 0.28) * occ;
    lit += vec3(1.0, 0.96, 1.0) * spec * 0.22;

    float rim = pow(1.0 - max(dot(n, V), 0.0), 3.0);
    lit += mix(cPlate, cDotStud, 0.5) * rim * 0.22;

    lit = lit * (2.51 * lit + 0.03) / (lit * (2.43 * lit + 0.59) + 0.14);

    col = vec4(lit, 1.0);
  }

  fragColor = col;
}
