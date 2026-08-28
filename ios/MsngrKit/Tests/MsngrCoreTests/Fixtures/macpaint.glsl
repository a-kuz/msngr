const float LOOP = 44.0;

// ---------- bitmaps (generated; row bit i = column i, LSB = leftmost) ----------
const int FONT_ROWS[] = int[](
17, 17, 17, 31, 17, 17, 17, 0, 0, 0, 0, 0, 0,
31,  4,  4,  4,  4,  4,  4, 0, 0, 0, 0, 0, 0,
 0,  0, 14,  8, 14,  9, 14, 0, 0, 0, 0, 0, 0,
 1,  1,  7,  9,  9,  9,  7, 0, 0, 0, 0, 0, 0,
 0,  0, 14,  1,  1,  1, 14, 0, 0, 0, 0, 0, 0,
 0,  0,  6,  9, 15,  1, 14, 0, 0, 0, 0, 0, 0,
12,  2, 15,  2,  2,  2,  2, 0, 0, 0, 0, 0, 0,
 1,  1,  7,  9,  9,  9,  9, 0, 0, 0, 0, 0, 0,
 0,  1,  0,  1,  1,  1,  1, 0, 0, 0, 0, 0, 0,
 1,  1,  1,  1,  1,  1,  1, 0, 0, 0, 0, 0, 0,
 0,  0, 31, 21, 21, 21, 21, 0, 0, 0, 0, 0, 0,
 0,  0,  7,  9,  9,  9,  9, 0, 0, 0, 0, 0, 0,
 0,  0,  6,  9,  9,  9,  6, 0, 0, 0, 0, 0, 0,
 0,  0, 13,  3,  1,  1,  1, 0, 0, 0, 0, 0, 0,
 0,  0, 14,  1,  6,  8,  7, 0, 0, 0, 0, 0, 0,
 2,  2, 15,  2,  2,  2, 12, 0, 0, 0, 0, 0, 0,
 0,  0,  9,  9,  9, 14,  8, 4, 2, 0, 0, 0, 0,
 0,  0, 15,  4,  2,  1, 15, 0, 0, 0, 0, 0, 0,
 1,  1,  0,  0,  0,  0,  0, 0, 0, 0, 0, 0, 0,
 0,  0,  0,  0,  0,  0,  1, 0, 0, 0, 0, 0, 0
);
// glyph order: HTabcefhilmnorstyz'.
const int ADVANCE[] = int[](6, 6, 5, 5, 5, 5, 5, 5, 2, 2, 6, 5, 5, 5, 5, 5, 5, 5, 2, 2);
const int IBEAM[] = int[](27, 4, 4, 4, 4, 4, 4, 4, 4, 4, 27); // 5x11, classic serifs
const int ARROW[] = int[](1, 3, 7, 15, 31, 63, 127, 255, 511, 1023, 63, 55, 115, 97, 224, 192); // 11x16
// MacPaint 1.0 tool icons, sampled 1:1 from the original 512x342 screenshot
const int ICO_LASSO[]   = int[](0, 0, 16256, 49264, 65544, 65540, 65538, 49154, 14338, 1820, 230, 42, 28, 16, 16, 8, 0, 0);
const int ICO_SEL[]     = int[](0, 0, 118686, 65538, 65538, 0, 0, 65538, 65538, 65538, 0, 0, 65538, 65538, 124878, 0, 0, 0);
const int ICO_HAND[]    = int[](0, 768, 7344, 9416, 42184, 91280, 74896, 73772, 65586, 32802, 32772, 32776, 16392, 16400, 8224, 8256, 8256, 0);
const int ICO_A[]       = int[](0, 512, 1792, 1792, 3968, 3712, 7360, 7232, 14432, 14368, 28720, 32752, 57368, 57368, 114700, 245774, 258079, 0);
const int ICO_BUCKET[]  = int[](0, 448, 544, 800, 1696, 6752, 29216, 57872, 115976, 115204, 122882, 118786, 116740, 115720, 115216, 49440, 16576, 0);
const int ICO_SPRAY[]   = int[](0, 8, 32, 2696, 7200, 8712, 32512, 16640, 30976, 18688, 30976, 18688, 30976, 30976, 16640, 16640, 32512, 0);
const int ICO_BRUSH[]   = int[](0, 1792, 1280, 1792, 1792, 1792, 1792, 1792, 16352, 8224, 16352, 8224, 8224, 8224, 10912, 13648, 8184, 0);
const int ICO_PENCILT[] = int[](0, 7680, 8704, 8448, 4864, 7296, 2176, 2112, 1088, 1056, 544, 528, 272, 240, 112, 48, 16, 0);
const int ICO_LINE[]    = int[](0, 0, 0, 0, 0, 6, 24, 96, 384, 1536, 6144, 24576, 98304, 0, 0, 0, 0, 0);
const int ICO_ERASER[]  = int[](0, 0, 0, 65024, 33024, 114816, 106560, 53280, 26640, 13320, 6660, 3582, 1794, 770, 510, 0, 0, 0);

