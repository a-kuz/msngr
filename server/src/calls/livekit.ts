import type { Env } from "../types";

/// The access token a client joins a LiveKit room with: an HS256 JWT issued
/// by the API key, naming the participant and the one room it may join. The
/// room is the call's id, which travels only inside E2EE content, so holding
/// it is the ticket; the token itself only says who is loading the SFU.
export const ROOM_TOKEN_TTL_SEC = 60 * 60;

function b64url(bytes: ArrayBuffer | Uint8Array): string {
  const arr = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  let s = "";
  for (const b of arr) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function sfuConfigured(env: Env): boolean {
  return !!(env.LIVEKIT_URL && env.LIVEKIT_API_KEY && env.LIVEKIT_API_SECRET);
}

export async function roomToken(env: Env, opts: {
  userId: string; name: string; room: string; nowSec?: number;
}): Promise<string> {
  const now = opts.nowSec ?? Math.floor(Date.now() / 1000);
  const header = { alg: "HS256", typ: "JWT" };
  const payload = {
    iss: env.LIVEKIT_API_KEY,
    sub: opts.userId,
    name: opts.name,
    nbf: now - 10,
    exp: now + ROOM_TOKEN_TTL_SEC,
    video: { room: opts.room, roomJoin: true, canPublish: true, canSubscribe: true,
             canPublishData: true },
  };
  const enc = new TextEncoder();
  const signingInput = `${b64url(enc.encode(JSON.stringify(header)))}.${b64url(enc.encode(JSON.stringify(payload)))}`;
  const key = await crypto.subtle.importKey(
    "raw", enc.encode(env.LIVEKIT_API_SECRET!), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", key, enc.encode(signingInput));
  return `${signingInput}.${b64url(sig)}`;
}
