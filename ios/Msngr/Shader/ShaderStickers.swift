import MsngrCore

/// The stickers every pack starts with. Each is a transparent document: the
/// canvas is composited premultiplied, so a shader writes `vec4(col * a, a)`
/// and everything outside the figure stays clear. They are seeded into
/// `savedSticker` once and from then on live like any sticker the user added.
enum ShaderStickers {
    static let bundled: [ShaderDocument] = [gloop, flameHeart, orb, sparkle]

    /// A gelatinous creature: a wobbling glossy body that hops in place, eyes
    /// that wander and blink, and follow the finger while it is down.
    static let gloop = ShaderDocument(name: "Gloop", passes: [
        ShaderPass(id: ShaderPass.imageId, kind: .image, code: """
        float hash(float n) { return fract(sin(n) * 43758.5453); }
        float noise1(float x) {
            float i = floor(x), f = fract(x);
            return mix(hash(i), hash(i + 1.0), f * f * (3.0 - 2.0 * f));
        }
        float disc(vec2 p, float r, float px) { return smoothstep(px, -px, length(p) - r); }

        void mainImage(out vec4 O, in vec2 F) {
            vec2 uv = (F - 0.5 * iResolution.xy) / iResolution.y;
            float px = 1.5 / iResolution.y;
            float t = iTime;

            // the hop: airborne on the top of the sine, squashed at the bottom
            float hop = abs(sin(t * 2.6));
            float squash = 1.0 + 0.14 * (0.5 - hop) * (1.0 + 0.6 * smoothstep(0.15, 0.0, hop));
            vec2 p = uv - vec2(0.0, -0.06 + 0.12 * hop);
            p.x /= squash;
            p.y *= squash;

            // the body: a disc with two slow waves running around its edge
            float ang = atan(p.y, p.x);
            float wob = 0.018 * sin(ang * 5.0 + t * 4.0) + 0.010 * sin(ang * 8.0 - t * 6.3);
            float r = 0.30 + wob;
            float d = length(p) - r;
            float body = smoothstep(px, -px, d);

            // shading as a soft sphere
            vec3 base = mix(iAccent.rgb, vec3(0.35, 0.85, 0.65), 0.6);
            vec2 q = p / r;
            vec3 n = normalize(vec3(q, sqrt(max(0.0, 1.0 - dot(q, q)))));
            vec3 light = normalize(vec3(-0.5, 0.75, 0.6));
            float diff = 0.55 + 0.45 * dot(n, light);
            vec3 col = base * diff;
            col = mix(base * 1.35, col, smoothstep(0.0, 0.22, -d));
            float spec = pow(max(dot(reflect(-light, n), vec3(0.0, 0.0, 1.0)), 0.0), 48.0);
            col += vec3(1.0) * spec * 0.85;
            // a wide soft gleam on the top left
            col += vec3(0.25) * disc(p - vec2(-0.11, 0.17), 0.05, 0.05) * 0.6;

            // eyes: a wandering gaze, the finger's when it is down, a blink every few seconds
            vec2 look = (vec2(noise1(t * 0.6), noise1(t * 0.8 + 11.0)) - 0.5) * 0.05;
            if (iMouse.z > 0.0) {
                vec2 m = (iMouse.xy - 0.5 * iResolution.xy) / iResolution.y;
                look = clamp(m * 0.16, vec2(-0.035), vec2(0.035));
            }
            float blink = smoothstep(0.0, 0.04, abs(fract(t * 0.29) - 0.5));
            blink = max(blink, 0.06);
            for (int i = 0; i < 2; i++) {
                float s = float(i) * 2.0 - 1.0;
                vec2 e = p - vec2(s * 0.115, 0.075);
                vec2 es = e;
                es.y /= blink;
                float white = disc(es, 0.072, px);
                float pupil = disc(es - look * vec2(1.0, 1.0 / blink), 0.036, px);
                float glint = disc(es - look - vec2(-0.014, 0.016), 0.011, px);
                vec3 eye = mix(vec3(0.98), vec3(0.08, 0.07, 0.1), pupil);
                eye = mix(eye, vec3(1.0), glint);
                col = mix(col, eye, white * body);
            }

            // cheeks and a smile
            for (int i = 0; i < 2; i++) {
                float s = float(i) * 2.0 - 1.0;
                float blush = disc(p - vec2(s * 0.19, -0.03), 0.045, 0.04);
                col = mix(col, vec3(1.0, 0.45, 0.55), blush * 0.45 * body);
            }
            float mouth = abs(length(p - vec2(0.0, 0.0)) - 0.125) - 0.009;
            float smile = smoothstep(px, -px, mouth) * smoothstep(-0.04, -0.07, p.y);
            col = mix(col, vec3(0.12, 0.05, 0.1), smile * body);

            // the shadow on the ground, small while it is up in the air
            vec2 g = (uv - vec2(0.0, -0.40)) * vec2(1.0, 3.2);
            float shadow = smoothstep(0.24, 0.02, length(g)) * (0.42 - 0.22 * hop);

            float a = max(body, shadow);
            vec3 rgb = col * body;
            O = vec4(rgb, a);
        }
        """, inputs: []),
    ])

