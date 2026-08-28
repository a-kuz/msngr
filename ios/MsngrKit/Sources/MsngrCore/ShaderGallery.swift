import Foundation

/// The showcase: one shader for every surface the product draws a shader on,
/// written to be seen in a hand. The stickers are transparent documents that
/// answer a tap; the background leans with the phone; the bubble shaders read
/// where the bubble sits on the screen; the avatars are what the peers see.
/// The app seeds the stickers into every new pack, and `msngrfixture showcase`
/// puts the whole set onto the stand's service accounts.
public enum ShaderGallery {
    public static let stickers: [ShaderDocument] = [pond, fireworks, eye, smoke, clock]
    public static let backgrounds: [ShaderDocument] = [aurora]
    public static let bubbles: [ShaderDocument] = [foil, ember]
    public static let avatars: [ShaderDocument] = [nebula, orbit]
    public static var all: [ShaderDocument] { stickers + backgrounds + bubbles + avatars }

    static func stateInput(_ id: String, filter: String = "nearest") -> ShaderInput {
        ShaderInput(channel: 3, source: ShaderInput.buffer(id), wrap: "clamp", filter: filter)
    }

    static func readInput(_ id: String, filter: String = "linear") -> ShaderInput {
        ShaderInput(channel: 0, source: ShaderInput.buffer(id), wrap: "clamp", filter: filter)
    }

    // MARK: - Stickers

    /// A round pond. Buffer A is a height field stepping the wave equation;
    /// a finger is a drop where it lands, and a drop of rain falls on its own
    /// every couple of seconds so the water is never still.
    public static let pond = ShaderDocument(name: "Pond", passes: [
        ShaderPass(id: "A", kind: .buffer, code: """
        float hash(float n) { return fract(sin(n) * 43758.5453); }
        void mainImage(out vec4 O, in vec2 F) {
            ivec2 p = ivec2(F);
            vec4 s = texelFetch(iChannel3, p, 0);
            float h = s.x, hp = s.y;
            float l = texelFetch(iChannel3, p + ivec2(1, 0), 0).x + texelFetch(iChannel3, p - ivec2(1, 0), 0).x
                    + texelFetch(iChannel3, p + ivec2(0, 1), 0).x + texelFetch(iChannel3, p - ivec2(0, 1), 0).x;
            if (s.w < 1.5) { h = 0.0; hp = 0.0; l = 0.0; }
            float nh = (2.0 * h - hp + 0.4 * (l - 4.0 * h)) * 0.985;
            float r = 0.025 * iResolution.y;
            if (iMouse.z > 0.0) {
                vec2 d = F - iMouse.xy;
                nh -= 0.4 * exp(-dot(d, d) / (r * r));
            }
            // a drop of rain: one frame every 1.7 s, somewhere inside the pond
            float k = floor(iTime / 1.7);
            if (fract(iTime / 1.7) * 1.7 < clamp(iTimeDelta, 0.008, 0.05)) {
                vec2 c = 0.5 * iResolution.xy + (vec2(hash(k * 3.1), hash(k * 7.7)) - 0.5) * 0.6 * iResolution.y;
                vec2 d = F - c;
                nh -= 0.6 * exp(-dot(d, d) / (r * r * 0.5));
            }
            O = vec4(clamp(nh, -1.2, 1.2), h, 0.0, 2.0);
        }
        """, inputs: [stateInput("A")]),
        ShaderPass(id: ShaderPass.imageId, kind: .image, code: """
        float hash2(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
        float noise(vec2 p) {
            vec2 i = floor(p), f = fract(p);
            f = f * f * (3.0 - 2.0 * f);
            return mix(mix(hash2(i), hash2(i + vec2(1.0, 0.0)), f.x),
                       mix(hash2(i + vec2(0.0, 1.0)), hash2(i + vec2(1.0, 1.0)), f.x), f.y);
        }
        void mainImage(out vec4 O, in vec2 F) {
            vec2 uv = (F - 0.5 * iResolution.xy) / iResolution.y;
            float px = 1.5 / iResolution.y;
            float rad = 0.42;
            float dist = length(uv) - rad;
            ivec2 p = ivec2(F);
            float h = texelFetch(iChannel0, p, 0).x;
            float hx = texelFetch(iChannel0, p + ivec2(1, 0), 0).x - texelFetch(iChannel0, p - ivec2(1, 0), 0).x;
            float hy = texelFetch(iChannel0, p + ivec2(0, 1), 0).x - texelFetch(iChannel0, p - ivec2(0, 1), 0).x;
            vec3 n = normalize(vec3(-hx * 3.0, -hy * 3.0, 1.0));
            // the bottom seen through the water, nudged by the surface
            vec2 q = uv + n.xy * 0.05;
            float rr = length(q) / rad;
            // sand at the rim, deep teal toward the middle
            float sand = noise(q * 24.0) * 0.55 + noise(q * 52.0 + 3.7) * 0.45;
            vec3 bottom = vec3(0.78, 0.68, 0.50) * (0.8 + 0.3 * sand);
            float depth = smoothstep(1.02, 0.3, rr);
            vec3 col = mix(bottom, vec3(0.05, 0.33, 0.45), 0.2 + 0.7 * depth);
            // the rings: a lit crest, a shaded trough
            col += vec3(0.7, 0.95, 0.9) * clamp(h * 2.2, 0.0, 0.8);
            col -= vec3(0.10, 0.18, 0.20) * clamp(-h * 2.0, 0.0, 0.6);
            vec3 L = normalize(vec3(-0.5, 0.7, 0.6));
            vec3 V = vec3(0.0, 0.0, 1.0);
            float spec = pow(max(dot(reflect(-L, n), V), 0.0), 60.0);
            col += vec3(1.0) * spec * 0.5;
            // the rim of the pond
            float rim = smoothstep(0.0, -0.035, dist);
            col = mix(vec3(0.35, 0.3, 0.25) * (0.8 + 0.4 * (1.0 - smoothstep(-0.04, 0.0, dist))), col, rim);
            float a = smoothstep(px, -px, dist);
            // the shadow under it
            vec2 sh = (uv - vec2(0.0, -0.44)) * vec2(1.0, 3.5);
            float shadow = smoothstep(0.42, 0.1, length(sh)) * 0.3 * (1.0 - a);
            col = mix(col, vec3(0.0), (1.0 - a) * shadow / max(shadow, 1e-4) * shadow);
            a = max(a, shadow);
            O = vec4(col * a, a);
        }
        """, inputs: [readInput("A", filter: "nearest")]),
    ])