// "Here's to the / crazy ones. / The misfits. / The rebels."  (-1 space, -2 newline)
const int TXT[] = int[](0,5,13,5,18,14,-1,15,12,-1,15,7,5,-2,
                          4,13,2,17,16,-1,12,11,5,14,19,-2,
                          1,7,5,-1,10,8,14,6,8,15,14,19,-2,
                          1,7,5,-1,13,5,3,5,9,14,19);

// cursive "hello" pen path (authored coords, baseline ~101)
const vec2 PTS[] = vec2[](
vec2(64,96),vec2(72,87),vec2(80,78),vec2(88,56),vec2(96,32),vec2(100,22),vec2(97,17),vec2(93,20),
vec2(88,30),vec2(78,54),vec2(68,78),vec2(60,97),vec2(56,108),vec2(58,114),vec2(64,115),vec2(72,110),
vec2(80,102),vec2(88,90),vec2(95,82),vec2(101,79),vec2(106,82),vec2(110,91),
vec2(127,95),vec2(130,88),vec2(131,81),vec2(128,77),vec2(124,80),vec2(122,87),vec2(123,95),vec2(127,100),
vec2(133,100),vec2(138,96),
vec2(143,90),vec2(149,72),vec2(155,52),vec2(158,40),vec2(158,33),vec2(155,33),vec2(151,41),vec2(147,57),
vec2(144,75),vec2(143,91),vec2(144,99),vec2(148,101),vec2(153,97),vec2(157,90),
vec2(161,84),vec2(166,66),vec2(171,48),vec2(174,37),vec2(174,32),vec2(171,34),vec2(167,44),vec2(163,62),
vec2(161,80),vec2(160,94),vec2(161,100),vec2(165,101),vec2(170,97),vec2(174,89),
vec2(177,84),vec2(180,79),vec2(184,77),vec2(189,78),vec2(192,82),vec2(193,88),vec2(191,94),vec2(187,99),
vec2(182,100),vec2(179,96),vec2(178,90),vec2(180,84),vec2(184,80),vec2(190,80),vec2(196,84),vec2(203,88),
vec2(210,88),vec2(216,84));
const vec2 HOFF = vec2(10, -6);     // hello offset inside canvas
const vec2 PERIOD = vec2(164, 36);
// uniform-scale the authored path to the original's size (asc ~35 cells, high on the canvas)
vec2 helloT(vec2 p){ return vec2(74. + (p.x - 64.)*0.42, 45. + (p.y - 101.)*0.42); }

