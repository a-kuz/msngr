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
            // sand at the rim, deep teal toward the middle; the dark theme
            // dims the sand so the pond stays water, not a moon
            float sand = noise(q * 24.0) * 0.55 + noise(q * 52.0 + 3.7) * 0.45;
            vec3 bottom = vec3(0.78, 0.68, 0.50) * (0.8 + 0.3 * sand) * mix(1.0, 0.55, iDark);
            float depth = smoothstep(1.02, 0.3, rr);
            vec3 water = mix(vec3(0.05, 0.33, 0.45), vec3(0.02, 0.17, 0.28), iDark);
            vec3 col = mix(bottom, water, 0.25 + 0.65 * depth);
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

    /// A human eye, procedural and photoreal: orthographic rays against the
    /// eyeball and the corneal sphere, refracted through the cornea onto the
    /// iris plane, with vessels in the sclera, bump-mapped skin, two rows of
    /// lashes and their shadows. It looks around on its own, blinks, and grows
    /// heavy-lidded now and then; a finger it follows while the touch lasts.
    /// One pass, no state: `ALPHA_OUT` gives it the transparent surround a
    /// sticker needs, so the skin patch fades out well inside the square.
    public static let eye = ShaderDocument(name: "Eye", passes: [
        ShaderPass(id: ShaderPass.imageId, kind: .image, code: """
        #define ALPHA_OUT 1
        precision highp float;
        // Photorealistic human eye, fully procedural, single pass.
        // Orthographic rays vs eyeball sphere + corneal sphere; real refraction through
        // the cornea onto the iris plane; procedural iris (fibers, crypts, furrows,
        // collarette, limbus), sclera with vessels, eyelids with bump-mapped skin,
        // lashes, blink and saccades; softbox environment light; ACES tone mapping.

        // ------------------------------------------------------------- geometry
        const float PI      = 3.14159265;
        const vec3  COR_C   = vec3(0.0, 0.0, 0.44); // corneal sphere center (eye space)
        const float COR_R   = 0.65;                 // corneal sphere radius
        const float IRIS_Z  = 0.83;                 // iris plane depth
        const float IRIS_R  = 0.52;                 // iris disc radius on its plane
        const float IOR     = 1.376;                // cornea refractive index
        // how much of the frame the eye spans: wide enough that the skin patch has
        // faded to nothing before the shorter edge, so a square canvas cuts nothing
        const float VIEW    = 3.0;

        // key light (window) direction, view space
        const vec3 KEY = normalize(vec3(-0.42, 0.48, 0.76));

        // ------------------------------------------------- tunable parameters
        // The test harness defines TUNE and drives these as uniform sliders;
        // standalone (Shadertoy) they compile as constants with the same values.
        #ifdef TUNE
        #define P(n, v) uniform float n;
        #else
        #define P(n, v) const float n = v;
        #endif
        P(pBlinkT,      3.998) // seconds between blinks
        P(pSaccT,       3.14)  // seconds between saccades
        P(pDrowsyAmp,   0.22)  // tired half-closure amount
        P(pWhip,        2.74)  // lash lag behind lid motion
        P(pWhipVar,     0.125) // per-strand lag spread
        P(pBreeze,      0.0)   // shared air sway
        P(pIdle,        1.035) // per-strand idle sway
        P(pLashRot,     4.0)   // lash fan rotation over a blink
        P(pLashLen,     1.264) // upper lash length
        P(pLashLenLo,   0.613) // lower lash length
        P(pCurlUp,      1.73)  // upper lash curl
        P(pCurlLo,      0.2)   // lower lash curl
        P(pHook,        0.55)  // J-root dip below the margin
        P(pStray,       6.0)   // stray lash probability
        P(pLashDark,    2.0)   // lash opacity
        P(pLashGlint,   0.42)  // specular glints on lashes
        P(pSolo,        0.0)   // debug: draw a single lash
        P(pPupil,       0.126) // pupil radius
        P(pIrisBright,  0.2)   // iris brightness
        P(pIrisSat,     2.0)   // iris saturation
        P(pLimbus,      1.0)   // limbal ring darkness
        P(pFiberRelief, 0.24)  // iris fiber shading
        P(pVein,        2.5)   // sclera vessels
        P(pScleraWarm,  2.0)   // sclera warm corners
        P(pTension,     3.0)   // conjunctiva tension on turns
        P(pAnchor,      0.0)   // conjunctiva lag behind the globe
        P(pSkinRed,     0.0)   // capillary blotches
        P(pPores,       2.28)  // pore / micro wrinkle depth
        P(pOily,        2.25)  // skin sheen
        P(pSSS,         0.075) // subsurface red at terminator
        P(pKey,         0.2)   // key light strength
        P(pWin,         33.175)// window brightness
        P(pGrain,       0.0)   // film grain
        P(pRim,         0.695) // skin patch radius
        P(pBG,          0.385) // backdrop brightness (Shadertoy fill; unused with ALPHA_OUT)

        // ------------------------------------------------------------- utils
        mat3 rotX(float a){ float c=cos(a),s=sin(a); return mat3(1,0,0, 0,c,s, 0,-s,c); }
        mat3 rotY(float a){ float c=cos(a),s=sin(a); return mat3(c,0,-s, 0,1,0, s,0,c); }

        float hash11(float p){ p = fract(p*0.1031); p *= p+33.33; return fract(p*(p+p)); }
        vec2  hash21(float p){ vec3 p3 = fract(vec3(p)*vec3(0.1031,0.1030,0.0973)); p3 += dot(p3,p3.yzx+33.33); return fract((p3.xx+p3.yz)*p3.zy); }
        float hash12(vec2 p){ vec3 p3 = fract(vec3(p.xyx)*0.1031); p3 += dot(p3,p3.yzx+33.33); return fract((p3.x+p3.y)*p3.z); }
        vec2  hash22(vec2 p){ vec3 p3 = fract(vec3(p.xyx)*vec3(0.1031,0.1030,0.0973)); p3 += dot(p3,p3.yzx+33.33); return fract((p3.xx+p3.yz)*p3.zy); }
        float hash13(vec3 p){ p = fract(p*0.1031); p += dot(p,p.zyx+31.32); return fract((p.x+p.y)*p.z); }

        float noise2(vec2 p){
            vec2 i = floor(p), f = fract(p);
            vec2 u = f*f*(3.0-2.0*f);
            return mix(mix(hash12(i),           hash12(i+vec2(1,0)), u.x),
                       mix(hash12(i+vec2(0,1)), hash12(i+vec2(1,1)), u.x), u.y);
        }
        float fbm(vec2 p){
            float s = 0.0, a = 0.5;
            for(int i=0;i<4;i++){ s += a*noise2(p); p = p*2.03 + vec2(31.7,-17.3); a *= 0.5; }
            return s;
        }
        float noise3(vec3 p){
            vec3 i = floor(p), f = fract(p);
            vec3 u = f*f*(3.0-2.0*f);
            return mix(mix(mix(hash13(i),             hash13(i+vec3(1,0,0)), u.x),
                           mix(hash13(i+vec3(0,1,0)), hash13(i+vec3(1,1,0)), u.x), u.y),
                       mix(mix(hash13(i+vec3(0,0,1)), hash13(i+vec3(1,0,1)), u.x),
                           mix(hash13(i+vec3(0,1,1)), hash13(i+vec3(1,1,1)), u.x), u.y), u.z);
        }
        float fbm3(vec3 p){
            float s = 0.0, a = 0.5;
            for(int i=0;i<4;i++){ s += a*noise3(p); p = p*2.07 + vec3(13.1,-7.7,5.3); a *= 0.5; }
            return s;
        }
        // voronoi: returns (F1, F2-F1)
        vec2 vor(vec2 p){
            vec2 i = floor(p), f = fract(p);
            float d1 = 8.0, d2 = 8.0;
            for(int y=-1;y<=1;y++) for(int x=-1;x<=1;x++){
                vec2 g = vec2(x,y);
                vec2 r = g + hash22(i+g) - f;
                float d = dot(r,r);
                if(d<d1){ d2=d1; d1=d; } else if(d<d2){ d2=d; }
            }
            d1 = sqrt(d1); d2 = sqrt(d2);
            return vec2(d1, d2-d1);
        }

        // ------------------------------------------------------------- environment
        // Softbox window + ambient dome + warm fill. Used for all speculars.
        vec3 envLight(vec3 rd){
            vec3 e = mix(vec3(0.050,0.043,0.040), vec3(0.085,0.095,0.115), rd.y*0.5+0.5);
            float dw = dot(rd, KEY);
            if(dw > 0.0){
                vec3 U = normalize(cross(vec3(0,1,0), KEY));
                vec3 V = cross(KEY, U);
                vec2 pr = vec2(dot(rd,U), dot(rd,V)) / dw;
                float bx = smoothstep(0.20, 0.165, abs(pr.x));
                float by = smoothstep(0.26, 0.21, abs(pr.y));
                float win = bx*by;
                // window frame bars
                win *= 0.22 + 0.78*smoothstep(0.008, 0.026, abs(pr.x));
                win *= 0.22 + 0.78*smoothstep(0.008, 0.026, abs(pr.y+0.04));
                e += vec3(1.25,1.20,1.12) * win * pWin;
            }
            vec3 F2 = normalize(vec3(0.62,-0.22,0.76));
            e += vec3(0.85,0.50,0.34) * pow(max(dot(rd,F2),0.0), 110.0) * 1.3;
            return e;
        }
        float fresnel(float c){ return 0.025 + 0.975*pow(clamp(1.0-c,0.0,1.0), 5.0); }

        // diffuse: wrapped key + hemispheric ambient
        vec3 shadeDiffuse(vec3 n, vec3 alb, float ao){
            float ndl = dot(n, KEY);
            float wrap = clamp((ndl+0.45)/1.45, 0.0, 1.0);
            vec3 key = vec3(1.30,1.18,1.05) * pow(wrap, 1.4) * 1.35 * pKey;
            vec3 amb = mix(vec3(0.30,0.22,0.19), vec3(0.36,0.38,0.44), n.y*0.5+0.5) * 0.75;
            return alb * (key + amb) * ao;
        }

        // ------------------------------------------------------------- gaze / blink
        vec2 gazeAngles(float t, vec4 iM, vec3 R){
            vec2 g;
            // it watches the pointer while the button is down; let go and it goes
            // back to looking around on its own
            if(iM.z > 0.0){
                vec2 m = (iM.xy - 0.5*R.xy) / R.y;
                g = clamp(m, vec2(-0.6), vec2(0.6)) * vec2(0.95, 0.72);
            } else {
                // saccades: hold + fast jump, plus drift and tremor
                float T = pSaccT;
                float id = floor(t/T), ft = fract(t/T);
                float dur = 0.55 + 0.6*hash11(id*3.7);           // some fixations longer
                vec2 g0 = (hash21(id)     - 0.5) * vec2(0.62, 0.34);
                vec2 g1 = (hash21(id+1.0) - 0.5) * vec2(0.62, 0.34);
                float k = smoothstep(0.0, 0.09*dur+0.05, ft);
                g = mix(g0, g1, k);
                g += 0.012*vec2(fbm(vec2(t*1.3, 4.7)), fbm(vec2(t*1.1, 9.3))) - 0.006;
            }
            return g;
        }
        float blinkAmt(float t){
            float T = pBlinkT;
            float id = floor(t/T), ft = t - id*T;
            float off = 0.4 + 2.2*hash11(id*7.1);
            float x = ft - off;
            float b = smoothstep(0.00,0.09,x)*smoothstep(0.26,0.12,x);
            // occasional quick double blink
            if(hash11(id*13.3) > 0.72){
                float x2 = x - 0.34;
                b = max(b, smoothstep(0.00,0.08,x2)*smoothstep(0.22,0.10,x2));
            }
            return clamp(b*1.15, 0.0, 1.0);
        }

        // occasional tired half-closure: lids grow heavy, droop for a few
        // seconds with a slight tremble, then slowly lift again
        float drowsy(float t){
            float T = 19.0;
            float id = floor(t/T), ft = t - id*T;
            float has = step(0.45, hash11(id*9.7+3.1));
            float start = 3.0 + 8.0*hash11(id*5.3+1.7);
            float dur   = 2.5 + 3.0*hash11(id*7.9+8.2);
            float amp   = 0.35 + 0.25*hash11(id*3.3+5.5);
            float x = ft - start;
            float env = smoothstep(0.0, 1.8, x) * (1.0 - smoothstep(dur, dur+1.6, x));
            env *= 1.0 + 0.06*sin(t*7.0);
            return clamp(amp*env*has*pDrowsyAmp, 0.0, 0.85);
        }

        // ------------------------------------------------------------- eyelids
        // returns (yUpper, yLower) of the palpebral fissure at x
        vec2 lids(float x, float b, vec2 g){
            float xL = -1.10, xR = 1.06;
            float yL = -0.05 + g.y*0.22, yR = 0.09 + g.y*0.22;
            float s = clamp((x-xL)/(xR-xL), 0.0, 1.0);
            float base = mix(yL, yR, s);
            float squint = 0.10*(fbm(vec2(iTime*0.33, 2.7)) - 0.35); // slow lid tension
            float hu = 0.53*(1.0 + 0.55*g.y - squint);
            float hl = 0.35*(1.0 - 0.28*g.y - 0.6*squint);
            float pu = pow(max(sin(PI*pow(s,0.78)),0.0), 1.05);  // apex nasal of center
            float pl = pow(max(sin(PI*pow(s,1.18)),0.0), 1.00);  // apex temporal
            float yu = base + hu*pu;
            float yl = base - hl*pl;
            // the cornea pushes the lower lid around where the eye points,
            // and a slow micro-ripple keeps the margin alive; corners stay pinned
            float push = exp(-(x - g.x*1.35)*(x - g.x*1.35)*4.5);
            yu += 0.030*push*pu;                              // cornea tents the upper lid
            yl -= 0.020*push*clamp(-g.y*2.0 + 0.15, 0.0, 1.0)*pl;
            yl += 0.005*(noise2(vec2(x*2.0 + 3.0, iTime*0.8)) - 0.5)*pl;
            // blink: upper lid sweeps down and seals against the lower lid
            float closeLine = base - 0.30*hl*pl;
            yu = mix(yu, closeLine, b);
            yl = mix(yl, closeLine - 0.006*pl, 0.55*smoothstep(0.4,1.0,b));
            return vec2(yu, yl);
        }

        // ------------------------------------------------------------- skin
        // lid-adjacent effects die out past the eye corners
        float lidFade(float x){ return smoothstep(-1.16,-1.06,x)*smoothstep(1.16,1.04,x); }

        float skinHeight(vec2 p, float b, vec2 g){
            vec2 L = lids(p.x, b, g);
            float du = p.y - L.x;          // signed: >0 above the upper lid
            float dl = L.y - p.y;          // signed: >0 below the lower lid
            float f = lidFade(p.x);
            float h = 0.0;
            h += 0.080*exp(-du*du*70.0)*step(0.0, du)*f;         // upper lid roll
            // supratarsal crease: unfolds when the lid drops, deepens on upgaze
            float crD = 0.20 + 0.06*g.y + 0.10*b;
            float crA = 1.0 - 0.65*b + 0.35*max(g.y, 0.0);
            h -= 0.038*crA*exp(-(du-crD)*(du-crD)*120.0)*f;
            h += 0.030*smoothstep(0.30,0.85,du)*smoothstep(1.5,0.5,abs(p.x-0.10)); // brow rise
            h += 0.045*exp(-dl*dl*230.0)*step(0.0, dl)*f;        // lower lid roll
            h -= 0.018*exp(-(dl-0.17)*(dl-0.17)*80.0)*smoothstep(1.1,0.3,abs(p.x)); // tear trough
            // crow's feet: faint radial wrinkles past the outer corner
            vec2 oc = p - vec2(1.48, 0.02);
            float cf = smoothstep(0.55,0.28,length(oc)) * smoothstep(0.14,0.30,length(oc))
                     * smoothstep(1.16,1.34,p.x);
            h += 0.0022*sin(atan(oc.y,oc.x)*20.0 + noise2(p*6.0)*3.5)*cf;
            h += 0.007*fbm(p*12.0);
            h += 0.0022*fbm(p*48.0);
            // micro wrinkle network: patchy and strongly warped so it never
            // reads as a uniform cell mesh
            float w = fbm(p*7.0);
            float ptch = smoothstep(0.35, 0.75, fbm(p*3.1 + vec2(4.4,8.8)));
            float mw = vor(p*30.0 + vec2(w, 0.7-w)*1.5).y;
            h -= 0.0016*pPores*smoothstep(0.12, 0.0, mw)*ptch*(0.4 + 0.9*noise2(p*2.9+6.6));
            // pores: sparse dimples between the wrinkles
            float pv = vor(p*46.0 + vec2(w*2.0, 9.1)).x;
            h -= 0.0012*pPores*smoothstep(0.30, 0.06, pv)*(0.35 + 0.65*noise2(p*5.0+2.2));
            return h;
        }
        vec3 skinNormal(vec2 p, float b, vec2 g){
            float e = 0.008;
            float h0 = skinHeight(p, b, g);
            float hx = skinHeight(p+vec2(e,0), b, g) - h0;
            float hy = skinHeight(p+vec2(0,e), b, g) - h0;
            return normalize(vec3(-hx/e*0.9, -hy/e*0.9, 1.0));
        }
        vec3 skinColor(vec2 p, float b, vec2 g){
            vec2 L = lids(p.x, b, g);
            float du = p.y - L.x;          // signed
            float dl = L.y - p.y;          // signed
            float f = lidFade(p.x);
            // albedo: layered, low-frequency unevenness first
            vec3 alb = vec3(0.62, 0.42, 0.34);
            mat2 r30 = mat2(0.866,-0.5,0.5,0.866);
            alb = mix(alb, vec3(0.68,0.46,0.36), fbm(r30*p*1.7+vec2(8.2,1.1))*0.55);
            alb = mix(alb, vec3(0.56,0.36,0.29), fbm(r30*p*3.4+vec2(1.3,7.7))*0.35);
            alb = mix(alb, vec3(0.60,0.29,0.24),                     // pink lid margins
                      (0.42*exp(-du*du*420.0) + 0.45*exp(-dl*dl*260.0))*f);
            alb = mix(alb, vec3(0.46,0.30,0.27),                     // under-eye shade
                      0.40*exp(-(dl-0.15)*(dl-0.15)*55.0)*smoothstep(1.2,0.3,abs(p.x)));
            alb = mix(alb, vec3(0.55,0.37,0.30),                     // upper lid warmth
                      0.35*exp(-(du-0.10)*(du-0.10)*80.0)*f);
            alb *= 0.93 + 0.12*fbm(p*8.0+vec2(3.7,9.1));             // mottling
            alb = mix(alb, alb*vec3(1.07,0.84,0.80),                 // capillary blotches
                      smoothstep(0.55,0.80,fbm(r30*p*2.6+vec2(17.3,5.1)))*min(0.60*pSkinRed, 1.0));
            alb *= 0.975 + 0.045*noise2(p*46.0+1.8);                 // pores tint
            vec3 n = skinNormal(p, b, g);
            // AO in crease and near lash lines
            float ao = 1.0;
            float crD = 0.20 + 0.06*g.y + 0.10*b;
            float crA = 1.0 - 0.65*b + 0.35*max(g.y, 0.0);
            ao -= 0.26*crA*exp(-(du-crD)*(du-crD)*120.0)*f;
            ao -= 0.22*exp(-du*du*900.0)*f;
            ao -= 0.20*exp(-dl*dl*600.0)*f;
            vec3 col = shadeDiffuse(n, alb, max(ao,0.0));
            // subsurface red at the shadow terminator
            float ndl = dot(n, KEY);
            col += alb * vec3(0.55,0.10,0.06) * exp(-ndl*ndl*9.0) * pSSS;
            // oily sheen, stronger on the lid roll and brow; pores and micro
            // relief break the highlight so it never reads as one smooth sheet
            vec3 hv = normalize(KEY + vec3(0,0,1));
            float mic = noise2(p*52.0)*(0.55 + 0.45*noise2(p*13.0+3.3));
            float spec = pow(max(dot(n,hv),0.0), 22.0 + 30.0*mic) * (0.45 + 1.10*mic);
            float oily = 0.045 + (0.13*exp(-du*du*90.0)
                       + 0.07*smoothstep(0.35,0.8,du)*smoothstep(1.5,0.9,du))*f;
            col += vec3(1.2,1.1,1.0) * spec * oily * pOily;
            // moist strip right along the lash line
            float marg = exp(-du*du*2600.0)*f;
            col += vec3(1.15,1.05,0.95)*pow(max(dot(n,hv),0.0), 70.0)*0.40*marg;
            // soft ambient occlusion of the whole socket
            float ring = length((p - vec2(0.0,0.05))*vec2(0.75,1.15)) - 1.05;
            col *= 1.0 - 0.10*exp(-ring*ring*6.0);
            return col;
        }

        // lid-inertia lag, set per frame in mainImage
        float gFlex = 0.0;
        // keratin glint accumulator: lashRow records where a shaft catches the
        // light; mainImage resets it before the visible lash passes
        float gGlint = 0.0;
        // J-arc dip scale: the root turn hides under the lid roll as it closes,
        // and through the flipped blink projection it would draw loops otherwise
        float gDipMul = 1.0;

        // lashes: each strand is a bent curve grown from the lid margin.
        // For a pixel we invert the fan approximately, then test nearby strand
        // candidates against their exact curves — no cell/curve mismatch.
        float lashRow(vec2 p, float rootY, float side, float seed, float lenMul, float freq, float leanBase){
            float d = side > 0.0 ? p.y - rootY : rootY - p.y;
            if(d < (side > 0.0 ? -0.08 : -0.01) || d > 0.30) return 0.0;
            float dc = max(d, 0.0);
            float px = VIEW/iResolution.y;
            // length profile along the lid: short nasal, longest mid-temporal
            float prof = 0.40 + 0.60*smoothstep(-1.05, -0.30, p.x);
            prof *= 1.0 - 0.45*smoothstep(0.70, 1.06, p.x);
            float lean0 = side > 0.0 ? (0.85*p.x - 0.10) : leanBase;
            float meanCurl = side > 0.0 ? 1.5 : 0.12;
            float ci = floor((p.x - dc*lean0 + sign(p.x+0.06)*meanCurl*dc*dc)*freq);
            // coherent air movement shared by neighbouring strands
            float breeze = noise2(vec2(p.x*2.0, iTime*0.6)) - 0.5;
            float acc = 0.0;
            // top half of the LashDark range squeezes translucency out entirely
            float dk = clamp(pLashDark - 1.0, 0.0, 1.0);
            for(int k=-4;k<=4;k++){
                float id = ci + float(k);
                // debug solo mode: keep one strand of the main upper row only
                if(pSolo > 0.5 && (seed != 0.0 || abs(id - 3.0) > 0.5)) continue;
                float h1 = hash11(id*1.37 + seed);
                float h2 = hash11(id*2.11 + seed + 7.3);
                float h3 = hash11(id*3.71 + seed + 11.1);
                float h4 = hash11(id*1.93 + seed + 17.9);
                float rootX = (id + 0.15 + 0.7*h1)/freq;
                float clump = (hash11(floor(id/3.0)*5.13 + seed + 31.7) - 0.5)
                            * (side>0.0 ? 0.35 : 0.20);
                float lean = clamp((side>0.0 ? 0.85*rootX-0.10 : leanBase + rootX*0.45)
                           + (h2-0.5)*0.25 + clump, -0.80, 0.80);
                // curl spread is wide: a few nearly straight, a few strongly hooked
                float curl = side>0.0 ? mix(0.25, 2.2, h4*h4)*pCurlUp : (0.55+0.95*h4)*pCurlLo;
                float len = (side>0.0 ? 0.085+0.115*h3 : 0.022+0.040*h3)*lenMul*prof;
                // rare strays: extra long, leaning out of the fan
                float stray = step(1.0 - 0.035*pStray, h1);
                len  *= 1.0 + 0.75*stray;
                lean += (h3-0.5)*0.55*stray;
                curl *= 1.0 - 0.45*stray;
                if(len < 0.015) continue;
                // roots staggered across a narrow band at the lash line
                float dcs = d + 0.009*h2 - 0.003;
                // J profile: the lash leaves the lid pointing down-forward, turns
                // at the bottom of a short arc, and the whole shaft rises from
                // there — so the shaft is rooted at the arc bottom, below the
                // margin, shifted forward of its follicle
                float dip = side > 0.0 ? min((0.10 + 0.20*h4)*len*pHook, 0.07)*gDipMul : 0.0;
                float fdir = lean >= 0.0 ? 1.0 : -1.0;
                float fw  = fdir*(0.55 + 0.35*h2)*dip;
                if(dcs < -dip) continue;
                float t01 = clamp(dcs/len, 0.0, 1.0);
                // upper tips curl back up towards vertical; lower bend gently to the cheek
                // short lower strands need far larger curvature to read as curved
                float bend = side>0.0 ? -curl : -9.0*curl;
                // the shaft rises from the margin already shifted past the turn
                float xe = rootX + 2.0*fw + lean*dcs + sign(rootX+0.06)*bend*dcs*dcs;
                // sway: root pinned, tip swings; per-strand phase over the shared breeze
                float wob = sin(iTime*(1.5+1.2*h2) + id*1.7)*pIdle + pBreeze*breeze
                          + gFlex*(0.5 + pWhipVar*h1);
                xe += (0.0035+0.0035*h1)*wob*t01*t01*(side>0.0 ? 1.0 : 0.6);
                // a hair is a cylinder ending in a needle: near-constant width for
                // half the length, then a conical taper to a point
                float w = (side>0.0 ? 0.0026+0.0017*h2 : 0.0017+0.0012*h2)
                        * (0.72 + 0.45*h3) * mix(1.0, 0.06, smoothstep(0.5, 1.0, t01)) + px*0.6;
                // cross-section reads as a cylinder: dense core, lighter flanks
                float adx = clamp((p.x - xe)/w, -1.5, 1.5);
                float body = sqrt(max(1.0 - adx*adx, 0.0));
                float s = smoothstep(w, w*0.25, abs(p.x - xe)) * mix(mix(0.55, 0.85, dk), 1.0, body);
                s *= smoothstep(len, len*0.88, dcs);          // crisp dark tip
                s *= step(0.0, dcs);                          // shaft exists above the margin
                // below the margin the lash turns through a parabolic arc: at each
                // depth the curve has two branches — the root growing down out of
                // the follicle and the rising shaft — meeting tangentially at the
                // bottom of the J
                if(dcs < 0.0 && dip > 0.0){
                    float q = abs(fw)*sqrt(clamp(1.0 + dcs/dip, 0.0, 1.0));
                    float xbot = rootX + fw;
                    s = max(s, max(smoothstep(w, w*0.3, abs(p.x - (xbot - q))),
                                   smoothstep(w, w*0.3, abs(p.x - (xbot + q)))));
                }
                s *= mix(0.88 + 0.12*h1, 1.0, dk);            // per-strand darkness
                s *= step(side>0.0 ? 0.18 : 0.34, h4);        // some missing, lower sparser
                // glint only where the strand spans real pixels: on low-res
                // renders a bright band on a subpixel hair reads as a break
                float dt1 = t01 - (0.22 + 0.40*h2);
                // lit flank of the cylinder: a thin specular ridge along the shaft
                float ridge = exp(-(adx + 0.35)*(adx + 0.35)*14.0);
                gGlint = max(gGlint, s*(exp(-dt1*dt1*40.0)*(0.4 + 0.6*h3) + 0.30*ridge)
                                   * smoothstep(0.9, 1.8, w/px));
                acc = 1.0 - (1.0-acc)*(1.0 - mix(0.96, 1.0, dk)*s); // crossings stack darker
            }
            if(side > 0.0){
                acc *= smoothstep(-1.14, -0.92, p.x);
            } else {
                acc *= smoothstep(-1.02, -0.66, p.x);         // lower row starts gently
            }
            acc *= smoothstep(1.13, 1.02, p.x);
            return clamp(acc, 0.0, 1.0);
        }
        // upper lid carries two rows of lashes.
        // The dropping lid rotates the whole fan toward the camera: the projected
        // height scales by the cosine of the rotation, collapses to edge-on stubs,
        // then the tips reappear pointing down past the margin.
        float lashesUp(vec2 p, float rootY, float lm, float b){
            float ps = cos(b*pLashRot);
            ps = (ps >= 0.0 ? 1.0 : -1.0)*max(abs(ps), 0.12);
            p.y = rootY + (p.y - rootY)/ps;
            gDipMul = clamp(ps, 0.0, 1.0);
            lm *= (1.0 - 0.10*b)*pLashLen;
            float a = lashRow(p, rootY, 1.0, 0.0, lm, 58.0, 0.0);
            return max(a, lashRow(p, rootY, 1.0, 43.0, 0.60*lm, 47.0, 0.0)*0.85);
        }

        // ------------------------------------------------------------- iris
        vec3 irisAlbedo(vec2 q, float pupR){
            float r = length(q);
            float rr = r/IRIS_R;
            vec2 dir = r > 1e-5 ? q/r : vec2(1,0);
            // seamless polar noise on a cylinder; slow along r => radial strands
            vec3 cyl = vec3(dir*9.0, rr*1.15);
            float fib  = fbm3(cyl);
            float fib2 = fbm3(vec3(dir*22.0, rr*2.2) + 7.1);
            float rw = rr + 0.10*(fib-0.5);
            // pupil with ruffled margin
            float pe = pupR*(1.0 + 0.08*(fbm3(vec3(dir*9.0, 0.3))-0.5));
            float inIris = smoothstep(pe, pe+0.018, r);
            // zones: amber collar hugging the pupil edge -> blue-grey stroma
            float drr = rw - pe/IRIS_R;                       // distance from the pupil margin
            float collar = smoothstep(0.05, 0.20, drr);
            float str = smoothstep(0.22, 0.80, fib*0.6 + fib2*0.45);
            vec3 inner  = vec3(0.215,0.165,0.105) * (0.50 + 0.70*str);
            vec3 outer  = mix(vec3(0.085,0.145,0.185), vec3(0.33,0.46,0.50), str);
            vec3 col = mix(inner, outer, collar);
            // crypts: dark irregular pits in mid-stroma
            vec2 cq = q*13.0 + 1.6*vec2(fbm(q*4.0), fbm(q*4.0+5.2)) - 0.8;
            float f1 = vor(cq).x;
            col *= 1.0 - 0.38*smoothstep(0.55,0.90,f1)*smoothstep(0.34,0.48,rr)*smoothstep(0.98,0.72,rr);
            // contraction furrows: concentric wavy arcs in outer third
            float fur = smoothstep(0.72, 1.0, sin(rw*34.0 + fib*4.5));
            col *= 1.0 - 0.22*fur*smoothstep(0.48,0.72,rr);
            // bright flecks near the collarette
            col += vec3(0.60,0.47,0.24)*smoothstep(0.80,0.96,fib2)*exp(-(rw-0.40)*(rw-0.40)*40.0)*0.5;
            // slow hue drift by sector: grey-green patches in the stroma
            float sect = fbm3(vec3(dir*2.6, rr*0.7)+3.3);
            col = mix(col, col*vec3(0.92,1.05,0.88), smoothstep(0.45,0.7,sect)*0.5);
            // darken outer stroma before the limbal ring
            col *= 1.0 - 0.30*smoothstep(0.50,0.95,rw);
            // collarette ridge highlight, broken by the fibers
            col += vec3(0.30,0.21,0.10)*exp(-(drr-0.14)*(drr-0.14)*200.0)*str*smoothstep(0.35,0.7,fib)*0.30;
            // limbal ring
            col *= 1.0 - pLimbus*smoothstep(0.74, 1.04, rw);
            // fiber relief: light micro-shading along key direction
            float fibL = fbm3(vec3((dir + KEY.xy*0.05)*9.0, rr*1.15));
            col *= 1.0 + pFiberRelief*(fibL - fib);
            col *= pIrisBright;
            col = mix(vec3(dot(col, vec3(0.299,0.587,0.114))), col, pIrisSat);
            // pupil
            col = mix(vec3(0.012,0.010,0.009), col, inIris);
            return max(col, 0.0);
        }

        // ------------------------------------------------------------- sclera
        vec3 scleraAlbedo(vec3 ep, vec2 uv, vec2 g){
            // conjunctiva is anchored at the fornix and corners: there the tissue
            // stays put while the globe rotates underneath, so its texture lags
            // the eyeball by the anchoring amount
            float anch = smoothstep(0.40, 0.95, abs(uv.x));
            vec2 exy = ep.xy + pAnchor*anch*g;
            vec3 alb = vec3(0.72, 0.66, 0.61);
            alb *= 0.94 + 0.10*fbm(exy*6.0);
            // gentle warm tint & pinkness toward the corners
            float corner = smoothstep(0.45, 1.0, abs(uv.x));
            alb = mix(alb, vec3(0.74,0.52,0.44), corner*0.35*pScleraWarm);
            // tension from the turn: the corner the eye looks away from goes
            // taut, the corner it turns into bunches up
            float cR = smoothstep(0.40, 0.95,  uv.x);
            float cL = smoothstep(0.40, 0.95, -uv.x);
            float str = clamp(cR*(-g.x) + cL*g.x, 0.0, 0.5)*1.3*pTension;
            float cmp = clamp(cR*g.x + cL*(-g.x), 0.0, 0.5)*1.5*pTension;
            // vessels: warped voronoi edges, gated by noise so they branch sparsely
            vec2 vp = exy*2.4 + 0.45*vec2(fbm(exy*4.5+7.7), fbm(exy*4.5+3.1)) - 0.22;
            float ed = vor(vp).y;
            float keep = smoothstep(0.50, 0.78, fbm(exy*2.2 + 9.1));
            float w1 = 0.05*(0.4+0.6*corner);
            float vein = smoothstep(w1, 0.004, ed);
            vein *= vein * keep;                                 // faint wide edges die out
            vec2 vp2 = exy*5.5 + 0.5*vec2(fbm(exy*7.0+1.3), fbm(exy*7.0+4.9)) - 0.25;
            float ed2 = vor(vp2).y;
            float cap = smoothstep(0.030, 0.003, ed2) * smoothstep(0.45,0.75, fbm(exy*3.1+2.2));
            float rho = length(ep.xy);
            float nearLimb = smoothstep(0.46, 0.62, rho);        // vessels thin out at limbus
            vein *= (0.25 + 0.75*corner) * mix(0.35, 1.0, nearLimb);
            cap  *= (0.20 + 0.80*corner) * mix(0.30, 1.0, nearLimb);
            vein *= 1.0 - 0.30*str;                              // taut side blanches
            cap  *= 1.0 - 0.30*str;
            alb *= 0.97 + 0.05*fbm(exy*18.0);                    // conjunctival texture
            alb = mix(alb, vec3(0.48,0.10,0.09), clamp(vein*1.30*pVein, 0.0, 1.0));
            alb = mix(alb, vec3(0.62,0.22,0.20), clamp(cap*0.85*pVein, 0.0, 1.0));
            alb = mix(alb, vec3(0.80,0.76,0.72), 0.15*str);
            // loose conjunctiva folds into fine vertical pleats on the bunched side
            float fold = sin(exy.x*70.0 + 4.0*fbm(exy*6.0));
            alb *= 1.0 - 0.09*cmp*(0.5 + 0.5*fold);
            // shadowed ring where sclera dives under the limbus
            alb *= 1.0 - 0.30*exp(-(rho-0.50)*(rho-0.50)*180.0);
            // slight warm cast right next to the iris
            alb *= mix(vec3(1.0), vec3(1.04,1.00,0.85), 0.45*pScleraWarm*exp(-(rho-0.56)*(rho-0.56)*70.0));
            return alb;
        }

        // ------------------------------------------------------------- tone map
        vec3 aces(vec3 x){
            return clamp(x*(2.51*x+0.03)/(x*(2.43*x+0.59)+0.14), 0.0, 1.0);
        }

        void mainImage(out vec4 fragColor, in vec2 fragCoord){
            vec3 R = iResolution;
            float scale = VIEW;
            vec2 uv = (fragCoord - 0.5*R.xy)/R.y * scale;
            uv.y -= 0.02;
            float tilt = 0.035 + 0.006*sin(iTime*0.13);          // slight head tilt + sway
            uv = mat2(cos(tilt),-sin(tilt),sin(tilt),cos(tilt))*uv;
            float px = scale / R.y;
            float t = iTime;

            vec3 rd = vec3(0.0, 0.0, -1.0);
            vec3 ro = vec3(uv, 3.0);

            vec2 g = gazeAngles(t, iMouse, R);
            vec2 gLid = gazeAngles(t - 0.06, iMouse, R);      // lids trail the saccade
            float b = max(blinkAmt(t), drowsy(t));
            b = max(b, 0.75*smoothstep(2.5, 0.4, t));         // wake up from a squint

            // lid inertia: lashes lag the moving lid a touch and settle with one
            // soft overshoot — smooth differences of the lid curve itself, so the
            // response is continuous and dies out with the motion
            float b0 = max(blinkAmt(t), drowsy(t));
            float b1 = max(blinkAmt(t-0.06), drowsy(t-0.06));
            float b2 = max(blinkAmt(t-0.12), drowsy(t-0.12));
            float b3 = max(blinkAmt(t-0.18), drowsy(t-0.18));
            float b4 = max(blinkAmt(t-0.24), drowsy(t-0.24));
            float b5 = max(blinkAmt(t-0.30), drowsy(t-0.30));
            gFlex = ((b1-b0) - 0.45*(b3-b2) + 0.18*(b5-b4)) * 2.0 * pWhip;

            // world->eye rotation
            mat3 gm = rotY(g.x) * rotX(-g.y);
            vec3 roE = ro*gm, rdE = rd*gm;

            vec2 sp = uv;                                     // lid/skin coordinates

            vec2 L = lids(sp.x, b, gLid);
            float dIn = min(L.x - sp.y, sp.y - L.y);          // >0 inside the fissure
            float inside = smoothstep(0.0, 1.5*px + 0.004, dIn);

            // ---------------- eyeball
            vec3 eyeCol = vec3(0.10, 0.035, 0.03);            // fallback: corner tissue
            float bs = dot(roE, rdE);
            float hs = bs*bs - (dot(roE,roE) - 1.0);
            float silh = sqrt(max(dot(roE,roE) - bs*bs, 0.0)); // ray distance to eye center
            if(hs > 0.0 && inside > 0.0){
                // sclera sphere
                float ts = -bs - sqrt(hs);
                vec3 PE = roE + ts*rdE;                        // eye-space point
                vec3 nS = PE;
                // cornea sphere
                vec3 oc = roE - COR_C;
                float bc = dot(oc, rdE);
                float hc = bc*bc - (dot(oc,oc) - COR_R*COR_R);
                float m = 0.0; vec3 PC = PE, nC = nS;
                if(hc > 0.0){
                    float tc = -bc - sqrt(hc);
                    PC = roE + tc*rdE;
                    if(PC.z > 0.5){
                        nC = normalize(PC - COR_C);
                        m = smoothstep(0.505, 0.455, length(PC.xy));
                    }
                }
                // --- sclera shading
                vec3 nWs = gm*nS;
                vec3 sAlb = scleraAlbedo(PE, sp, g);
                vec3 sclera = shadeDiffuse(nWs, sAlb, 1.0);
                float Fs = fresnel(max(dot(nWs, -rd), 0.0));
                // tear film over the sclera is duller than the cornea: cap the
                // window highlight so it doesn't mirror a second crisp rectangle
                sclera += min(envLight(reflect(rd, nWs)), vec3(5.0)) * Fs * 0.45;

                // --- cornea shading (refract to the iris plane)
                vec3 cornea = sclera;
                if(m > 0.0){
                    vec3 nWc = gm*nC;
                    vec3 rdr = refract(rdE, nC, 1.0/IOR);
                    float t2 = (PC.z - IRIS_Z)/max(-rdr.z, 1e-4);
                    vec2 q = PC.xy + rdr.xy*t2;
                    // pupil: slow hippus + light response flicker
                    float pup = pPupil + 0.030*sin(t*0.35) + 0.020*(fbm(vec2(t*0.8, 3.3))-0.5);
                    vec3 iAlb = irisAlbedo(q, pup);
                    // iris is lit through the cornea
                    vec3 nIr = gm*vec3(0,0,1);
                    float ndl = clamp(dot(nIr, KEY)*0.6 + 0.55, 0.0, 1.0);
                    vec3 iris = iAlb * (vec3(1.25,1.15,1.02)*ndl + vec3(0.22,0.24,0.28));
                    // caustic crescent opposite the key light
                    vec2 dq = length(q)>1e-4 ? normalize(q) : vec2(1,0);
                    float caus = pow(max(dot(dq, -normalize(KEY.xy)), 0.0), 3.0);
                    iris *= 1.0 + 0.30*caus*smoothstep(0.9,0.55,length(q)/IRIS_R);
                    // blend iris->sclera outside the limbus (fuzzy limbus)
                    float rr = length(q)/IRIS_R;
                    float limbusMix = smoothstep(0.98, 1.10, rr + 0.05*(fbm(q*14.0)-0.5));
                    vec3 through = mix(iris, sclera, limbusMix);
                    float Fc = fresnel(max(dot(nWc, -rd), 0.0));
                    cornea = through*(1.0-Fc) + envLight(reflect(rd, nWc))*Fc;
                }
                eyeCol = mix(sclera, cornea, m);
            }
            // conjunctival pocket where the fissure reaches past the eyeball
            eyeCol = mix(mix(vec3(0.55,0.42,0.40), vec3(0.20,0.09,0.08),
                             clamp((silh-1.0)*3.0, 0.0, 1.0)),
                         eyeCol, smoothstep(1.005, 0.985, silh));
            {
                // --- shadows cast by lids and lashes (pocket included)
                float su = L.x - sp.y;                        // depth under upper lid
                eyeCol *= 0.52 + 0.48*smoothstep(0.0, 0.30, su);
                eyeCol *= 0.60 + 0.40*smoothstep(0.0, 0.10, su);
                eyeCol *= 0.76 + 0.24*smoothstep(0.0, 0.07, sp.y - L.y);
                // lash shadows: strands projected onto the eye along the key light,
                // penumbra widening with distance from the lid
                vec2 shp = vec2(sp.x - su*0.50, 2.0*L.x - sp.y + su*0.15);
                float pen = 0.004 + su*0.030;
                float lsh = lashesUp(shp, L.x, 1.0, b)
                          + lashesUp(shp + vec2(pen, 0.0), L.x, 1.0, b)
                          + lashesUp(shp - vec2(pen, 0.0), L.x, 1.0, b);
                lsh /= 3.0;
                eyeCol *= 1.0 - 0.52*lsh*smoothstep(0.60, 0.10, su);
                // wet tear film mirrors the lashes right under the lid:
                // unskewed, vertically compressed, fading fast with depth
                float lrf = lashesUp(vec2(sp.x, L.x + su*1.7), L.x, 1.0, b);
                eyeCol *= 1.0 - 0.30*lrf*smoothstep(0.22, 0.02, su);
                // tear meniscus: bright along the lower lid; the upper one sits in
                // the lid shadow, so only a faint glint remains
                float men = 0.12*exp(-su*su*2600.0) + exp(-(sp.y-L.y)*(sp.y-L.y)*3800.0);
                eyeCol += vec3(0.9,0.9,0.95) * men * 0.22;
                eyeCol *= 1.0 - 0.35*exp(-su*su*9000.0);      // contact dark line
            }

            // ---------------- composite skin / eye
            // orbicularis: a blink pulls the surrounding skin toward the eye,
            // and a faint tremor keeps the field alive
            vec2 dv = sp - vec2(0.0, -0.05);
            vec2 spSkin = sp - dv*(0.05*b)*exp(-dot(dv,dv)*0.35);
            spSkin += 0.0022*vec2(noise2(sp*2.5 + vec2(t*0.7, 0.0)) - 0.5,
                                  noise2(sp*2.5 + vec2(7.7, t*0.6)) - 0.5);
            vec3 col = inside < 0.999 ? skinColor(spSkin, b, gLid) : eyeCol;
            col = mix(col, eyeCol, inside);

            // caruncle (inner corner): dragged and stretched by the turning globe,
            // tucked in when the eye looks nasal
            vec2 cc = vec2(-1.05, -0.05) + g*vec2(0.10, 0.05);
            vec2 cw = vec2(0.15*(1.0 + 0.30*clamp(g.x, -0.6, 0.6)), 0.11);
            vec2 cp = (sp - cc) / cw;
            float car = 1.0 - dot(cp,cp);
            if(car > 0.0){
                vec3 cAlb = vec3(0.56,0.24,0.20) * (0.88 + 0.24*fbm(sp*34.0));
                vec3 cN = normalize(vec3(cp*0.45, 1.0));
                vec3 cCol = shadeDiffuse(cN, cAlb, 0.85);
                cCol += envLight(reflect(rd, cN)) * fresnel(cN.z) * 0.18;
                col = mix(col, cCol, smoothstep(0.0, 0.7, car) * inside);
            }

            // lashes on top of everything; the lower row grows along the local lid normal
            gGlint = 0.0;                                    // collect only visible passes
            float lu = lashesUp(sp, L.x, 1.0, b);            // fan rotates down with the lid
            float e2 = 0.04;
            float slL = (lids(sp.x+e2, b, gLid).y - lids(sp.x-e2, b, gLid).y)/(2.0*e2);
            float ll = lashRow(sp, L.y - 0.004, -1.0, 13.0, pLashLenLo, 33.0, slL);
            ll = max(ll, 0.7*lashRow(sp, L.y - 0.010, -1.0, 29.0, 0.55*pLashLenLo, 26.0, slL));
            float ptch = 0.45 + 0.55*smoothstep(0.30, 0.62, noise2(vec2(sp.x*3.0, 9.3)));
            ll *= ptch;                                       // patchy growth
            // lower-lash shadow on the skin, displaced along the key light
            vec2 shO = vec2(-0.009, 0.010);
            float lls = lashRow(sp + shO, L.y - 0.010, -1.0, 13.0, pLashLenLo, 33.0, slL);
            lls = max(lls, 0.7*lashRow(sp + shO, L.y - 0.016, -1.0, 29.0, 0.55*pLashLenLo, 26.0, slL));
            lls = max(lls, 0.6*lashRow(sp + shO*1.9, L.y - 0.010, -1.0, 13.0, pLashLenLo, 33.0, slL));
            col *= 1.0 - 0.22*lls*ptch*(1.0 - inside);
            col = mix(col, vec3(0.028,0.020,0.016), clamp(lu, 0.0, 1.0)*clamp(0.98*pLashDark, 0.0, 1.0));
            col = mix(col, vec3(0.055,0.040,0.032), clamp(ll, 0.0, 1.0)*clamp(0.88*pLashDark, 0.0, 1.0));
            // keratin sheen: warm glints where a shaft catches the key light
            col += vec3(0.95,0.80,0.62) * gGlint * 0.30 * pLashGlint;

            // ---------------- grade
            col *= 1.0 + 0.16*clamp(-uv.x*0.55 + uv.y*0.40, -1.0, 1.0);         // key-side falloff
            col *= 1.0 - 0.35*smoothstep(0.9, 1.9, length(uv*vec2(0.75,1.0)));  // vignette
            col = aces(col*0.92);
            col = pow(col, vec3(1.0/2.2));
            // skin exists only in a patch around the eye; empty space beyond
            float rimD = length((uv - vec2(0.0, 0.10))*vec2(0.72, 1.45)) - pRim;
            float rim0 = smoothstep(0.0, 0.30, rimD + 0.12*(fbm(uv*2.4+vec2(1.7,6.2))-0.5));
            float lash = clamp(lu + ll, 0.0, 1.0)*clamp(0.98*pLashDark, 0.0, 1.0);
            float rim = rim0*(1.0 - lash);                    // lashes pierce the rim
            col += (hash12(fragCoord + fract(t)*17.0) - 0.5) * pGrain;          // grain
        #ifdef ALPHA_OUT
            // transparent surround for embedding: alpha follows the patch rim,
            // color premultiplied for canvas compositing. A lash outside the
            // patch has no skin under it — its colour is the bare lash tone,
            // otherwise the missing skin tints the strand light and milky
            col = mix(col, vec3(0.115,0.095,0.080), rim0*lash);
            float aOut = 1.0 - rim;
            fragColor = vec4(col*aOut, aOut);
        #else
            col = mix(col, vec3(0.97,1.00,1.07)*pBG, rim);
            fragColor = vec4(col, 1.0 - rim);
        #endif
        }
        """, inputs: []),
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
