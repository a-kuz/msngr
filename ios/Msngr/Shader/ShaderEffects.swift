import UIKit
import MsngrCore

/// Shader effects played over the chat on an event: the burst that follows
/// a sent message and the one a reaction lands with. Each is a document with
/// alpha, drawn in a transparent canvas laid over the feed for a moment, with
/// `iMouse.xy` at the point the event happened. The bundled two below are the
/// defaults; the user's own replace them from Settings.
enum ShaderEffects {
    /// How long an effect canvas stays; the shaders fade out by then.
    static let duration: TimeInterval = 1.4

    @MainActor
    static func document(for effect: ShaderSurfaces.Effect) -> ShaderDocument {
        if let own = ShaderSurfaces.shared.effect(effect) { return own }
        switch effect {
        case .send: return sendBurst
        case .reaction: return reactionBurst
        }
    }

    /// Sparks flying up and out of the send button: a ring of particles on a
    /// hash, brightened in the accent colour, gone in a second.
    static let sendBurst = ShaderDocument(name: "Send burst", passes: [
        ShaderPass(id: ShaderPass.imageId, kind: .image, code: """
        float hash(float n) { return fract(sin(n) * 43758.5453); }
        void mainImage(out vec4 O, in vec2 F) {
            vec2 p = (F - iMouse.xy) / iResolution.y;
            float t = iTime;
            float fade = smoothstep(1.2, 0.2, t);
            vec3 col = vec3(0.0);
            float a = 0.0;
            for (int i = 0; i < 28; i++) {
                float fi = float(i);
                float ang = hash(fi * 7.1) * 6.2831;
                float spd = 0.18 + 0.32 * hash(fi * 3.3);
                vec2 dir = vec2(cos(ang), sin(ang)) * vec2(1.0, 1.4);
                vec2 c = dir * spd * t - vec2(0.0, 0.25 * t * t);
                float d = length(p - c);
                float r = 0.004 + 0.006 * hash(fi * 5.7);
                float g = r / (d + 1e-4);
                // the sparks are one point at t = 0: the first frames are held
                // back so the overlap does not flash white
                g = g * g * fade * smoothstep(0.0, 0.15, t);
                col += iAccent.rgb * g + vec3(1.0) * g * 0.35;
                a += g;
            }
            O = vec4(min(col, vec3(1.0)), clamp(a, 0.0, 1.0));
        }
        """, inputs: []),
    ])

    /// Confetti puffing out of the bubble a reaction landed on.
    static let reactionBurst = ShaderDocument(name: "Reaction burst", passes: [
        ShaderPass(id: ShaderPass.imageId, kind: .image, code: """
        float hash(float n) { return fract(sin(n) * 43758.5453); }
        vec3 pal(float h) { return 0.55 + 0.45 * cos(6.2831 * (h + vec3(0.0, 0.33, 0.67))); }
        void mainImage(out vec4 O, in vec2 F) {
            vec2 p = (F - iMouse.xy) / iResolution.y;
            float t = iTime;
            float fade = smoothstep(1.3, 0.4, t);
            vec3 col = vec3(0.0);
            float a = 0.0;
            for (int i = 0; i < 36; i++) {
                float fi = float(i);
                float ang = hash(fi * 2.7) * 6.2831;
                float spd = 0.25 + 0.4 * hash(fi * 9.1);
                vec2 c = vec2(cos(ang), sin(ang)) * spd * (1.0 - exp(-3.0 * t)) * 0.5;
                c.y -= 0.35 * t * t;
                vec2 q = p - c;
                float rot = t * (2.0 + 4.0 * hash(fi));
                q = mat2(cos(rot), -sin(rot), sin(rot), cos(rot)) * q;
                float sq = smoothstep(0.011, 0.008, max(abs(q.x), abs(q.y) * 1.8));
                col += pal(hash(fi * 4.4)) * sq;
                a += sq;
            }
            O = vec4(col * fade, clamp(a, 0.0, 1.0) * fade);
        }
        """, inputs: []),
    ])
}

/// A transparent canvas laid over a view for the life of one effect. Runs at
/// the `focus` priority so a burst is never the one told to hold a frame.
@MainActor
enum ShaderEffectPlayer {
    static func play(_ effect: ShaderSurfaces.Effect, in host: UIView, at point: CGPoint) {
        guard ShaderSurfaces.shared.effectsEnabled else {
            MsngrLog.shader.info("effect \(effect.rawValue, privacy: .public) skipped: effects are off")
            return
        }
        let document = ShaderEffects.document(for: effect)
        let canvas = ShaderCanvas(transparent: true)
        canvas.priority = .focus
        canvas.deviceInputs = true
        canvas.isUserInteractionEnabled = false
        canvas.frame = host.bounds
        canvas.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.addSubview(canvas)
        MsngrLog.shader.info("effect \(effect.rawValue, privacy: .public) starts")
        // the effect lives `duration` from the moment its program is ready:
        // counted from play(), a cold compile ate the window and the first
        // effect of a process was cut short or never seen at all
        var takenDown = false
        let takeDown = {
            guard !takenDown else { return }
            takenDown = true
            canvas.setRunning(false)
            canvas.clear()
            canvas.removeFromSuperview()
        }
        canvas.onState = { state in
            switch state {
            case .ready:
                MsngrLog.shader.info("effect \(effect.rawValue, privacy: .public) ready")
                DispatchQueue.main.asyncAfter(deadline: .now() + ShaderEffects.duration) { takeDown() }
            case .failed(let why):
                MsngrLog.shader.error("effect \(effect.rawValue, privacy: .public) failed: \(why, privacy: .public)")
                DispatchQueue.main.async { takeDown() }
            case .compiling: break
            }
        }
        canvas.show(document)
        // iMouse: the point of the event, in the canvas's pixels with y up
        canvas.renderer?.touch(point, in: host.bounds.size, scale: canvas.metalView.contentScaleFactor, began: true)
        canvas.renderer?.touch(point, in: host.bounds.size, scale: canvas.metalView.contentScaleFactor, began: false)
        canvas.setRunning(true)
        // whatever happens to the program, the overlay does not outlive the compile timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + ShaderProgram.compileTimeout + ShaderEffects.duration) { takeDown() }
    }
}
