const float PI = radians(180.);
const float PI2 = PI*2.0;

mat2 rot2(float a) {
    float c = cos(a), s = sin(a);
    return mat2(c, s, -s, c);
}

void mainImage(out vec4 o, vec2 sp) {
    float z = 0.;
    vec3 vp = normalize(vec3(sp*2.,0)-iResolution.xyy);
    o = vec4(0);

    for (int i = 0; i < 50; i++) {
        vec3 p = z * vp;
        p.z += 2.5; // - 12.5*sin(iTime*0.3);
        p.y -= 1.0;
        //p.xz *= rot2(0.02*iTime);
        p.zy *= rot2(0.5);
        p.y *= 1.0 + p.z*0.7;

        // torodial coords
        float pol = atan(p.y, p.x);
        float tor = atan(p.z, length(p.xy) - 1.0);
        float rad = length(p - vec3(cos(pol), sin(pol), 0));
        rad = min(rad, 1.0);
        p = vec3((1.0 - rad)*cos(pol), (1.0 - rad)*sin(pol), tor);
        p = p.xzy;

        // coords distortions to make the flame effect
        for (float s = 0.7; s < 15.; s /= 0.6) {
            vec3 dp = cos(s*vec3(5,3,15)*(p.yzx + vec3(-iTime*0.5, iTime*0.1, s)));
            p += 0.05/s*dp;
            p.xz *= rot2(-iTime*0.3);
        }

        //p.xz *= rot2(iTime*pol);

        //float sdf = length(rad - 0.7);
        float sdf = abs(length(p.xz) - 0.3);
        float d = 0.01 + 0.25*sdf;
        vec4 col = sin(p.z/0.15 + sdf/0.1 + vec4(3,2,1,0)) + 1.0;
        o += 1.0/(d*d) * col;
        z += d; // raymarching step
    }

    o = tanh(o / 0.8e5);
}