    /// Fireworks. Buffer A holds four rockets in four texels: a tap launches
    /// the next one toward the finger, and one goes up on its own when nobody
    /// has tapped for a while. The image draws each rocket's climb, then its
    /// burst of sparks under gravity.
    public static let fireworks = ShaderDocument(name: "Fireworks", passes: [
        ShaderPass(id: "common", kind: .common, code: """
        float hash(float n) { return fract(sin(n) * 43758.5453); }
        const float CLIMB = 0.8;
        const float LIFE = 3.4;
        const float AUTO = 2.6;
        """, inputs: []),
        ShaderPass(id: "A", kind: .buffer, code: """
        void mainImage(out vec4 O, in vec2 F) {
            ivec2 p = ivec2(F);
            if (p.y > 0 || p.x > 4) { O = vec4(0.0); return; }
            vec4 s = texelFetch(iChannel3, p, 0);
            vec4 meta = texelFetch(iChannel3, ivec2(4, 0), 0);
            // meta: last launch time, the written mark, the next slot
            if (meta.y < 1.5) { s = vec4(0.0, 0.0, -100.0, 0.0); meta = vec4(-100.0, 2.0, 0.0, 0.0); }
            bool launch = false;
            vec2 target = vec2(0.0);
            if (iMouse.w > 0.0) {
                launch = true;
                target = iMouse.xy;
            } else if (iTime - meta.x > AUTO) {
                launch = true;
                float k = floor(iTime * 10.0);
                target = iResolution.xy * vec2(0.2 + 0.6 * hash(k * 1.3), 0.5 + 0.35 * hash(k * 2.9));
            }
            int slot = int(meta.z + 0.5);
            if (p.x == 4) {
                if (launch) { meta.x = iTime; meta.z = mod(meta.z + 1.0, 4.0); }
                O = meta;
                return;
            }
            if (launch && p.x == slot) s = vec4(target, iTime, hash(iTime * 17.0 + float(slot)));
            O = s;
        }
        """, inputs: [stateInput("A")]),
        ShaderPass(id: ShaderPass.imageId, kind: .image, code: """
        vec3 pal(float h) { return 0.55 + 0.45 * cos(6.2831 * (h + vec3(0.0, 0.33, 0.67))); }
        void mainImage(out vec4 O, in vec2 F) {
            vec2 uv = F / iResolution.y;
            vec3 col = vec3(0.0);
            float a = 0.0;
            for (int i = 0; i < 4; i++) {
                vec4 s = texelFetch(iChannel0, ivec2(i, 0), 0);
                float age = iTime - s.z;
                if (age < 0.0 || age > LIFE) continue;
                vec2 target = s.xy / iResolution.y;
                vec3 tint = pal(s.w);
                if (age < CLIMB) {
                    // the climb: a bright head with a trail of embers
                    float k = age / CLIMB;
                    vec2 start = vec2(target.x + 0.08 * (s.w - 0.5), 0.0);
                    for (int j = 0; j < 8; j++) {
                        float kk = k - float(j) * 0.02;
                        if (kk < 0.0) continue;
                        vec2 pos = mix(start, target, 1.0 - (1.0 - kk) * (1.0 - kk));
                        pos.x += 0.01 * sin(kk * 40.0 + s.w * 10.0);
                        float d = length(uv - pos);
                        float g = 0.0035 / (d + 1e-4);
                        g = g * g * (j == 0 ? 1.0 : 0.25 / (1.0 + float(j)));
                        col += mix(vec3(1.0, 0.9, 0.7), tint, 0.4) * g;
                        a += g;
                    }
                } else {
                    float t = age - CLIMB;
                    float fade = smoothstep(LIFE - CLIMB, 0.5, t);
                    float flash = exp(-t * 12.0);
                    float d0 = length(uv - target);
                    col += vec3(1.0) * flash * 0.02 / (d0 + 0.01);
                    a += flash * 0.02 / (d0 + 0.01);
                    for (int j = 0; j < 44; j++) {
                        float fj = float(j) + s.w * 100.0;
                        float ang = hash(fj * 7.1) * 6.2831;
                        float spd = 0.22 + 0.16 * hash(fj * 3.3);
                        vec2 dir = vec2(cos(ang), sin(ang));
                        vec2 pos = target + dir * spd * (1.0 - exp(-1.6 * t)) / 1.6 * 1.6;
                        pos.y -= 0.10 * t * t;
                        float d = length(uv - pos);
                        float r = 0.0028 + 0.0015 * hash(fj * 5.7);
                        float g = r / (d + 1e-4);
                        float twinkle = 0.6 + 0.4 * sin(t * 18.0 + fj);
                        g = g * g * fade * twinkle;
                        col += mix(tint, vec3(1.0), smoothstep(0.3, 0.0, t)) * g;
                        a += g;
                    }
                }
            }
            O = vec4(min(col, vec3(1.0)), clamp(a, 0.0, 1.0));
        }
        """, inputs: [readInput("A", filter: "nearest")]),
    ])

