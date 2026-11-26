// App Store Connect API client shared by scripts/asc.mjs and scripts/xcode-cloud.mjs.
// Needs ASC_KEY_ID and ASC_ISS in the environment; the key file is ASC_KEY or
// ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8. Nothing secret is printed.
import crypto from 'node:crypto';
import fs from 'node:fs';

export const API = 'https://api.appstoreconnect.apple.com';

// A signed JWT, valid for about 18 minutes (Apple allows 20).
export function token() {
  const kid = process.env.ASC_KEY_ID, iss = process.env.ASC_ISS;
  if (!kid || !iss) throw new Error('set ASC_KEY_ID and ASC_ISS');
  const key = fs.readFileSync(process.env.ASC_KEY || `${process.env.HOME}/.appstoreconnect/private_keys/AuthKey_${kid}.p8`, 'utf8');
  const b64 = o => Buffer.from(JSON.stringify(o)).toString('base64url');
  const now = Math.floor(Date.now() / 1000);
  const head = b64({ alg: 'ES256', kid, typ: 'JWT' });
  const claims = b64({ iss, iat: now, exp: now + 1100, aud: 'appstoreconnect-v1' });
  const sig = crypto.sign('sha256', Buffer.from(`${head}.${claims}`), { key, dsaEncoding: 'ieee-p1363' }).toString('base64url');
  return `${head}.${claims}.${sig}`;
}

// One call. PATH may be a full URL from a `links.next`. Returns { status, text }.
export async function call(method, path, body) {
  const res = await fetch(path.startsWith('http') ? path : API + path, {
    method,
    headers: { Authorization: `Bearer ${token()}`, 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : (typeof body === 'string' ? body : JSON.stringify(body)),
  });
  return { status: res.status, text: await res.text() };
}