    /// A glossy heart beating in a fire: the flames are noise sheared upward
    /// and cut by the distance to the heart, with embers drifting off the top.
    static let flameHeart = ShaderDocument(name: "Flame heart", passes: [
        ShaderPass(id: ShaderPass.imageId, kind: .image, code: """
        float hash21(vec2 p) {
            p = fract(p * vec2(123.34, 456.21));
            p += dot(p, p + 45.32);
            return fract(p.x * p.y);
        }
        float hash(float n) { return fract(sin(n) * 43758.5453); }
        float vnoise(vec2 p) {
            vec2 i = floor(p), f = fract(p);
            f = f * f * (3.0 - 2.0 * f);
            return mix(mix(hash21(i), hash21(i + vec2(1.0, 0.0)), f.x),
                       mix(hash21(i + vec2(0.0, 1.0)), hash21(i + vec2(1.0, 1.0)), f.x), f.y);
        }
        float fbm(vec2 p) {
            float v = 0.0, a = 0.5;
            mat2 m = mat2(1.6, 1.2, -1.2, 1.6);
            for (int i = 0; i < 5; i++) { v += a * vnoise(p); p = m * p; a *= 0.5; }
            return v;
        }
        float dot2(vec2 v) { return dot(v, v); }
        float sdHeart(vec2 p) {
            p.x = abs(p.x);
            if (p.y + p.x > 1.0) return sqrt(dot2(p - vec2(0.25, 0.75))) - sqrt(2.0) / 4.0;
            return sqrt(min(dot2(p - vec2(0.0, 1.0)), dot2(p - 0.5 * max(p.x + p.y, 0.0)))) * sign(p.x - p.y);
        }
        vec3 ramp(float x) {
            vec3 c = mix(vec3(0.55, 0.02, 0.0), vec3(1.0, 0.38, 0.02), smoothstep(0.0, 0.55, x));
            return mix(c, vec3(1.0, 0.96, 0.7), smoothstep(0.6, 1.0, x));
        }

        void mainImage(out vec4 O, in vec2 F) {
            vec2 uv = (F - 0.5 * iResolution.xy) / iResolution.y;
            float px = 1.5 / iResolution.y;
            float t = iTime;

            // the beat: a thump and a lighter one right after, then rest
            float ph = fract(t * 1.15);
            float beat = exp(-ph * 9.0) * 0.6 + exp(-abs(ph - 0.28) * 14.0) * 0.4;
            float size = 0.5 * (1.0 + 0.09 * beat);
            vec2 hp = (uv + vec2(0.0, 0.30)) / size;
            float dh = sdHeart(hp) * size;

            // flames: noise blown upward, fed by the heart's edge, thinning with height
            vec2 fp = vec2(uv.x * 4.2, uv.y * 3.0 - t * 2.4);
            float n = fbm(fp + 0.35 * fbm(fp * 1.7 + vec2(0.0, -t * 1.2)));
            float above = max(uv.y + 0.02, 0.0);
            float fire = n * 1.35 - dh * 3.2 - above * 1.6 - 0.15;
            fire *= smoothstep(-0.02, 0.10, dh);
            fire = clamp(fire, 0.0, 1.0);
            float fa = smoothstep(0.02, 0.35, fire);
            vec3 col = ramp(fire) * fa;

            // embers off the top
            for (int i = 0; i < 14; i++) {
                float fi = float(i);
                float life = fract(t * (0.25 + 0.2 * hash(fi * 3.1)) + hash(fi * 7.7));
                vec2 c = vec2((hash(fi * 1.3) - 0.5) * 0.5 + 0.05 * sin(t * 2.0 + fi), -0.05 + life * 0.6);
                c.x += 0.03 * sin(life * 12.0 + fi);
                float d = length(uv - c);
                float g = (0.0025 + 0.002 * hash(fi)) / (d + 1e-4);
                g = g * g * (1.0 - life) * smoothstep(0.0, 0.1, life);
                col += vec3(1.0, 0.55, 0.15) * g;
                fa = max(fa, clamp(g, 0.0, 1.0));
            }

            // the heart itself: red glass with a sphere's light on it
            float heart = smoothstep(px, -px, dh);
            vec2 q = hp - vec2(0.0, 0.55);
            vec3 nn = normalize(vec3(q * 0.9, sqrt(max(0.0, 1.0 - dot(q * 0.9, q * 0.9)))));
            vec3 light = normalize(vec3(-0.5, 0.8, 0.6));
            float diff = 0.5 + 0.5 * dot(nn, light);
            vec3 hc = mix(vec3(0.62, 0.02, 0.08), vec3(1.0, 0.25, 0.3), diff);
            hc = mix(hc * 1.4, hc, smoothstep(0.0, 0.08, -dh));
            float spec = pow(max(dot(reflect(-light, nn), vec3(0.0, 0.0, 1.0)), 0.0), 36.0);
            hc += vec3(1.0, 0.9, 0.9) * spec * 0.9;
            // the fire's light through the edge on every beat
            hc += vec3(1.0, 0.5, 0.2) * smoothstep(0.06, 0.0, -dh) * (0.25 + 0.5 * beat);

            col = mix(col, hc, heart);
            float a = max(fa, heart);
            O = vec4(col, a);
        }
        """, inputs: []),
    ])

