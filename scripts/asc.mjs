// One App Store Connect API call. Usage: node scripts/asc.mjs METHOD PATH [JSON-BODY]
// Prints the HTTP status on the first line, then the response body (cut at 4000 characters).
// Needs ASC_KEY_ID and ASC_ISS in the environment; the key file is ASC_KEY or
// ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8. Nothing secret is printed.
import crypto from 'node:crypto';
import fs from 'node:fs';

const kid = process.env.ASC_KEY_ID, iss = process.env.ASC_ISS;
if (!kid || !iss) { console.error('asc.mjs: set ASC_KEY_ID and ASC_ISS'); process.exit(2); }
const key = fs.readFileSync(process.env.ASC_KEY || `${process.env.HOME}/.appstoreconnect/private_keys/AuthKey_${kid}.p8`, 'utf8');
const b64 = o => Buffer.from(JSON.stringify(o)).toString('base64url');
const now = Math.floor(Date.now() / 1000);
const head = b64({ alg: 'ES256', kid, typ: 'JWT' });
const claims = b64({ iss, iat: now, exp: now + 1100, aud: 'appstoreconnect-v1' });
const sig = crypto.sign('sha256', Buffer.from(`${head}.${claims}`), { key, dsaEncoding: 'ieee-p1363' }).toString('base64url');

const [method, path, body] = process.argv.slice(2);
const res = await fetch('https://api.appstoreconnect.apple.com' + path, {
  method,
  headers: { Authorization: `Bearer ${head}.${claims}.${sig}`, 'Content-Type': 'application/json' },
  body: body || undefined,
});
console.log(res.status);
console.log((await res.text()).slice(0, 4000));