// ---------- helpers ----------
float ss(float a, float b, float x){ return smoothstep(a, b, x); }
float kf(float t, float a, float b){ return clamp((t-a)/(b-a), 0., 1.); }
float hash21(vec2 p){ p = fract(p*vec2(123.34, 345.45)); p += dot(p, p+34.345); return fract(p.x*p.y); }
vec3 hsl(float h, float s, float l){
  vec3 rgb = clamp(abs(mod(h*6. + vec3(0,4,2), 6.) - 3.) - 1., 0., 1.);
  return l + s*(rgb - 0.5)*(1. - abs(2.*l - 1.));
}
bool bitAt(int row, int x){ return ((row >> x) & 1) == 1; }
int fontBit(int g, ivec2 q){
  if (q.x < 0 || q.x > 7 || q.y < 0 || q.y > 12) return 0;
  return bitAt(FONT_ROWS[g*13 + q.y], q.x) ? 1 : 0;
}
bool iconBit(int id, ivec2 q){
  if (q.x < 0 || q.x > 17 || q.y < 0 || q.y > 17) return false;
  int row;
  switch (id){
    case 0: row = ICO_LASSO[q.y]; break;   case 1: row = ICO_SEL[q.y]; break;
    case 2: row = ICO_HAND[q.y]; break;    case 3: row = ICO_A[q.y]; break;
    case 4: row = ICO_BUCKET[q.y]; break;  case 5: row = ICO_SPRAY[q.y]; break;
    case 6: row = ICO_BRUSH[q.y]; break;   case 7: row = ICO_PENCILT[q.y]; break;
    case 8: row = ICO_LINE[q.y]; break;    default: row = ICO_ERASER[q.y]; break;
  }
  return bitAt(row, q.x);
}
float charTime(int i){ return 0.5 + float(i)*0.145 + 0.04*sin(float(i)*2.7); }
float sdSeg(vec2 p, vec2 a, vec2 b){
  vec2 pa = p - a, ba = b - a;
  float h = clamp(dot(pa,ba)/dot(ba,ba), 0., 1.);
  return length(pa - ba*h);
}

// ---------- scene 1: MacWrite ----------
int sceneWrite(vec2 c, float t){
  ivec2 p = ivec2(floor(c));
  int fg = 0;
  // dither band hugging the window (left + top)
  if (p.x >= -3 && p.x <= -2 && p.y >= -3 && p.y <= 120 && ((p.x+p.y)&1) == 0) fg = 1;
  if (p.y >= -3 && p.y <= -2 && p.x >= -3 && p.x <= 150 && ((p.x+p.y)&1) == 0) fg = 1;
  if (p.x < 0 || p.x > 150 || p.y < 0 || p.y > 120) return fg;
  if (p.x == 0 || p.x == 150 || p.y == 0 || p.y == 120) return 1;
  if (p.y <= 8){                        // title bar: three stripes
    int f = 0;
    if (p.y >= 2 && p.y <= 6 && (p.y&1) == 0 && p.x >= 3 && p.x <= 147) f = 1;
    if (p.x >= 6 && p.x <= 12 && p.y >= 2 && p.y <= 6)
      f = (p.x == 6 || p.x == 12 || p.y == 2 || p.y == 6) ? 1 : 0;
    if (p.y == 8) f = 1;
    return f;
  }
  // ruler: dotted line, hanging ticks, a down-pointing margin marker
  if (p.y == 14 && (p.x&1) == 0 && p.x >= 4 && p.x <= 146) fg = 1;
  if (p.y == 15 && (p.x-4) % 8 == 0 && p.x >= 4 && p.x <= 146) fg = 1;
  if (p.y >= 15 && p.y <= 16 && (p.x-4) % 32 == 0 && p.x >= 4 && p.x <= 146) fg = 1;
  if (p.y >= 10 && p.y <= 13 && abs(p.x - 30) <= 13 - p.y) fg = 1;   // marker, apex down
  for (int b = 0; b < 2; b++){                                        // two well boxes
    int bx = 42 + b*20;
    if (p.x >= bx && p.x <= bx+14 && p.y >= 18 && p.y <= 27){
      fg = (p.x == bx || p.x == bx+14 || p.y == 18 || p.y == 27) ? 1 : 0;
      if (p.y >= 21 && p.y <= 24 && abs(p.x - bx - 7) <= (p.y - 21)*2 + 1) fg = 1;  // apex up, 2-cell steps
    }
  }
  if ((p.y == 30 || p.y == 31) && p.x >= 3 && p.x <= 147) fg = 1;

  // text; selection is anchor->cursor, like a real drag: the I-beam sweeps line 1,
  // then pulls down-right — line 1 fills to its end at once, line 2 picks up under it
  float selU = ss(8.6, 11.4, t);
  float uu = clamp(selU + 0.045*sin(selU*9.2) + 0.028*sin(selU*21.7), 0., 1.);   // human pace
  float ibX = mix(10., 70., uu);
  float lineDrop = ss(0.60, 0.74, uu);
  float ibY = 38. + 12.*lineDrop;
  bool selActive = t > 8.6 && t < 15.5;
  if (p.y >= 36 && p.y <= 88){       // glyphs/caret/selection live in this band only
    vec2 pen = vec2(10, 38);
    float caretX = 10., caretY = 38.;
    float selX0 = 8., selX1 = 8.;
    int line = 0, prev = -9;
    for (int i = 0; i < 50; i++){
      int g = TXT[i];
      if (g == -2){ pen = vec2(10., pen.y + 12.); line++; prev = -9; continue; }
      if (prev == 13 && g == 2) pen.x -= 1.;             // kern r->a
      prev = g;
      bool vis = t > charTime(i);
      float adv = (g == -1) ? 4.0 : float(ADVANCE[g]);
      if (vis && g >= 0 && fontBit(g, p - ivec2(int(pen.x), int(pen.y))) == 1) fg = 1;
      if (vis){ caretX = pen.x + adv; caretY = pen.y; }
      float bEnd = pen.x + adv;
      if (line == 0 && (bEnd <= ibX || lineDrop > 0.5)) selX0 = bEnd;
      if (line == 1 && lineDrop > 0.5 && bEnd <= ibX) selX1 = bEnd;
      pen.x += adv;
    }
    // caret
    if (t > -3.0 && t < 8.4 && fract(t*1.4) < 0.6 &&
        p.x == int(caretX) &&
        p.y >= int(caretY) - 1 && p.y < int(caretY) + 9) fg = 1;
    // selection invert (per character, snaps as the I-beam passes)
    int inv = 0;
    if (selActive){
      if (p.y >= 37 && p.y <= 48 && float(p.x) >= 8. && float(p.x) < selX0) inv = 1;
      if (p.y >= 49 && p.y <= 60 && float(p.x) >= 8. && float(p.x) < selX1) inv = 1;
    }
    fg ^= inv;
  }
  // I-beam cursor, drawn in inverse video like the real one
  if (t > 8.0 && t < 15.5){
    vec2 ib = vec2(ibX, ibY + 0.8*sin(uu*7.0) - 0.4);    // hand drifts off the line a little
    float gi = ss(8.0, 8.9, t);
    ib = mix(vec2(90, 90), ib, gi);                      // glides in
    ib += vec2(-10, 4)*sin(3.14159*gi);                  // on a curved, human path
    ivec2 q = p - ivec2(int(ib.x) - 2, int(ib.y) - 2);
    if (q.x >= 0 && q.x < 5 && q.y >= 0 && q.y < 11 && bitAt(IBEAM[q.y], q.x)) fg = 1 - fg;
  }
  return fg;
}