    /// An eye that watches the finger. Buffer A keeps where it is looking, so
    /// the gaze glides after the touch instead of jumping, and when it blinked
    /// last: a tap makes it blink, and it blinks on its own now and then.
    public static let eye = ShaderDocument(name: "Eye", passes: [
        ShaderPass(id: "A", kind: .buffer, code: """
        float hash(float n) { return fract(sin(n) * 43758.5453); }
        void mainImage(out vec4 O, in vec2 F) {
            vec4 s = texelFetch(iChannel3, ivec2(0, 0), 0);
            if (s.w < 1.5) s = vec4(0.0, 0.0, -10.0, 2.0);
            float dt = clamp(iTimeDelta, 0.0, 0.1);
            vec2 target;
            if (iMouse.z > 0.0) {
                target = (iMouse.xy - 0.5 * iResolution.xy) / iResolution.y * 1.6;
            } else {
                // looking around: it settles on a point, then moves to the next
                float seg = floor(iTime / 1.8);
                target = vec2(hash(seg * 3.7) - 0.5, hash(seg * 9.1) - 0.5) * 0.5;
            }
            float len = length(target);
            if (len > 0.3) target *= 0.3 / len;
            float k = 1.0 - exp(-dt * (iMouse.z > 0.0 ? 14.0 : 6.0));
            vec2 gaze = mix(s.xy, target, k);
            float blink = s.z;
            if (iMouse.w > 0.0 || (iTime - blink > 2.5 && hash(floor(iTime * 4.0)) < 0.03)) blink = iTime;
            O = vec4(gaze, blink, 2.0);
        }
        """, inputs: [stateInput("A")]),
        ShaderPass(id: ShaderPass.imageId, kind: .image, code: """
        void mainImage(out vec4 O, in vec2 F) {
            vec2 uv = (F - 0.5 * iResolution.xy) / iResolution.y;
            float px = 1.5 / iResolution.y;
            vec4 s = texelFetch(iChannel0, ivec2(0, 0), 0);
            vec2 gaze = s.xy;
            float t = iTime - s.z;
            float closed = smoothstep(0.0, 0.07, t) * (1.0 - smoothstep(0.09, 0.26, t));
            float open = 1.0 - 0.96 * closed;
            // the almond: the lids meet at the corners
            float w = 0.46;
            float x = clamp(uv.x / w, -1.0, 1.0);
            float lidTop = 0.30 * (1.0 - x * x) * open;
            float lidBot = 0.24 * (1.0 - x * x) * (0.6 + 0.4 * open);
            float d = uv.y > 0.0 ? uv.y - lidTop : -uv.y - lidBot;
            if (abs(uv.x) > w) d = max(d, abs(uv.x) - w);
            float inside = smoothstep(px, -px, d);
            // the sclera, shaded toward the lids
            vec3 col = vec3(0.97, 0.96, 0.95) * (0.72 + 0.28 * smoothstep(0.0, 0.12, -d));
            // the iris follows the gaze; the pupil widens under a finger
            vec2 c = gaze * 0.6;
            float ri = 0.165;
            float rp = 0.065 * (iMouse.z > 0.0 ? 1.35 : 1.0) * (1.0 + 0.04 * sin(iTime * 3.0));
            vec2 q = uv - c;
            float r = length(q);
            float ang = atan(q.y, q.x);
            float fib = 0.5 + 0.5 * sin(ang * 36.0 + r * 60.0) * sin(ang * 13.0 - r * 20.0);
            vec3 irisIn = vec3(0.16, 0.45, 0.42);
            vec3 irisOut = vec3(0.08, 0.28, 0.5);
            vec3 iris = mix(irisIn, irisOut, smoothstep(0.03, ri, r));
            iris *= 0.75 + 0.45 * fib;
            iris = mix(iris, vec3(0.05, 0.12, 0.2), smoothstep(ri - 0.03, ri, r));
            col = mix(col, iris, smoothstep(px, -px, r - ri));
            col = mix(col, vec3(0.02), smoothstep(px * 2.0, -px, r - rp));
            // the light in the eye
            vec2 hl = uv - (c * 0.3 + vec2(-0.055, 0.07));
            col = mix(col, vec3(1.0), smoothstep(0.03, 0.02, length(hl)) * 0.9);
            col = mix(col, vec3(1.0), smoothstep(0.014, 0.008, length(uv - (c * 0.3 + vec2(0.05, -0.05)))) * 0.5);
            // the lid's shadow and edge
            col *= 1.0 - 0.35 * smoothstep(0.05, 0.0, -d) * step(0.0, uv.y);
            float edge = smoothstep(0.012, 0.0, abs(d)) * inside;
            col = mix(col, vec3(0.18, 0.08, 0.06), edge * 0.9);
            // lashes along the upper lid
            float lash = 0.0;
            if (uv.y > 0.0 && abs(uv.x) < w) {
                float along = fract(uv.x * 30.0);
                float above = uv.y - lidTop;
                lash = smoothstep(0.1, 0.0, abs(along - 0.5) - 0.08) * smoothstep(0.05 * (1.0 - abs(x) * 0.5), 0.0, above) * step(0.0, above);
                lash *= smoothstep(1.0, 0.7, abs(x));
            }
            col = mix(col, vec3(0.15, 0.07, 0.05), lash);
            float a = max(inside, lash);
            O = vec4(col * a, a);
        }
        """, inputs: [readInput("A", filter: "nearest")]),
    ])

