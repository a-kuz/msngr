import type { Env } from "../types";

/// The access token a client joins a LiveKit room with: an HS256 JWT issued
/// by the API key, naming the participant and the one room it may join. The
/// room is the call's id, which travels only inside E2EE content, so holding
/// it is the ticket; the token itself only says who is loading the SFU.
///
/// Ten minutes is enough to connect: the SFU hands a connected client fresh
/// tokens over signaling for as long as it stays, and a client that comes
/// back later asks the Worker for a new ticket, which checks membership again.
export const ROOM_TOKEN_TTL_SEC = 10 * 60;

function b64url(bytes: ArrayBuffer | Uint8Array): string {
  const arr = bytes instanceof Uint8Array ? bytes : new Uint8Array(bytes);
  let s = "";
  for (const b of arr) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function sfuConfigured(env: Env): boolean {
  return !!(env.LIVEKIT_URL && env.LIVEKIT_API_KEY && env.LIVEKIT_API_SECRET);
}

async function signToken(env: Env, claims: Record<string, unknown>, ttlSec: number,
                         nowSec = Math.floor(Date.now() / 1000)): Promise<string> {
  const header = { alg: "HS256", typ: "JWT" };
  const payload = { iss: env.LIVEKIT_API_KEY, nbf: nowSec - 10, exp: nowSec + ttlSec, ...claims };
  const enc = new TextEncoder();
  const signingInput = `${b64url(enc.encode(JSON.stringify(header)))}.${b64url(enc.encode(JSON.stringify(payload)))}`;
  const key = await crypto.subtle.importKey(
    "raw", enc.encode(env.LIVEKIT_API_SECRET!), { name: "HMAC", hash: "SHA-256" }, false, ["sign"]);
  const sig = await crypto.subtle.sign("HMAC", key, enc.encode(signingInput));
  return `${signingInput}.${b64url(sig)}`;
}

export async function roomToken(env: Env, opts: {
  userId: string; name: string; room: string; nowSec?: number;
}): Promise<string> {
  return signToken(env, {
    sub: opts.userId,
    name: opts.name,
    video: { room: opts.room, roomJoin: true, canPublish: true, canSubscribe: true,
             canPublishData: true },
  }, ROOM_TOKEN_TTL_SEC, opts.nowSec);
}

/// The SFU's HTTP side. `LIVEKIT_API_URL` names it directly when the Worker
/// runs next to the SFU; otherwise it is the signaling host over HTTPS.
function httpBase(env: Env): string {
  const base = env.LIVEKIT_API_URL
    ?? env.LIVEKIT_URL!.replace(/^wss:/, "https:").replace(/^ws:/, "http:");
  return base.replace(/\/$/, "");
}

/// Takes a participant out of a room. Called for someone who is no longer a
/// member of the chat while the call goes on: their ticket may still be
/// valid, and the room must not wait for it to expire. Returns false when
/// the SFU refused or could not be reached; a participant the SFU says is
/// not in the room counts as removed.
export async function removeParticipant(env: Env, room: string, identity: string): Promise<boolean> {
  if (!sfuConfigured(env)) return false;
  const token = await signToken(env, { sub: "msngr-worker", video: { roomAdmin: true, room } }, 60);
  try {
    const r = await fetch(`${httpBase(env)}/twirp/livekit.RoomService/RemoveParticipant`, {
      method: "POST",
      headers: { "content-type": "application/json", authorization: `Bearer ${token}` },
      body: JSON.stringify({ room, identity }),
    });
    if (r.ok) return true;
    const text = await r.text();
    // twirp's own not_found is the SFU speaking; any other 404 is something
    // in front of it
    if (r.status === 404 && text.includes('"not_found"')) return true;
    console.warn(`livekit: RemoveParticipant ${identity} from ${room}: ${r.status} ${text}`);
    return false;
  } catch (e) {
    console.warn(`livekit: RemoveParticipant ${identity} from ${room} failed: ${e}`);
    return false;
  }
}