    /// A raymarched drop of liquid metal: four spheres blended into one core,
    /// lit with two lights, a fresnel rim and an iridescent film, turning on its
    /// own and under the finger.
    static let orb = ShaderDocument(name: "Orb", passes: [
        ShaderPass(id: ShaderPass.imageId, kind: .image, code: """
        float smin(float a, float b, float k) {
            float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
            return mix(b, a, h) - k * h * (1.0 - h);
        }
        float map(vec3 q) {
            float t = iTime;
            float d = length(q) - 0.5;
            for (int i = 0; i < 4; i++) {
                float fi = float(i);
                vec3 c = vec3(sin(t * 0.9 + fi * 1.7), cos(t * 1.1 + fi * 2.3), sin(t * 0.7 + fi * 0.9)) * 0.42;
                d = smin(d, length(q - c) - 0.28, 0.3);
            }
            return d;
        }
        vec3 calcNormal(vec3 p) {
            vec2 e = vec2(0.002, 0.0);
            return normalize(vec3(map(p + e.xyy) - map(p - e.xyy),
                                  map(p + e.yxy) - map(p - e.yxy),
                                  map(p + e.yyx) - map(p - e.yyx)));
        }
        vec3 pal(float h) { return 0.5 + 0.5 * cos(6.2831 * (h + vec3(0.0, 0.33, 0.67))); }
        mat2 rot(float a) { float c = cos(a), s = sin(a); return mat2(c, -s, s, c); }

        void mainImage(out vec4 O, in vec2 F) {
            vec2 uv = (F - 0.5 * iResolution.xy) / iResolution.y;
            float t = iTime;

            // the camera: a slow turn, plus whatever the finger dragged
            vec2 spin = vec2(t * 0.35, 0.35 + 0.15 * sin(t * 0.5));
            if (iMouse.z > 0.0) spin += (iMouse.xy - iMouse.zw) / iResolution.y * 4.0 * vec2(1.0, -1.0);
            vec3 ro = vec3(0.0, 0.0, 3.2);
            vec3 rd = normalize(vec3(uv, -1.7));
            ro.yz = rot(spin.y) * ro.yz; rd.yz = rot(spin.y) * rd.yz;
            ro.xz = rot(spin.x) * ro.xz; rd.xz = rot(spin.x) * rd.xz;

            float dist = 0.0, near = 1e3;
            bool hit = false;
            for (int i = 0; i < 72; i++) {
                vec3 p = ro + rd * dist;
                float d = map(p);
                near = min(near, d);
                if (d < 0.0015) { hit = true; break; }
                dist += d * 0.9;
                if (dist > 6.0) break;
            }

            vec3 col = vec3(0.0);
            float a = 0.0;
            if (hit) {
                vec3 p = ro + rd * dist;
                vec3 n = calcNormal(p);
                float fres = pow(1.0 - max(dot(n, -rd), 0.0), 3.0);
                vec3 l1 = normalize(vec3(-0.6, 0.8, 0.7));
                vec3 l2 = normalize(vec3(0.7, -0.4, 0.5));
                vec3 base = pal(n.y * 0.35 + n.x * 0.2 + t * 0.08) * 0.6 + 0.35;
                base = mix(base, iAccent.rgb, 0.2);
                float dif = max(dot(n, l1), 0.0) * 0.75 + max(dot(n, l2), 0.0) * 0.4 + 0.35;
                col = base * dif;
                vec3 r = reflect(rd, n);
                vec3 env = mix(vec3(0.35, 0.25, 0.6), vec3(1.0), smoothstep(-0.5, 0.9, r.y));
                col += env * (0.15 + 0.8 * fres);
                col += vec3(1.0) * pow(max(dot(r, l1), 0.0), 70.0) * 1.3;
                col += vec3(0.9, 0.95, 1.0) * pow(max(dot(r, l2), 0.0), 30.0) * 0.5;
                // the film: a thin iridescent sheen turning with the view
                col += pal(fres * 1.5 + t * 0.1) * fres * 0.5;
                col = pow(clamp(col, 0.0, 1.0), vec3(0.85));
                a = 1.0;
            }
            // a soft edge where a ray only just missed
            float edge = smoothstep(0.02, 0.0, near) * 0.5;
            if (!hit) { a = edge; col = vec3(0.8, 0.85, 1.0) * edge; }

            // the shadow under it
            vec2 g = (uv - vec2(0.0, -0.42)) * vec2(1.0, 3.6);
            float shadow = smoothstep(0.30, 0.04, length(g)) * 0.4;
            a = max(a, shadow);

            O = vec4(col, a);
        }
        """, inputs: []),
    ])

