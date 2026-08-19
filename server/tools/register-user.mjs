// Registers a user with real, verifiable crypto keys: the Ed25519 key signs the
// X25519 key ("MsngrIdentityDH/1" context) and the signed prekey, exactly the
// bytes the client checks. For seeding fixture users (the UI smoke needs @akuz)
// on a private stand.
//
//   node tools/register-user.mjs <base-url> <username> <displayName> [out.json]
//
// Prints the server's answer; with out.json also stores the private keys, so the
// user can be driven later (replies, provisioning).
import crypto from "node:crypto";

const [base, username, displayName, outPath] = process.argv.slice(2);
if (!base || !username || !displayName) {
  console.error("usage: node tools/register-user.mjs <base-url> <username> <displayName> [out.json]");
  process.exit(1);
}

const b64url = (buf) => Buffer.from(buf).toString("base64url");
const rawPub = (key) => key.export({ type: "spki", format: "der" }).subarray(-32);
const rawPriv = (key) => key.export({ type: "pkcs8", format: "der" }).subarray(-32);

const dh = crypto.generateKeyPairSync("x25519");
const signing = crypto.generateKeyPairSync("ed25519");
const sign = (data) => crypto.sign(null, data, signing.privateKey);

const bindingContext = Buffer.from("MsngrIdentityDH/1", "utf8");
const identityKeySig = sign(Buffer.concat([bindingContext, rawPub(dh.publicKey)]));

const spk = crypto.generateKeyPairSync("x25519");
const signedPrekey = { id: 1, key: b64url(rawPub(spk.publicKey)), sig: b64url(sign(rawPub(spk.publicKey))) };

const oneTime = Array.from({ length: 20 }, (_, i) => {
  const k = crypto.generateKeyPairSync("x25519");
  return { pub: { id: i + 1, key: b64url(rawPub(k.publicKey)) }, priv: b64url(rawPriv(k.privateKey)) };
});

const body = {
  username, displayName, device: { name: "seed" },
  identityKey: b64url(rawPub(dh.publicKey)),
  identitySignKey: b64url(rawPub(signing.publicKey)),
  identityKeySig: b64url(identityKeySig),
  signedPrekey,
  oneTimePrekeys: oneTime.map((k) => k.pub),
};

const res = await fetch(`${base}/api/register`, {
  method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(body),
});
const answer = await res.json();
console.log(JSON.stringify(answer));
if (!answer.ok) process.exit(1);

if (outPath) {
  const { writeFileSync } = await import("node:fs");
  writeFileSync(outPath, JSON.stringify({
    ...answer, username, displayName,
    identityKeyPriv: b64url(rawPriv(dh.privateKey)),
    identitySignKeyPriv: b64url(rawPriv(signing.privateKey)),
    signedPrekeyPriv: b64url(rawPriv(spk.privateKey)),
    oneTimePrekeysPriv: oneTime.map((k) => ({ id: k.pub.id, priv: k.priv })),
  }, null, 2));
}