// ---------- scene 2: MacPaint ----------
int scenePaint(vec2 c, float t){
  ivec2 p = ivec2(floor(c));
  int fg = 0;
  // toolbox 2x5
  if (p.x >= 0 && p.x <= 44 && p.y >= 0 && p.y <= 120){
    if (p.x == 0 || p.x == 22 || p.x == 44 || p.y % 24 == 0) fg = 1;
    int col = p.x < 22 ? 0 : 1;
    int row = clamp(p.y / 24, 0, 4);
    ivec2 q = p - ivec2(col*22 + 2, row*24 + 3);
    if (iconBit(row*2 + col, q)) fg = 1;
    int selTool = (t < 20.6) ? 7 : 6;                    // pencil -> brush on click
    if (row*2 + col == selTool &&
        p.x > col*22 && p.x < col*22 + 22 && p.y > row*24 && p.y < row*24 + 24) fg = 1 - fg;
  }
  // dither divider
  if (p.x >= 46 && p.x <= 53 && p.y >= -20 && p.y <= 140 && ((p.x+p.y)&1) == 0) fg = 1;
  // canvas window chrome
  if (p.x >= 54 && p.x <= 330){
    if (p.y >= -32 && p.y <= -20){
      if (p.y == -32 || p.y == -20 || p.x == 54 || p.x == 330) fg = 1;
      else if ((p.y&1) == 1 && p.x >= 58 && p.x <= 326) fg = 1;
      if (p.x >= 62 && p.x <= 70 && p.y >= -29 && p.y <= -23)
        fg = (p.x == 62 || p.x == 70 || p.y == -29 || p.y == -23) ? 1 : 0;
    }
    if (p.y > -20 && p.y < -8){                          // little toolbar strip
      if (p.y >= -18 && p.y <= -10 && (p.y&1) == 0 && p.x >= 240 && p.x <= 286) fg = 1;
      if (p.x >= 292 && p.x <= 316 && p.y >= -18 && p.y <= -10)
        fg = (p.x == 292 || p.x == 316 || p.y == -18 || p.y == -10) ? 1 : 0;
    }
    if (p.y == -8 && p.x >= 54) fg = 1;                  // canvas top edge
  }
  // hello pen path, rasterized at cell centers
  vec2 cc = floor(c) + 0.5;
  float drawU = kf(t, 22.6, 33.4);
  vec2 pen = helloT(PTS[0]) + HOFF;
  float visLen = drawU * 320.76;   // precomputed path length after helloT scaling
  if (drawU > 0. && cc.x > 70. && cc.x < 180. && cc.y > 0. && cc.y < 54.){
    float cum = 0.;
    for (int i = 0; i < PTS.length()-1; i++){
      vec2 a = helloT(PTS[i]) + HOFF, b = helloT(PTS[i+1]) + HOFF;
      float L = length(b - a);
      if (cum >= visLen) break;
      vec2 e = (cum + L <= visLen) ? b : mix(a, b, (visLen - cum)/L);
      if (sdSeg(cc, a, e) < 1.3) fg = 1;
      pen = e;
      cum += L;
    }
  } else if (drawU > 0. && cc.x > 6. && cc.x < 190. && cc.y > -6. && cc.y < 92.){
    // pen position for the brush nib; fragments beyond nib reach skip this
    float cum = 0.;
    for (int i = 0; i < PTS.length()-1; i++){
      vec2 a = helloT(PTS[i]) + HOFF, b = helloT(PTS[i+1]) + HOFF;
      float L = length(b - a);
      if (cum + L >= visLen){ pen = mix(a, b, (visLen - cum)/L); break; }
      cum += L; pen = b;
    }
  }
  // period
  if (t > 33.9 && length(cc - PERIOD) < 1.7) fg = 1;

  // arrow cursor: comes in, clicks the brush tool
  if (t > 17.8 && t < 21.0){
    float au = ss(18.0, 20.5, t);
    vec2 ap = mix(vec2(150, 95), vec2(10, 86), au);
    ap += vec2(-9, -16)*sin(3.14159*au) + vec2(0, 2)*sin(6.28*au);   // arced approach
    ivec2 q = p - ivec2(ap);
    if (q.x >= 0 && q.x < 11 && q.y >= 0 && q.y < 16 && bitAt(ARROW[q.y], q.x)) fg = 1;
  }
  // after the click the cursor is the brush nib: a small round dot at the pen
  if (t > 21.0 && t < 36.5){
    vec2 tip = pen;
    if (t > 33.4) tip = mix(pen, PERIOD, ss(33.4, 33.9, t));
    tip = mix(vec2(14, 84), tip, ss(21.0, 22.6, t));     // glides from the toolbox
    if (length(cc - tip) < 1.8) fg = 1;
  }
  return fg;
}