    /// An app icon embossed with the Claude sparkle, raymarched and orbiting
    /// under the finger, the rays running in a wave. The sparkle's shape is a
    /// 112-vertex polygon: Buffer A bakes its distance field once, with the
    /// wave's angular weights alongside, and the march samples that texture
    /// instead of walking the polygon at every step.
    static let sparkle = ShaderDocument(name: "Sparkle", passes: [
        ShaderPass(id: "common", kind: .common, code: """
        const float TAU = 6.28318530718;
        // the sparkle's distance field is baked over this square
        const float BAKE = 1.6;
        const int NP = 112;
        const float ANG[12] = float[12](0.2619, 0.7678, 1.0647, 1.6580, 2.1468, 2.5309,
                                        3.1416, 3.7003, 4.2236, 4.8692, 5.4455, 6.1435);
        const float LEN[12] = float[12](0.922, 0.947, 0.922, 0.954, 0.960, 0.918,
                                        0.953, 0.949, 1.000, 0.871, 0.901, 0.891);
        const vec2 POLY[112] = vec2[112](
            vec2(0.672,0.),vec2(0.408,0.057),vec2(0.844,0.164),vec2(0.881,0.203),vec2(0.891,0.239),vec2(0.87,0.266),vec2(0.809,0.295),vec2(0.702,0.284),
            vec2(0.297,0.185),vec2(0.26,0.182),vec2(0.286,0.216),vec2(0.562,0.472),vec2(0.653,0.568),vec2(0.694,0.625),vec2(0.681,0.657),vec2(0.658,0.658),
            vec2(0.556,0.596),vec2(0.262,0.361),vec2(0.474,0.73),vec2(0.471,0.783),vec2(0.46,0.797),vec2(0.431,0.811),vec2(0.396,0.811),vec2(0.343,0.77),
            vec2(0.308,0.726),vec2(0.061,0.345),vec2(0.048,0.389),vec2(0.013,0.764),vec2(-0.016,0.919),vec2(-0.033,0.937),vec2(-0.067,0.951),vec2(-0.099,0.944),
            vec2(-0.128,0.913),vec2(-0.11,0.697),vec2(-0.058,0.297),vec2(-0.279,0.599),vec2(-0.387,0.727),vec2(-0.462,0.8),vec2(-0.49,0.815),vec2(-0.523,0.805),
            vec2(-0.543,0.775),vec2(-0.425,0.586),vec2(-0.192,0.246),vec2(-0.559,0.486),vec2(-0.67,0.543),vec2(-0.698,0.546),vec2(-0.739,0.537),vec2(-0.76,0.512),
            vec2(-0.761,0.476),vec2(-0.723,0.435),vec2(-0.547,0.315),vec2(-0.226,0.12),vec2(-0.227,0.11),vec2(-0.31,0.101),vec2(-0.861,0.075),vec2(-0.911,0.064),
            vec2(-0.933,0.049),vec2(-0.952,0.017),vec2(-0.953,0.),vec2(-0.942,-0.017),vec2(-0.703,-0.025),vec2(-0.246,-0.017),vec2(-0.707,-0.33),vec2(-0.791,-0.403),
            vec2(-0.804,-0.427),vec2(-0.812,-0.469),vec2(-0.805,-0.503),vec2(-0.77,-0.539),vec2(-0.723,-0.545),vec2(-0.605,-0.473),vec2(-0.236,-0.213),vec2(-0.247,-0.247),
            vec2(-0.441,-0.585),vec2(-0.52,-0.743),vec2(-0.526,-0.78),vec2(-0.516,-0.826),vec2(-0.483,-0.871),vec2(-0.454,-0.89),vec2(-0.375,-0.883),vec2(-0.344,-0.85),
            vec2(-0.061,-0.289),vec2(-0.023,-0.187),vec2(-0.014,-0.199),vec2(0.037,-0.703),vec2(0.056,-0.799),vec2(0.089,-0.844),vec2(0.121,-0.86),vec2(0.15,-0.854),
            vec2(0.189,-0.818),vec2(0.196,-0.787),vec2(0.184,-0.641),vec2(0.113,-0.242),vec2(0.124,-0.243),vec2(0.148,-0.268),vec2(0.361,-0.535),vec2(0.475,-0.653),
            vec2(0.513,-0.681),vec2(0.537,-0.688),vec2(0.591,-0.68),vec2(0.638,-0.616),vec2(0.643,-0.6),vec2(0.625,-0.524),vec2(0.381,-0.194),vec2(0.317,-0.079),
            vec2(0.602,-0.128),vec2(0.781,-0.152),vec2(0.853,-0.15),vec2(0.882,-0.124),vec2(0.881,-0.093),vec2(0.869,-0.061),vec2(0.793,-0.028),vec2(0.728,-0.013));
        """, inputs: []),
        // Buffer A, one texel per point of the bake square: the static distance
        // to the sparkle in r, and in gba the three angular weights the wave's
        // scale is a cosine combination of. Computed once, then carried over
        // from the previous frame; a cleared buffer (g = 0) is baked again.
        ShaderPass(id: "A", kind: .buffer, code: """
        float angDist(float a, float b) { float d = abs(a - b); return min(d, TAU - d); }

        float sdPolyStatic(vec2 p) {
            float d = dot(p - POLY[0], p - POLY[0]);
            float s = 1.0;
            vec2 vj = POLY[NP - 1];
            for (int i = 0; i < NP; i++) {
                vec2 vi = POLY[i];
                vec2 e = vj - vi, w = p - vi;
                vec2 b = w - e * clamp(dot(w, e) / dot(e, e), 0.0, 1.0);
                d = min(d, dot(b, b));
                bool c0 = p.y >= vi.y, c1 = p.y < vj.y, c2 = e.x * w.y > e.y * w.x;
                if (c0 == c1 && c1 == c2) s = -s;
                vj = vi;
            }
            return s * sqrt(d);
        }

        void mainImage(out vec4 O, in vec2 F) {
            vec4 prev = texelFetch(iChannel3, ivec2(F), 0);
            if (prev.g > 0.5) { O = prev; return; }
            vec2 p = (F / iResolution.xy - 0.5) * 2.0 * BAKE;
            float ang = atan(p.y, p.x);
            if (ang < 0.0) ang += TAU;
            float w0 = 0.0, wc = 0.0, ws = 0.0, den = 0.0;
            for (int i = 0; i < 12; i++) {
                float dd = angDist(ang, ANG[i]);
                float w = pow(max(0.0, cos(min(dd * 1.6, TAU * 0.25))), 6.0) + 0.0005;
                float inv = w / LEN[i];
                w0 += inv; wc += inv * cos(ANG[i]); ws += inv * sin(ANG[i]);
                den += w;
            }
            O = vec4(sdPolyStatic(p), 0.72 * w0 / den, 0.20 * wc / den, 0.20 * ws / den);
        }
        """, inputs: [ShaderInput(channel: 3, source: ShaderInput.buffer("A"), wrap: "clamp", filter: "nearest")]),
        ShaderPass(id: ShaderPass.imageId, kind: .image, code: """
        const vec3 TERRA = vec3(0.741, 0.388, 0.290);
        const vec3 CREAM = vec3(0.965, 0.955, 0.93);

        vec4 bake(vec2 p) { return texture(iChannel0, p / (2.0 * BAKE) + 0.5); }

        // the sparkle with the running wave on its rays: the scale at this
        // angle from the baked weights, the distance from the baked field
        float sdPoly(vec2 p, float t) {
            vec4 k = bake(normalize(p + vec2(1e-5, 0.0)) * 0.8);
            float ph = TAU * t;
            float sc = k.g + cos(ph) * k.b + sin(ph) * k.a;
            return bake(p / sc).r * sc;
        }
        float sdSquircle(vec2 p, float hf, float n) {
            p = abs(p) / hf;
            float k = pow(pow(p.x, n) + pow(p.y, n), 1.0 / n);
            return (k - 1.0) * hf;
        }
        float sdIcon(vec3 p, float hf, float hz, float bevel) {
            float dxy = sdSquircle(p.xy, hf, 4.5);
            vec2 w = vec2(dxy, abs(p.z) - hz);
            return min(max(w.x, w.y), 0.0) + length(max(w, 0.0)) - bevel;
        }
        float map(vec3 pos, float t) {
            float box = sdIcon(pos, 1.25, 0.10, 0.03);
            if (pos.z < 0.045 || pos.z > 0.16) return box;
            float d2 = sdPoly(pos.xy, t);
            vec2 w = vec2(d2, abs(pos.z - 0.12) - 0.06);
            float prism = min(max(w.x, w.y), 0.0) + length(max(w, 0.0));
            return max(box, -prism);
        }
        vec3 calcNormal(vec3 p, float t) {
            vec2 k = vec2(1.0, -1.0);
            float e = 0.0016;
            return normalize(k.xyy * map(p + k.xyy * e, t) + k.yyx * map(p + k.yyx * e, t) +
                             k.yxy * map(p + k.yxy * e, t) + k.xxx * map(p + k.xxx * e, t));
        }

        void mainImage(out vec4 O, in vec2 F) {
            vec2 uv = (F - 0.5 * iResolution.xy) / iResolution.y;

            float yaw = -0.42 + 0.12 * sin(iTime * 0.6), pitch = 0.34 + 0.06 * cos(iTime * 0.8);
            if (iMouse.z > 0.0) {
                yaw = -0.42 + (iMouse.x - 0.5 * iResolution.x) / iResolution.x * 3.0;
                pitch = clamp(0.34 - (iMouse.y - 0.5 * iResolution.y) / iResolution.y * 3.0, -1.3, 1.3);
            }
            float cp = cos(pitch), sp = sin(pitch), cy = cos(yaw), sy = sin(yaw);
            float R = 6.0;
            vec3 ro = vec3(R * cp * sy, R * sp, R * cp * cy);
            vec3 fw = normalize(-ro);
            vec3 rt = normalize(cross(fw, vec3(0.0, 1.0, 0.0)));
            vec3 up = cross(rt, fw);
            vec3 rd = normalize(uv.x * rt + uv.y * up + 1.75 * fw);

            // the sphere around the icon first, then the icon itself
            float t = 0.0;
            bool hit = false;
            for (int i = 0; i < 24; i++) {
                float d = length(ro + rd * t) - 2.0;
                if (d < 0.01 || t > 8.0) break;
                t += d;
            }
            if (t < 8.0) {
                for (int i = 0; i < 72; i++) {
                    float d = map(ro + rd * t, iTime);
                    if (d < 0.0008) { hit = true; break; }
                    if (t > 8.0) break;
                    t += d * 0.85;
                }
            }

            vec3 col = vec3(0.0);
            float a = 0.0;
            if (hit) {
                vec3 pos = ro + rd * t;
                vec3 n = calcNormal(pos, iTime);
                vec3 Lk = normalize(vec3(0.45, 0.7, 0.7));
                vec3 Lf = normalize(vec3(-0.5, 0.2, 0.5));
                float difK = clamp(dot(n, Lk), 0.0, 1.0);
                float difF = clamp(dot(n, Lf), 0.0, 1.0);
                float spec = pow(clamp(dot(reflect(-Lk, n), -rd), 0.0, 1.0), 48.0);
                float inset = smoothstep(0.105, 0.075, pos.z);
                vec3 albedo = mix(TERRA, CREAM, inset);
                float ao = mix(0.80, 1.0, smoothstep(0.06, 0.105, pos.z));
                float sheen = pow(clamp(0.5 + 0.5 * n.y, 0.0, 1.0), 3.0);
                col = albedo * 0.42 + albedo * difK * 0.70 + albedo * difF * 0.20;
                col *= ao;
                col += albedo * sheen * 0.10;
                col += spec * vec3(1.0) * 0.16 * (1.0 - inset);
                col = pow(clamp(col, 0.0, 1.0), vec3(0.4545));
                a = 1.0;
            }

            // the shadow on the ground under the plate
            vec2 g = (uv - vec2(0.0, -0.36)) * vec2(1.0, 2.8);
            float shadow = smoothstep(0.42, 0.12, length(g)) * 0.35;
            a = max(a, shadow);
            O = vec4(col, a);
        }
        """, inputs: [ShaderInput(channel: 0, source: ShaderInput.buffer("A"), wrap: "clamp", filter: "linear")]),
    ])
}