    /// Ink in water. Buffer A carries a velocity field and the dye through
    /// itself frame to frame; a finger pushes and stains, and a thin thread
    /// rises from the bottom on its own. The ink takes the accent colour.
    public static let smoke = ShaderDocument(name: "Ink", passes: [
        ShaderPass(id: "A", kind: .buffer, code: """
        void mainImage(out vec4 O, in vec2 F) {
            vec2 R = iResolution.xy;
            vec2 uv = F / R;
            float dt = clamp(iTimeDelta, 0.004, 0.033);
            float mult = dt * 60.0;
            vec4 here = texture(iChannel3, uv);
            vec4 back = texture(iChannel3, uv - here.xy * dt);
            vec2 v = back.xy;
            float d = back.z;
            if (here.w < 0.5) { v = vec2(0.0); d = 0.0; }
            v.y += d * 0.3 * dt;
            v += 0.06 * dt * vec2(sin(uv.y * 9.0 + iTime * 0.8), cos(uv.x * 7.0 - iTime * 0.6));
            v *= 0.986;
            d *= 0.990;
            if (iMouse.z > 0.0) {
                vec2 q = uv - iMouse.xy / R;
                float g = exp(-dot(q, q) * 400.0);
                v += q / (length(q) + 1e-3) * g * 0.05 * mult;
                d += g * 1.0 * mult;
            }
            vec2 src = vec2(0.5 + 0.05 * sin(iTime * 0.9), 0.08);
            vec2 qs = uv - src;
            float g0 = exp(-dot(qs, qs) * 700.0);
            d += g0 * 0.9 * mult * (0.7 + 0.3 * sin(iTime * 3.0));
            v.y += g0 * 0.035 * mult;
            v.x += g0 * 0.02 * sin(iTime * 1.7) * mult;
            float edge = min(min(uv.x, 1.0 - uv.x), min(uv.y, 1.0 - uv.y));
            d *= smoothstep(0.0, 0.06, edge);
            O = vec4(v, min(d, 2.5), 1.0);
        }
        """, inputs: [stateInput("A", filter: "linear")]),
        ShaderPass(id: ShaderPass.imageId, kind: .image, code: """
        void mainImage(out vec4 O, in vec2 F) {
            vec2 uv = F / iResolution.xy;
            vec2 px = 1.0 / iResolution.xy;
            float d = texture(iChannel0, uv).z;
            float dx = texture(iChannel0, uv + vec2(px.x, 0.0)).z - texture(iChannel0, uv - vec2(px.x, 0.0)).z;
            float dy = texture(iChannel0, uv + vec2(0.0, px.y)).z - texture(iChannel0, uv - vec2(0.0, px.y)).z;
            vec3 ink = iAccent.rgb;
            vec3 deep = ink * 0.3;
            vec3 col = mix(deep, ink, clamp(d * 1.4, 0.0, 1.0));
            col = mix(col, vec3(1.0), smoothstep(0.9, 2.2, d) * 0.7);
            col += (dx * 3.0 - dy * 2.0) * 0.5 * vec3(1.0);
            float a = clamp(d * 2.2, 0.0, 1.0);
            O = vec4(clamp(col, 0.0, 1.0) * a, a);
        }
        """, inputs: [readInput("A")]),
    ])

