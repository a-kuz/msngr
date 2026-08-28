import MsngrCore

/// The stickers every pack starts with. Each is a transparent document: the
/// canvas is composited premultiplied, so a shader writes `vec4(col * a, a)`
/// and everything outside the figure stays clear. They are seeded into
/// `savedSticker` once and from then on live like any sticker the user added.
enum ShaderStickers {
    static let bundled: [ShaderDocument] = [heart, sparkle]

    /// A raymarched heart that beats when tapped. Buffer A holds its state in
    /// one texel: how excited it is and how long ago the last beat began. A tap
    /// starts a beat at once and adds excitement; excitement makes the beats
    /// come faster and stronger, lights a glow and lets small hearts float off,
    /// then fades over a few seconds. The beat drives the haptics too.
    static let heart = ShaderDocument(name: "Heart", passes: [
        ShaderPass(id: "common", kind: .common, code: """
        float dot2(vec2 v) { return dot(v, v); }
        // iq's heart: the tip at the origin, the lobes up to y ≈ 1.1, x within ±0.6
        float sdHeart(vec2 p) {
            p.x = abs(p.x);
            if (p.y + p.x > 1.0) return sqrt(dot2(p - vec2(0.25, 0.75))) - sqrt(2.0) / 4.0;
            return sqrt(min(dot2(p - vec2(0.0, 1.0)), dot2(p - 0.5 * max(p.x + p.y, 0.0)))) * sign(p.x - p.y);
        }
        // one contraction: rises to 1 at t = w, then relaxes
        float thump(float t, float w) { t = max(t, 0.0) / w; return t * exp(1.0 - t); }
        // a beat is the lub and the dub, stronger when excited
        float pulse(float beatT, float energy) {
            return (thump(beatT, 0.09) + 0.6 * thump(beatT - 0.21, 0.08)) * (0.45 + 0.55 * energy);
        }
        """, inputs: []),
        // The state, carried from frame to frame in texel (0, 0):
        // x excitement 0…1, y seconds since the last beat began,
        // w = 2 marks a written texel.
        ShaderPass(id: "A", kind: .buffer, code: """
        void mainImage(out vec4 O, in vec2 F) {
            vec4 s = texelFetch(iChannel3, ivec2(0, 0), 0);
            float energy = s.x, beatT = s.y;
            if (s.w < 1.5) { energy = 0.0; beatT = 0.0; }
            float dt = clamp(iTimeDelta, 0.0, 0.1);
            beatT += dt;
            energy *= exp(-dt / 2.8);
            // iMouse.w is positive on the frame a tap lands
            if (iMouse.w > 0.0) {
                beatT = 0.0;
                energy = min(1.0, energy + 0.4);
            }
            // resting the heart beats slowly, excited it races
            float interval = mix(1.5, 0.42, energy);
            if (beatT > interval) beatT = 0.0;
            O = vec4(energy, beatT, 0.0, 2.0);
        }
        """, inputs: [ShaderInput(channel: 3, source: ShaderInput.buffer("A"), wrap: "clamp", filter: "nearest")]),
        ShaderPass(id: ShaderPass.imageId, kind: .image, code: """
        float hash(float n) { return fract(sin(n) * 43758.5453); }
        mat2 rot(float a) { float c = cos(a), s = sin(a); return mat2(c, -s, s, c); }
        float dot3(vec3 v) { return dot(v, v); }
        float smin(float a, float b, float k) {
            float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
            return mix(b, a, h) - k * h * (1.0 - h);
        }
        float sdRoundCone(vec3 p, vec3 a, vec3 b, float r1, float r2) {
            vec3 ba = b - a;
            float l2 = dot(ba, ba), rr = r1 - r2, a2 = l2 - rr * rr, il2 = 1.0 / l2;
            vec3 pa = p - a;
            float y = dot(pa, ba), z = y - l2;
            float x2 = dot3(pa * l2 - ba * y), y2 = y * y * l2, z2 = z * z * l2;
            float k = sign(rr) * rr * rr * x2;
            if (sign(z) * a2 * z2 > k) return sqrt(x2 + z2) * il2 - r2;
            if (sign(y) * a2 * y2 < k) return sqrt(x2 + y2) * il2 - r1;
            return (sqrt(x2 * a2 * il2) + y * rr) * il2 - r1;
        }

        // the heart in three dimensions: two lobes blended into a tapering
        // body, the whole flattened front to back
        float map(vec3 p, float scale) {
            p /= scale;
            p.z *= 1.45;
            float lobes = smin(length(p - vec3(0.30, 0.28, 0.0)) - 0.46,
                               length(p - vec3(-0.30, 0.28, 0.0)) - 0.46, 0.05);
            float body = sdRoundCone(p, vec3(0.0, 0.15, 0.0), vec3(0.0, -0.72, 0.0), 0.50, 0.06);
            return smin(lobes, body, 0.2) / 1.45 * scale;
        }
        vec3 calcNormal(vec3 p, float scale) {
            vec2 e = vec2(0.002, 0.0);
            return normalize(vec3(map(p + e.xyy, scale) - map(p - e.xyy, scale),
                                  map(p + e.yxy, scale) - map(p - e.yxy, scale),
                                  map(p + e.yyx, scale) - map(p - e.yyx, scale)));
        }

        void mainImage(out vec4 O, in vec2 F) {
            vec2 uv = (F - 0.5 * iResolution.xy) / iResolution.y;
            float px = 1.5 / iResolution.y;
            vec4 s = texelFetch(iChannel0, ivec2(0, 0), 0);
            float energy = s.x, beatT = s.y;
            float beat = pulse(beatT, energy);
            float scale = 1.0 + 0.11 * beat;

            // the camera: a slow sway, a turn toward the finger while it is down
            float yaw = 0.30 * sin(iTime * 0.7), pitch = 0.10 + 0.08 * sin(iTime * 0.5);
            if (iMouse.z > 0.0) {
                vec2 m = (iMouse.xy - 0.5 * iResolution.xy) / iResolution.y;
                yaw += m.x * 0.8;
                pitch -= m.y * 0.6;
            }
            vec3 ro = vec3(0.0, 0.0, 3.0);
            vec3 rd = normalize(vec3(uv, -1.5));
            ro.yz = rot(pitch) * ro.yz; rd.yz = rot(pitch) * rd.yz;
            ro.xz = rot(yaw) * ro.xz; rd.xz = rot(yaw) * rd.xz;

            float t = 1.2, near = 1e3;
            bool hit = false;
            for (int i = 0; i < 96; i++) {
                vec3 p = ro + rd * t;
                float d = map(p, scale);
                near = min(near, d);
                if (d < 0.0015) { hit = true; break; }
                if (t > 5.0) break;
                t += d * 0.9;
            }

            vec3 col = vec3(0.0);
            float a = 0.0;
            if (hit) {
                vec3 p = ro + rd * t;
                vec3 n = calcNormal(p, scale);
                vec3 key = normalize(vec3(-0.55, 0.85, 0.9));
                vec3 fill = normalize(vec3(0.8, -0.2, 0.6));
                float ndl = dot(n, key);
                float dif = max(ndl, 0.0) * 0.85 + max(dot(n, fill), 0.0) * 0.25;
                float fres = pow(1.0 - max(dot(n, -rd), 0.0), 3.0);
                // red glass over a warm core: light leaks through where the key is behind
                vec3 deep = vec3(0.55, 0.01, 0.06);
                vec3 skin = vec3(0.95, 0.12, 0.2);
                vec3 base = mix(deep, skin, dif);
                base += vec3(0.9, 0.15, 0.2) * pow(clamp(-ndl, 0.0, 1.0), 2.0) * 0.5;
                base += vec3(1.0, 0.4, 0.5) * fres * 0.6;
                // the pink flush of excitement
                base = mix(base, vec3(1.0, 0.35, 0.5), energy * 0.35 * (0.5 + 0.5 * beat));
                vec3 r = reflect(rd, n);
                vec3 env = mix(vec3(0.25, 0.05, 0.1), vec3(1.0, 0.95, 0.95), smoothstep(-0.3, 0.9, r.y));
                col = base + env * (0.05 + 0.5 * fres);
                col += vec3(1.0) * pow(max(dot(r, key), 0.0), 90.0) * 1.4;
                col += vec3(1.0, 0.9, 0.9) * pow(max(dot(r, key), 0.0), 12.0) * 0.25;
                col += vec3(1.0) * pow(max(dot(r, fill), 0.0), 40.0) * 0.35;
                col = pow(clamp(col, 0.0, 1.0), vec3(0.9));
                a = 1.0;
            } else {
                // the glow around it, brighter with excitement and on each beat
                float glow = exp(-near * 5.0) * (0.15 + 0.85 * energy) * (0.5 + 0.5 * beat);
                // gone before the canvas edge, so the square never shows
                glow *= smoothstep(0.5, 0.28, max(abs(uv.x), abs(uv.y)));
                col = vec3(1.0, 0.3, 0.45) * glow;
                a = glow;
                // the rim: a ray that only just missed softens the silhouette
                float edge = smoothstep(0.006, 0.0, near);
                col = mix(col, vec3(0.8, 0.05, 0.15), edge);
                a = max(a, edge);
            }

            // small hearts floating off while it is excited
            for (int i = 0; i < 9; i++) {
                float fi = float(i);
                float life = fract(iTime * (0.35 + 0.25 * hash(fi * 3.7)) + hash(fi * 9.1));
                vec2 c = vec2((hash(fi * 1.7) - 0.5) * 0.5 + 0.04 * sin(iTime * 3.0 + fi * 2.0), -0.15 + life * 0.75);
                float size = 0.035 + 0.03 * hash(fi * 5.3);
                vec2 q = (uv - c) / size;
                q = rot(0.4 * sin(iTime * 2.0 + fi)) * q;
                float d = sdHeart(q + vec2(0.0, 0.5)) * size;
                float show = smoothstep(px, -px, d) * energy * smoothstep(0.0, 0.15, life) * (1.0 - life);
                vec3 pink = mix(vec3(1.0, 0.35, 0.5), vec3(1.0, 0.7, 0.8), hash(fi * 2.9));
                col = mix(col, pink, show);
                a = max(a, show);
            }

            // the shadow under it, closer and darker when it swells
            vec2 g = (uv - vec2(0.0, -0.44)) * vec2(1.0, 3.4);
            float shadow = smoothstep(0.34 * scale, 0.05, length(g)) * 0.35;
            a = max(a, shadow);

            // texel (0, 0) is read by the haptics: the beat as intensity
            if (F.x < 1.0 && F.y < 1.0) { O = vec4(beat * 0.9, 0.35, 0.0, 0.0); return; }
            O = vec4(col, a);
        }
        """, inputs: [ShaderInput(channel: 0, source: ShaderInput.buffer("A"), wrap: "clamp", filter: "nearest")]),
    ], haptics: true)

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
