// One App Store Connect API call. Usage: node scripts/asc.mjs METHOD PATH [JSON-BODY]
// Prints the HTTP status on the first line, then the response body (cut at 4000 characters).
// Needs ASC_KEY_ID and ASC_ISS in the environment; the key file is ASC_KEY or
// ~/.appstoreconnect/private_keys/AuthKey_<ASC_KEY_ID>.p8. Nothing secret is printed.
import { call } from './lib/asc.mjs';

if (!process.env.ASC_KEY_ID || !process.env.ASC_ISS) { console.error('asc.mjs: set ASC_KEY_ID and ASC_ISS'); process.exit(2); }
const [method, path, body] = process.argv.slice(2);
const res = await call(method, path, body || undefined);
console.log(res.status);
console.log(res.text.slice(0, 4000));