// ---------- dissolve: dots shrink in place under a smooth size-gradient front ----------
// dissolve sweeps down row by row; MacPaint materializes column by column instead
float cellScale(vec2 cell, float dIn, float dOut, vec2 prRO, vec2 prRI, bool inByX){
  float sc = 1.;
  if (dOut > 0.) sc *= ss(0., 22., cell.y - mix(prRO.x, prRO.y, dOut));
  float prI = inByX ? cell.x : cell.y;
  if (dIn  < 1.) sc *= 1. - ss(0., 22., prI - mix(prRI.x, prRI.y, dIn));
  return sc;
}

float dotCov(vec2 c, float scale, float aa, float soft){
  if (scale <= 0.03) return 0.;
  vec2 f = fract(c) - 0.5;
  float r = 0.12*scale;
  vec2 b = vec2(0.5 - 0.032)*scale - r;
  vec2 q = abs(f) - b;
  float d = length(max(q, vec2(0))) + min(max(q.x, q.y), 0.) - r;
  return 1. - ss(0., aa + soft, d + (aa + soft)*0.5);
}

float hueAt(float t){
  const vec2 K[] = vec2[](vec2(0, 1.04), vec2(15, 0.84), vec2(21, 0.65), vec2(27, 0.50),
                           vec2(33, 0.35), vec2(39, 0.16), vec2(44, 0.04));
  float h = 0.;
  for (int i = 0; i < 6; i++)
    if (t >= K[i].x && t <= K[i+1].x)
      h = mix(K[i].y, K[i+1].y, (t - K[i].x)/(K[i+1].x - K[i].x));
  return fract(h);
}