    /// A clock that keeps the real time: `iDate` is the phone's clock, the
    /// face and the marks take the theme's colours, the second hand the accent.
    public static let clock = ShaderDocument(name: "Clock", passes: [
        ShaderPass(id: ShaderPass.imageId, kind: .image, code: """
        float sdSeg(vec2 p, vec2 a, vec2 b) {
            vec2 pa = p - a, ba = b - a;
            float h = clamp(dot(pa, ba) / dot(ba, ba), 0.0, 1.0);
            return length(pa - ba * h);
        }
        vec2 hand(float turns) { float a = turns * 6.2831853; return vec2(sin(a), cos(a)); }
        void mainImage(out vec4 O, in vec2 F) {
            vec2 uv = (F - 0.5 * iResolution.xy) / iResolution.y;
            float px = 1.5 / iResolution.y;
            float r = length(uv);
            float face = 0.44;
            float sec = iDate.w;
            vec2 hS = hand(mod(sec, 60.0) / 60.0);
            vec2 hM = hand(mod(sec / 60.0, 60.0) / 60.0);
            vec2 hH = hand(mod(sec / 3600.0, 12.0) / 12.0);
            vec3 faceCol = mix(vec3(0.97, 0.96, 0.93), vec3(0.13, 0.13, 0.15), iDark);
            vec3 markCol = iLabel.rgb;
            vec3 col = faceCol;
            // the marks
            float ang = atan(uv.x, uv.y);
            float a60 = abs(mod(ang + 0.05236, 0.10472) - 0.05236);
            float a12 = abs(mod(ang + 0.26180, 0.52360) - 0.26180);
            float minor = step(0.37, r) * step(r, 0.40) * smoothstep(0.004, 0.002, a60 * r);
            float major = step(0.345, r) * step(r, 0.40) * smoothstep(0.008, 0.005, a12 * r);
            col = mix(col, markCol, max(minor * 0.6, major));
            // the hands, each with a shadow a little below it
            vec2 sh = vec2(0.006, -0.008);
            float dh = sdSeg(uv, -hH * 0.05, hH * 0.22) - 0.018;
            float dm = sdSeg(uv, -hM * 0.06, hM * 0.33) - 0.012;
            float ds = sdSeg(uv, -hS * 0.09, hS * 0.36) - 0.004;
            float shadow = smoothstep(0.02, 0.0, min(min(sdSeg(uv - sh, -hH * 0.05, hH * 0.22) - 0.018,
                                                        sdSeg(uv - sh, -hM * 0.06, hM * 0.33) - 0.012),
                                                        sdSeg(uv - sh, -hS * 0.09, hS * 0.36) - 0.004));
            col = mix(col, col * 0.6, shadow * 0.5);
            col = mix(col, markCol, smoothstep(px, -px, dh));
            col = mix(col, markCol, smoothstep(px, -px, dm));
            col = mix(col, iAccent.rgb, smoothstep(px, -px, ds));
            col = mix(col, iAccent.rgb, smoothstep(px, -px, r - 0.018));
            col = mix(col, faceCol, smoothstep(px, -px, r - 0.007));
            // the bezel: brushed metal in a ring
            float bez = smoothstep(px, -px, r - face) * smoothstep(-px, px, r - face + 0.035);
            float brush = 0.75 + 0.25 * sin(ang * 90.0) * 0.3 + 0.2 * cos(ang * 2.0 + 1.0);
            vec3 metal = mix(vec3(0.55, 0.55, 0.58), vec3(0.95), brush);
            col = mix(col, metal, bez);
            float a = smoothstep(px, -px, r - face);
            vec2 g = (uv - vec2(0.0, -0.46)) * vec2(1.0, 3.5);
            float drop = smoothstep(0.44, 0.12, length(g)) * 0.3;
            a = max(a, drop);
            O = vec4(col * smoothstep(px, -px, r - face), a);
        }
        """, inputs: []),
    ])

    // MARK: - Background

