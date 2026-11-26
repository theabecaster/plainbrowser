// Xcode Cloud as the TestFlight fallback when this Mac is busy. Free tier only: the developer
// membership includes 25 compute hours a month, and `start` refuses to go past FREE_TIER_CAP_HOURS.
// See docs/development.md, Xcode Cloud.
//
// Usage: node scripts/xcode-cloud.mjs <command>
//   setup                  create or update Plain's manual-only archive workflow; disables the
//                          product's other workflows; prints XCODE_CLOUD_WORKFLOW_ID
//   usage                  compute hours used this calendar month and in the last 31 days
//   start [branch] [--dry-run]
//                          start the workflow on the branch's pushed head (default dev); prints
//                          the run id on the last line. Exit 3: budget guard said no. Exit 4: not set up.
//   wait <run-id>          poll until the run finishes; exit 0 only if it succeeded; the last
//                          line is `commit <sha>` (or `commit unknown`)
//   fetch <run-id> <dir>   download the run's archive into dir; prints the .xcarchive path
//
// Settings come from the environment or scripts/local.env (the environment wins): ASC_KEY_ID,
// ASC_ISS, optional ASC_KEY, TESTFLIGHT_APP_ID, XCODE_CLOUD_WORKFLOW_ID.
import { execFileSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { call, token } from './lib/asc.mjs';

export const FREE_TIER_CAP_HOURS = 20;   // 5 h under the included 25, for runs counted late
export const RUN_ESTIMATE_HOURS = 0.25;  // one Release archive of Plain
const WINDOW_DAYS = 31;                  // covers any monthly cycle, whatever day it resets
const WORKFLOW_NAME = 'TestFlight archive (manual)';
const POLL_SECONDS = 30, WAIT_MINUTES = 90;

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const q = s => encodeURIComponent(s);

class Exit extends Error { constructor(code, msg) { super(msg); this.code = code; } }
const die = (msg, code = 1) => { throw new Exit(code, msg); };
const say = msg => console.log(msg);

// scripts/local.env fills in what the environment leaves unset.
function loadEnv() {
  const file = path.join(ROOT, 'scripts/local.env');
  if (!fs.existsSync(file)) return;
  for (const line of fs.readFileSync(file, 'utf8').split('\n')) {
    const m = line.match(/^\s*([A-Z_][A-Z0-9_]*)=(.*)$/);
    if (!m || process.env[m[1]]) continue;
    const v = m[2].trim().replace(/^(['"])(.*)\1$/, '$2');
    if (v) process.env[m[1]] = v;
  }
}

async function api(method, p, body) {
  const { status, text } = await call(method, p, body);
  let json = null;
  try { json = text ? JSON.parse(text) : null; } catch { /* not JSON */ }
  if (status < 200 || status > 299) {
    const why = json?.errors?.map(e => e.detail || e.title).join('; ') || text.slice(0, 300);
    die(`${method} ${p.split('?')[0]} answered ${status}: ${why}`);
  }
  return json;
}
// Every page of a list.
async function all(p) {
  const out = [], included = [];
  for (let next = p; next;) {
    const page = await api('GET', next);
    out.push(...page.data); included.push(...(page.included || []));
    next = page.links?.next;
  }
  return { data: out, included };
}

// ---- Budget ---------------------------------------------------------------------------------

const hours = ms => ms / 3_600_000;
// Compute time of one run: the sum of its actions (Apple bills each action), running ones up to
// now. A run that has not started counts as one estimate, since it will use about that much.
export function runHours(run, actions, now) {
  const a = run.attributes;
  if (a.executionProgress === 'PENDING' || !a.startedDate) return RUN_ESTIMATE_HOURS;
  const spans = actions?.length ? actions.map(x => x.attributes) : [a];
  let ms = 0;
  for (const s of spans) {
    if (!s.startedDate) continue;
    const end = s.finishedDate ? Date.parse(s.finishedDate) : now;
    ms += Math.max(0, end - Date.parse(s.startedDate));
  }
  return hours(ms);
}
export function monthStart(now) { const d = new Date(now); return new Date(d.getFullYear(), d.getMonth(), 1).getTime(); }
export function windowStart(now) { return now - WINDOW_DAYS * 86_400_000; }
// runs: [{ run, actions }]. Returns hours for the calendar month and for the trailing window.
export function usageHours(runs, now) {
  let month = 0, window = 0;
  for (const { run, actions } of runs) {
    const created = Date.parse(run.attributes.createdDate);
    const h = runHours(run, actions, now);
    if (created >= windowStart(now)) window += h;
    if (created >= monthStart(now)) month += h;
  }
  return { month, window };
}
// The guard uses the trailing window: Apple does not say on which day the month resets, and the
// last 31 days contain any monthly cycle, so the guard can only be early, never late.
export function budgetAllows(used, estimate = RUN_ESTIMATE_HOURS, cap = FREE_TIER_CAP_HOURS) {
  return used.window + estimate <= cap;
}

// Every run of every Xcode Cloud product on the team in the window: the 25 hours are per team.
async function recentRuns(now) {
  const products = (await all(`/v1/ciProducts?fields${q('[ciProducts]')}=name&limit=200`)).data;
  const runs = [];
  for (const p of products) {
    let next = `/v1/ciProducts/${p.id}/buildRuns?sort=-number&limit=50&include=workflow`
      + `&fields${q('[ciBuildRuns]')}=number,createdDate,startedDate,finishedDate,executionProgress,completionStatus,workflow`
      + `&fields${q('[ciWorkflows]')}=name`;
    while (next) {
      const page = await api('GET', next);
      const fresh = page.data.filter(r => Date.parse(r.attributes.createdDate) >= windowStart(now));
      runs.push(...fresh);
      // Newest first: once a page ends before the window, older pages are all outside it.
      next = fresh.length === page.data.length ? page.links?.next : null;
    }
  }
  const out = [];
  for (let i = 0; i < runs.length; i += 5) {
    out.push(...await Promise.all(runs.slice(i, i + 5).map(async run => {
      const acts = await all(`/v1/ciBuildRuns/${run.id}/actions?limit=200&fields${q('[ciBuildActions]')}=name,startedDate,finishedDate`);
      return { run, actions: acts.data };
    })));
  }
  return { products, runs: out };
}

// ---- Commands -------------------------------------------------------------------------------

function need(...vars) {
  for (const v of vars) if (!process.env[v]) die(`${v} is not set (environment or scripts/local.env)`, v === 'XCODE_CLOUD_WORKFLOW_ID' ? 4 : 1);
}

async function product() {
  const res = await api('GET', `/v1/ciProducts?filter${q('[app]')}=${process.env.TESTFLIGHT_APP_ID}&fields${q('[ciProducts]')}=name&limit=1`);
  return res.data[0] || null;
}

// The workflow's settings. Manual starts only: no branch, tag, pull request or schedule
// condition, so it never spends compute hours by itself.
function workflowAttributes() {
  return {
    name: WORKFLOW_NAME,
    description: 'Manual only, started by scripts/xcode-cloud.mjs. Archives Release; scripts/testflight.sh numbers and uploads it.',
    manualBranchStartCondition: { source: { isAllMatch: true } },
    actions: [{
      name: 'Archive - iOS', actionType: 'ARCHIVE', destination: 'ANY_IOS_DEVICE',
      scheme: 'Plain', platform: 'IOS', isRequiredToPass: true,
    }],
    isEnabled: true, isLockedForEditing: false, clean: false, containerFilePath: 'Plain.xcodeproj',
  };
}

async function setup() {
  need('TESTFLIGHT_APP_ID');
  const prod = await product();
  if (!prod) die('no Xcode Cloud product for this app yet. The owner creates it once in Xcode (docs/development.md, Xcode Cloud), then rerun setup.', 4);
  const repos = (await api('GET', `/v1/ciProducts/${prod.id}/primaryRepositories?limit=10&fields${q('[scmRepositories]')}=ownerName,repositoryName`)).data;
  const repo = repos.find(r => r.attributes.repositoryName === 'plainbrowser') || repos[0];
  if (!repo) die('the Xcode Cloud product has no repository; grant Xcode Cloud access to the GitHub repo', 4);

  // First, before anything can fail: any other workflow (Xcode's default one starts on every
  // push) would spend hours on its own.
  const flows = (await all(`/v1/ciProducts/${prod.id}/workflows?limit=200&fields${q('[ciWorkflows]')}=name,isEnabled`)).data;
  for (const f of flows) {
    if (f.attributes.name === WORKFLOW_NAME || !f.attributes.isEnabled) continue;
    await api('PATCH', `/v1/ciWorkflows/${f.id}`, { data: { type: 'ciWorkflows', id: f.id, attributes: { isEnabled: false } } });
    say(`disabled workflow "${f.attributes.name}"`);
  }

  // "Latest Release" follows each new Xcode release, so the workflow never needs an edit for it.
  const xcode = (await api('GET', `/v1/ciXcodeVersions?limit=50&fields${q('[ciXcodeVersions]')}=name,version`)).data.find(x => x.attributes.name === 'Latest Release');
  const macos = (await api('GET', `/v1/ciMacOsVersions?limit=50&fields${q('[ciMacOsVersions]')}=name,version`)).data.find(x => x.attributes.name === 'Latest Release');
  if (!xcode || !macos) die('Xcode Cloud lists no "Latest Release" Xcode or macOS');
  const rel = {
    xcodeVersion: { data: { type: 'ciXcodeVersions', id: xcode.id } },
    macOsVersion: { data: { type: 'ciMacOsVersions', id: macos.id } },
  };

  let flow = flows.find(f => f.attributes.name === WORKFLOW_NAME);
  if (flow) {
    const cleared = { branchStartCondition: null, tagStartCondition: null, pullRequestStartCondition: null, scheduledStartCondition: null };
    await api('PATCH', `/v1/ciWorkflows/${flow.id}`, { data: { type: 'ciWorkflows', id: flow.id, attributes: { ...workflowAttributes(), ...cleared }, relationships: rel } });
    say(`updated workflow "${WORKFLOW_NAME}"`);
  } else {
    flow = (await api('POST', '/v1/ciWorkflows', { data: {
      type: 'ciWorkflows', attributes: workflowAttributes(),
      relationships: { ...rel, product: { data: { type: 'ciProducts', id: prod.id } }, repository: { data: { type: 'scmRepositories', id: repo.id } } },
    } })).data;
    say(`created workflow "${WORKFLOW_NAME}"`);
  }
  say(`Xcode ${xcode.attributes.version}, macOS ${macos.attributes.version}, repo ${repo.attributes.ownerName}/${repo.attributes.repositoryName}`);
  say(`add to scripts/local.env:\nXCODE_CLOUD_WORKFLOW_ID=${flow.id}`);
}

async function usage() {
  const now = Date.now();
  const { products, runs } = await recentRuns(now);
  const used = usageHours(runs, now);
  const f = h => h.toFixed(2);
  say(`products: ${products.length}, runs in the last ${WINDOW_DAYS} days: ${runs.length}`);
  say(`used this calendar month: ${f(used.month)} h; last ${WINDOW_DAYS} days: ${f(used.window)} h`);
  say(`guard: ${f(used.window)} h + ${RUN_ESTIMATE_HOURS} h per run, cap ${FREE_TIER_CAP_HOURS} h (included: 25 h) -> ${budgetAllows(used) ? 'a new run is allowed' : 'new runs are refused'}`);
  return { used, runs };
}

async function start(branch = 'dev', dry = false) {
  need('TESTFLIGHT_APP_ID', 'XCODE_CLOUD_WORKFLOW_ID');
  const wf = process.env.XCODE_CLOUD_WORKFLOW_ID;
  const flow = (await api('GET', `/v1/ciWorkflows/${wf}?fields${q('[ciWorkflows]')}=name,isEnabled`)).data;
  if (!flow.attributes.isEnabled) die(`workflow "${flow.attributes.name}" is disabled; run setup`, 4);
  const repo = (await api('GET', `/v1/ciWorkflows/${wf}/repository?fields${q('[scmRepositories]')}=repositoryName`)).data;
  const refs = (await all(`/v1/scmRepositories/${repo.id}/gitReferences?limit=200&fields${q('[scmGitReferences]')}=name,kind,isDeleted`)).data;
  const ref = refs.find(r => r.attributes.kind === 'BRANCH' && r.attributes.name === branch && !r.attributes.isDeleted);
  if (!ref) die(`Xcode Cloud does not see branch ${branch}; push it first`);

  const { used, runs } = await usage();
  const busy = runs.find(({ run }) => run.relationships?.workflow?.data?.id === wf && run.attributes.executionProgress !== 'COMPLETE');
  if (busy) die(`run ${busy.run.id} (#${busy.run.attributes.number}) of this workflow is still going; wait for it`, 1);
  if (!budgetAllows(used)) die(`budget guard: ${used.window.toFixed(2)} h used + ${RUN_ESTIMATE_HOURS} h would pass ${FREE_TIER_CAP_HOURS} h`, 3);
  if (dry) { say(`dry run: would start "${flow.attributes.name}" on ${branch}`); return; }

  const run = (await api('POST', '/v1/ciBuildRuns', { data: {
    type: 'ciBuildRuns', attributes: { clean: false },
    relationships: {
      workflow: { data: { type: 'ciWorkflows', id: wf } },
      sourceBranchOrTag: { data: { type: 'scmGitReferences', id: ref.id } },
    },
  } })).data;
  say(`started run #${run.attributes.number ?? '?'} on ${branch}`);
  say(run.id);
}

async function wait(id) {
  if (!id) die('usage: wait <run-id>', 2);
  const deadline = Date.now() + WAIT_MINUTES * 60_000;
  let last = '';
  for (;;) {
    const a = (await api('GET', `/v1/ciBuildRuns/${id}?fields${q('[ciBuildRuns]')}=number,executionProgress,completionStatus,sourceCommit`)).data.attributes;
    const state = a.executionProgress === 'COMPLETE' ? a.completionStatus : a.executionProgress;
    if (state !== last) { say(`${new Date().toTimeString().slice(0, 8)} run #${a.number}: ${state}`); last = state; }
    if (a.executionProgress === 'COMPLETE') {
      if (a.completionStatus !== 'SUCCEEDED') die(`run #${a.number} ended ${a.completionStatus}; see Xcode > Report navigator > Cloud`);
      // Last line: the commit the run built, when Apple reports it, so callers can check it.
      say(`commit ${a.sourceCommit?.commitSha || 'unknown'}`);
      return;
    }
    if (Date.now() > deadline) die(`run #${a.number} still ${state} after ${WAIT_MINUTES} minutes; rerun wait ${id}`);
    await new Promise(r => setTimeout(r, POLL_SECONDS * 1000));
  }
}

async function fetchArchive(id, dir) {
  if (!id || !dir) die('usage: fetch <run-id> <dir>', 2);
  const actions = (await api('GET', `/v1/ciBuildRuns/${id}/actions?limit=50&fields${q('[ciBuildActions]')}=actionType,completionStatus`)).data;
  const archive = actions.find(a => a.attributes.actionType === 'ARCHIVE' && a.attributes.completionStatus === 'SUCCEEDED');
  if (!archive) die(`run ${id} has no successful archive action`);
  const arts = (await api('GET', `/v1/ciBuildActions/${archive.id}/artifacts?limit=50&fields${q('[ciArtifacts]')}=fileType,fileName,fileSize,downloadUrl`)).data;
  const art = arts.find(x => x.attributes.fileType === 'ARCHIVE');
  if (!art?.attributes.downloadUrl) die(`run ${id} has no archive artifact`);
  fs.mkdirSync(dir, { recursive: true });
  // The download link is presigned; if it ever asks for the API token, send it.
  let res = await fetch(art.attributes.downloadUrl);
  if (res.status === 401 || res.status === 403) res = await fetch(art.attributes.downloadUrl, { headers: { Authorization: `Bearer ${token()}` } });
  if (!res.ok) die(`archive download answered ${res.status}`);
  const zip = path.join(dir, 'archive.zip');
  fs.writeFileSync(zip, Buffer.from(await res.arrayBuffer()));
  execFileSync('/usr/bin/ditto', ['-x', '-k', zip, dir]);
  fs.rmSync(zip);
  const found = execFileSync('/usr/bin/find', [dir, '-maxdepth', '3', '-name', '*.xcarchive', '-type', 'd']).toString().trim().split('\n').filter(Boolean);
  if (found.length !== 1) die(`expected one .xcarchive in the artifact, found ${found.length}`);
  say(found[0]);
}

async function main(argv) {
  const [cmd, ...rest] = argv;
  if (!['setup', 'usage', 'start', 'wait', 'fetch'].includes(cmd)) {
    die('usage: node scripts/xcode-cloud.mjs setup | usage | start [branch] [--dry-run] | wait <run-id> | fetch <run-id> <dir>', 2);
  }
  loadEnv();
  if (!process.env.ASC_KEY_ID || !process.env.ASC_ISS) die('ASC_KEY_ID and ASC_ISS are not set (environment or scripts/local.env)');
  const dry = rest.includes('--dry-run');
  const args = rest.filter(a => a !== '--dry-run');
  switch (cmd) {
    case 'setup': return setup();
    case 'usage': return void await usage();
    case 'start': return start(args[0], dry);
    case 'wait': return wait(args[0]);
    case 'fetch': return fetchArchive(args[0], args[1]);
  }
}

if (import.meta.url === pathToFileURL(process.argv[1]).href) {
  main(process.argv.slice(2)).catch(e => {
    console.error(`xcode-cloud.mjs: ${e.message}`);
    process.exit(e instanceof Exit ? e.code : 1);
  });
}