void mainImage(out vec4 O, in vec2 F){
  float t = mod(iTime, LOOP);
  vec2 R = iResolution.xy;
  vec2 uv = vec2(F.x - 0.5*R.x, 0.5*R.y - F.y)/R.y;   // y down

  int scene = -1; float dIn = 1., dOut = 0.;
  vec2 cam = vec2(0); float zoom = 60., rot = 0.22;
  if (t < 15.8){ scene = 0; dOut = kf(t, 12.2, 15.8); }
  else if (t < 16.2) scene = -1;
  else if (t < 40.6){ scene = 1; dIn = kf(t, 16.2, 19.4); dOut = kf(t, 37.0, 40.6); }
  else if (t < 40.9) scene = -1;
  else { scene = 0; dIn = kf(t, 40.9, 43.6); }

  float ts = t;                     // scene-local time for scene 0 at the loop tail
  if (scene == 0){
    if (t > 40.) ts = t - LOOP;
    float u = (ts + 2.8)/17.6;
    cam = vec2(50, 24) + vec2(18, 34)*u + 1.2*vec2(sin(ts*0.23), cos(ts*0.19));
    zoom = 75. - 3.*u;
    rot = 0.30 - 0.04*u;
  } else if (scene == 1){
    float u1 = ss(0., 1., kf(t, 16.2, 20.6));
    float u2 = ss(0., 1., kf(t, 20.6, 22.6));
    float u3 = kf(t, 22.6, 33.4);
    float u4 = ss(0., 1., kf(t, 34.0, 40.3));
    cam = vec2(42, 66);
    cam = mix(cam, vec2(34, 78),  u1);
    cam = mix(cam, vec2(72, 40),  u2);
    cam = mix(cam, vec2(140, 44), u3);
    cam = mix(cam, vec2(156, 48), u4);
    zoom = mix(mix(mix(mix(84., 82., u1), 80., u2), 79., u3), 80., u4);
    rot = 0.30 - 0.04*kf(t, 16.2, 40.3);
  }

  float hue = hueAt(t);
  float y01 = 1. - F.y/R.y;
  float l = mix(0.62, 0.47, y01) + 0.05*(1. - min(1., length((vec2(F.x/R.x, y01) - vec2(0.5, 0.12))*vec2(1.4, 1))));
  vec3 col = hsl(hue, 0.66, l);

  if (scene >= 0){
    // the scene is a 3D-tilted plane: horizontals and verticals lean by
    // different angles (rot / lean), and a mild homography fans lines
    // across the screen like in the original
    float lean = rot + 0.08;
    mat2 M = inverse(mat2(cos(rot), sin(rot), -sin(lean), cos(lean)));
    vec2 uvp = uv / (1. + dot(uv, vec2(-0.08, 0.10)));
    vec2 c = cam + M*uvp*zoom;
    float aa = max(zoom/R.y*1.4, 0.004);
    vec3 ink = hsl(hue, 0.60, 0.17);
    vec2 prRO = scene == 0 ? vec2(-40, 155) : vec2(-70, 195);
    vec2 prRI = scene == 0 ? vec2(-40, 155) : vec2(-35, 355);
    bool inByX = scene == 1;
    // barely-there shadow cast down-right by the raised dots
    vec2 csh = c - vec2(0.22, 0.34);
    int bitSh = scene == 0 ? sceneWrite(csh, ts) : scenePaint(csh, t);
    if (bitSh == 1){
      float sh = dotCov(csh, cellScale(floor(csh), dIn, dOut, prRO, prRI, inByX), aa, 0.40);
      col = mix(col, col*0.88, sh*0.55);
    }
    int bit = scene == 0 ? sceneWrite(c, ts) : scenePaint(c, t);
    if (bit == 1){
      float cov = dotCov(c, cellScale(floor(c), dIn, dOut, prRO, prRI, inByX), aa, 0.);
      col = mix(col, ink, cov);
    }
  }
  col *= 1. - 0.16*dot(uv, uv)*2.4;
  O = vec4(col, 1);
}