    /// A night with an aurora over mountains. The sky leans with the phone
    /// (`iGravity`), the ribbons drift, the stars blink, and in the light theme
    /// it is a pale dawn with the same ribbons faint on it.
    public static let aurora = ShaderDocument(name: "Aurora", passes: [
        ShaderPass(id: ShaderPass.imageId, kind: .image, code: """
        float hash2(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
        float noise(vec2 p) {
            vec2 i = floor(p), f = fract(p);
            f = f * f * (3.0 - 2.0 * f);
            return mix(mix(hash2(i), hash2(i + vec2(1.0, 0.0)), f.x),
                       mix(hash2(i + vec2(0.0, 1.0)), hash2(i + vec2(1.0, 1.0)), f.x), f.y);
        }
        float fbm(vec2 p) {
            float v = 0.0, a = 0.5;
            for (int i = 0; i < 4; i++) { v += a * noise(p); p = p * 2.03 + vec2(1.7, 9.2); a *= 0.5; }
            return v;
        }
        void mainImage(out vec4 O, in vec2 F) {
            vec2 uv = F / iResolution.xy;
            float aspect = iResolution.x / iResolution.y;
            // the phone's tilt shifts the sky; on a table it is at rest
            float tilt = clamp(iGravity.x, -1.0, 1.0) * 0.12;
            float night = iDark;
            vec3 top = mix(vec3(0.62, 0.72, 0.86), vec3(0.01, 0.02, 0.07), night);
            vec3 bottom = mix(vec3(0.93, 0.80, 0.72), vec3(0.05, 0.08, 0.18), night);
            vec3 col = mix(bottom, top, smoothstep(0.1, 0.9, uv.y));
            // stars, twinkling; hidden in the day
            vec2 sp = vec2((uv.x + tilt * 0.5) * aspect, uv.y) * 90.0;
            vec2 si = floor(sp);
            vec2 sf = fract(sp) - 0.5;
            float sh = hash2(si);
            float star = smoothstep(0.08, 0.0, length(sf + (vec2(hash2(si + 1.3), hash2(si + 7.1)) - 0.5) * 0.6))
                       * step(0.93, sh) * (0.6 + 0.4 * sin(iTime * (1.0 + sh * 3.0) + sh * 40.0));
            col += vec3(1.0) * star * night * smoothstep(0.25, 0.5, uv.y);
            // three ribbons of aurora
            vec3 glow = vec3(0.0);
            for (int i = 0; i < 3; i++) {
                float fi = float(i);
                float x = (uv.x + tilt) * aspect * 1.4 + fi * 3.1;
                float yc = 0.56 + 0.11 * fi + 0.07 * sin(x * 1.3 + iTime * 0.25 + fi) + 0.08 * (fbm(vec2(x * 0.8, iTime * 0.05 + fi)) - 0.5);
                float width = 0.035 + 0.02 * fi;
                float band = exp(-(uv.y - yc) * (uv.y - yc) / (width * width));
                float curtain = fbm(vec2(x * 2.5 + iTime * 0.12, uv.y * 3.0 - iTime * 0.05 + fi * 4.0));
                curtain = smoothstep(0.35, 0.8, curtain);
                float rays = 0.6 + 0.4 * sin(x * 22.0 + fi * 2.0 + iTime * 0.4 + curtain * 6.0);
                vec3 tint = mix(vec3(0.1, 0.9, 0.5), vec3(0.6, 0.2, 0.9), smoothstep(0.5, 0.85, uv.y + 0.1 * fi));
                glow += tint * band * curtain * rays * (1.0 - 0.25 * fi);
                // the ribbon's light spills upward
                glow += tint * 0.12 * smoothstep(yc - 0.02, yc + 0.25, uv.y) * (1.0 - smoothstep(yc + 0.25, yc + 0.5, uv.y)) * curtain * 0.6;
            }
            col += glow * mix(0.25, 1.0, night);
            // mountains along the bottom, with a mist above them
            float mx = (uv.x + tilt * 1.5) * aspect;
            float ridge = 0.14 + 0.07 * fbm(vec2(mx * 2.2, 3.0)) + 0.03 * fbm(vec2(mx * 7.0, 8.0));
            float ridge2 = 0.09 + 0.05 * fbm(vec2(mx * 1.6 + 5.0, 1.0));
            vec3 far = mix(vec3(0.55, 0.58, 0.72), vec3(0.06, 0.08, 0.16), night);
            vec3 near = mix(vec3(0.35, 0.38, 0.5), vec3(0.02, 0.03, 0.07), night);
            col = mix(col, far, smoothstep(ridge + 0.004, ridge - 0.004, uv.y));
            col = mix(col, near, smoothstep(ridge2 + 0.004, ridge2 - 0.004, uv.y));
            col += glow * 0.08 * smoothstep(ridge, ridge + 0.15, uv.y) * (1.0 - smoothstep(ridge + 0.15, ridge + 0.3, uv.y)) * night;
            O = vec4(col, 1.0);
        }
        """, inputs: []),
    ])

    // MARK: - Bubble shaders

    /// Holographic foil behind the text. The bands shift with where the
    /// bubble sits on the screen, so scrolling the feed tilts the card, and
    /// with the phone's tilt on top of that.
    public static let foil = ShaderDocument(name: "Foil", passes: [
        ShaderPass(id: ShaderPass.imageId, kind: .image, code: """
        float hash2(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
        void mainImage(out vec4 O, in vec2 F) {
            vec2 uv = F / iResolution.xy;
            float aspect = iResolution.x / iResolution.y;
            float place = iBubble.y / max(iScreen.y, 1.0);
            float lean = clamp(iGravity.x, -1.0, 1.0) * 0.4 + clamp(iGravity.y, -1.0, 1.0) * 0.2;
            float h = uv.x * 0.5 * aspect + uv.y * 0.3 + place * 1.6 + lean + iTime * 0.04;
            vec3 col = 0.5 + 0.5 * cos(6.2831 * (h + vec3(0.0, 0.33, 0.67)));
            // the sheen that sweeps across a tilted card
            float sweep = (uv.x * aspect - uv.y) * 2.5 + place * 14.0 + lean * 6.0 + iTime * 0.3;
            float sheen = pow(0.5 + 0.5 * sin(sweep), 10.0);
            col += vec3(1.0) * sheen * 0.45;
            // the fine grain of the foil
            float grain = hash2(floor(F / 2.0)) * 0.08;
            col = col * 0.55 + 0.04 + grain;
            // darker toward the edges so the text stays readable everywhere
            float vig = smoothstep(0.0, 0.35, uv.x) * smoothstep(1.0, 0.65, uv.x);
            col *= 0.78 + 0.22 * vig;
            O = vec4(col, 1.0);
        }
        """, inputs: []),
    ])

    /// Embers behind the text: slow fire rising through noise, sparks
    /// climbing off it, dark enough for white text.
    public static let ember = ShaderDocument(name: "Ember", passes: [
        ShaderPass(id: ShaderPass.imageId, kind: .image, code: """
        float hash2(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
        float noise(vec2 p) {
            vec2 i = floor(p), f = fract(p);
            f = f * f * (3.0 - 2.0 * f);
            return mix(mix(hash2(i), hash2(i + vec2(1.0, 0.0)), f.x),
                       mix(hash2(i + vec2(0.0, 1.0)), hash2(i + vec2(1.0, 1.0)), f.x), f.y);
        }
        float fbm(vec2 p) {
            float v = 0.0, a = 0.5;
            for (int i = 0; i < 4; i++) { v += a * noise(p); p = p * 2.1 + vec2(3.1, 1.7); a *= 0.5; }
            return v;
        }
        void mainImage(out vec4 O, in vec2 F) {
            vec2 uv = F / iResolution.xy;
            float aspect = iResolution.x / iResolution.y;
            vec2 p = vec2(uv.x * aspect * 1.6, uv.y * 1.6 - iTime * 0.35);
            float f = fbm(p + 0.4 * fbm(p * 1.7 + iTime * 0.1));
            f *= 1.25 - uv.y * 0.7;
            vec3 col = mix(vec3(0.10, 0.02, 0.01), vec3(0.75, 0.22, 0.04), smoothstep(0.3, 0.75, f));
            col += vec3(1.0, 0.7, 0.25) * smoothstep(0.7, 0.92, f) * 0.6;
            // sparks
            vec2 sp = vec2(uv.x * aspect * 14.0, uv.y * 14.0 - iTime * 1.2);
            vec2 si = floor(sp);
            vec2 sf = fract(sp) - 0.5;
            float sh = hash2(si);
            sf.x += 0.2 * sin(iTime * 2.0 + sh * 30.0);
            float spark = smoothstep(0.12, 0.0, length(sf)) * step(0.88, sh) * (0.5 + 0.5 * sin(iTime * 6.0 + sh * 50.0));
            col += vec3(1.0, 0.75, 0.4) * spark;
            O = vec4(col * 0.85, 1.0);
        }
        """, inputs: []),
    ])

    // MARK: - Avatars

    /// A nebula in the avatar's disc, and what the circle cannot hold: a soft
    /// halo breathing past the edge and a comet on an orbit around it. The
    /// canvas an avatar gets is twice the circle, so the disc's radius in uv
    /// is 0.25 and everything outside it is drawn over the interface.
    public static let nebula = ShaderDocument(name: "Nebula", passes: [
        ShaderPass(id: ShaderPass.imageId, kind: .image, code: """
        float hash2(vec2 p) { return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453); }
        float noise(vec2 p) {
            vec2 i = floor(p), f = fract(p);
            f = f * f * (3.0 - 2.0 * f);
            return mix(mix(hash2(i), hash2(i + vec2(1.0, 0.0)), f.x),
                       mix(hash2(i + vec2(0.0, 1.0)), hash2(i + vec2(1.0, 1.0)), f.x), f.y);
        }
        float fbm(vec2 p) {
            float v = 0.0, a = 0.5;
            for (int i = 0; i < 5; i++) { v += a * noise(p); p = p * 2.02 + vec2(1.3, 7.7); a *= 0.5; }
            return v;
        }
        mat2 rot(float a) { float c = cos(a), s = sin(a); return mat2(c, -s, s, c); }
        void mainImage(out vec4 O, in vec2 F) {
            vec2 uv = (F - 0.5 * iResolution.xy) / iResolution.y;
            float px = 1.5 / iResolution.y;
            float r = length(uv);
            float RD = 0.25;
            vec3 col = vec3(0.0);
            float a = 0.0;
            // the cloud inside the disc
            float disc = smoothstep(px, -px, r - RD);
            if (disc > 0.0) {
                vec2 q = rot(iTime * 0.05 + r * 4.0) * uv * 5.6;
                q += 0.6 * vec2(fbm(q + iTime * 0.08), fbm(q + vec2(3.3, 1.1) - iTime * 0.06));
                float f = fbm(q * 1.4);
                float g = fbm(q * 3.0 + 5.0);
                vec3 neb = vec3(0.03, 0.02, 0.08);
                neb = mix(neb, vec3(0.25, 0.05, 0.45), smoothstep(0.25, 0.6, f));
                neb = mix(neb, vec3(0.85, 0.2, 0.55), smoothstep(0.5, 0.75, f) * g);
                neb = mix(neb, vec3(1.0, 0.65, 0.35), smoothstep(0.68, 0.9, f + g * 0.3) * 0.8);
                neb += vec3(1.0, 0.85, 0.7) * 0.5 * exp(-r * r * 90.0);
                neb *= 0.75 + 0.25 * smoothstep(RD, RD * 0.5, r);
                col += neb * disc;
                a = disc;
            }
            // the halo breathing past the edge
            float breath = 0.6 + 0.4 * sin(iTime * 0.9);
            float halo = exp(-(r - RD) * 16.0) * step(RD, r) * breath;
            col += vec3(0.7, 0.35, 0.9) * halo * 0.55;
            a = clamp(a + halo * 0.55, 0.0, 1.0);
            // the comet around it, with a tail; behind the disc it hides
            float ph = iTime * 0.9;
            bool front = sin(ph) < 0.0;
            for (int k = 0; k < 10; k++) {
                float pk = ph - float(k) * 0.05;
                vec2 c = vec2(cos(pk) * 0.38, sin(pk) * 0.20);
                float d = length(uv - c);
                float w = 1.0 - float(k) / 10.0;
                float g = (k == 0 ? 0.006 : 0.003 * w) / (d + 1e-3);
                g = g * g;
                if (!front) g *= smoothstep(-px, px, r - RD);
                col += mix(vec3(1.0, 0.9, 0.8), vec3(0.7, 0.4, 1.0), float(k) / 10.0) * g;
                a = clamp(a + g, 0.0, 1.0);
            }
            O = vec4(min(col, vec3(1.2)), a);
        }
        """, inputs: []),
    ])

    /// A planet filling the avatar's circle, with moons whose orbits are
    /// wider than the circle: they leave it, cross the interface and come
    /// back, passing behind the planet on the far side. The canvas an avatar
    /// gets is twice the circle, so the planet's radius in uv is 0.25.
    public static let orbit = ShaderDocument(name: "Orbit", passes: [
        ShaderPass(id: ShaderPass.imageId, kind: .image, code: """
        float hash(float n) { return fract(sin(n) * 43758.5453); }
        void mainImage(out vec4 O, in vec2 F) {
            vec2 uv = (F - 0.5 * iResolution.xy) / iResolution.y;
            float px = 1.5 / iResolution.y;
            float RD = 0.25;
            vec3 L = normalize(vec3(-0.6, 0.7, 0.5));
            vec3 col = vec3(0.0);
            float a = 0.0;
            // moons behind the planet first, then the planet, then the front ones
            for (int layer = 0; layer < 2; layer++) {
                if (layer == 1) {
                    float d = length(uv) - RD;
                    if (d < px) {
                        float z = sqrt(max(0.0, RD * RD - dot(uv, uv)));
                        vec3 n = normalize(vec3(uv, z));
                        float dif = max(dot(n, L), 0.0);
                        float band = 0.5 + 0.5 * sin(uv.y * 32.0 + sin(uv.x * 10.0 + iTime * 0.3) * 1.5 + iTime * 0.2);
                        vec3 surf = mix(vec3(0.85, 0.55, 0.25), vec3(0.95, 0.8, 0.55), band);
                        surf = mix(surf, vec3(0.3, 0.45, 0.7), smoothstep(0.6, 0.9, abs(uv.y) / RD));
                        vec3 pc = surf * (0.12 + 0.88 * dif) + vec3(0.9, 0.7, 0.5) * pow(1.0 - n.z, 3.0) * 0.4;
                        float m = smoothstep(px, -px, d);
                        col = mix(col, pc, m);
                        a = max(a, m);
                    }
                }
                for (int i = 0; i < 6; i++) {
                    float fi = float(i);
                    float ring = fi < 3.0 ? 0.34 : 0.44;
                    float speed = fi < 3.0 ? 0.9 : -0.55;
                    float ph = iTime * speed + fi * 2.1;
                    vec2 c = vec2(cos(ph) * ring, sin(ph) * ring * 0.42);
                    bool front = sin(ph) < 0.0;
                    if ((layer == 1) != front) continue;
                    float mr = 0.02 + 0.012 * hash(fi * 3.3);
                    vec2 q = uv - c;
                    float md = length(q) - mr;
                    float z = sqrt(max(0.0, mr * mr - dot(q, q)));
                    vec3 n = normalize(vec3(q, z));
                    vec3 mc = mix(vec3(0.65, 0.7, 0.8), vec3(0.9, 0.5, 0.5), hash(fi * 7.7)) * (0.2 + 0.8 * max(dot(n, L), 0.0));
                    float m = smoothstep(px, -px, md);
                    // a moon behind the planet is hidden by its disc alone
                    if (!front) m *= smoothstep(-px, px, length(uv) - RD);
                    col = mix(col, mc, m);
                    a = max(a, m);
                }
            }
            O = vec4(col, a);
        }
        """, inputs: []),
    ])
}
