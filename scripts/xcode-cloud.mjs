// Xcode Cloud as the TestFlight fallback when this Mac is busy. Free tier only: the developer
// membership includes 25 compute hours a month, and `start` refuses to go past FREE_TIER_CAP_HOURS.
// See docs/development.md, Xcode Cloud.
//
// Usage: node scripts/xcode-cloud.mjs <command>
//   setup [--dry-run]      check the workflow against WORKFLOW below and repair what differs;
//                          disable the product's other workflows. Changes nothing when all is right.
//   usage                  compute hours used this calendar month and in the last 31 days
//   start [branch] [--dry-run]
//                          start the workflow on the branch's pushed head (default dev); prints
//                          the run id on the last line. Exit 3: budget guard said no. Exit 4: not set up.
//   wait <run-id>          poll until the run finishes; exit 0 only if it succeeded; the last two
//                          lines are `commit <sha|unknown>` and `build <App Store Connect build number>`
//
// Settings come from the environment or scripts/local.env (the environment wins): ASC_KEY_ID,
// ASC_ISS, optional ASC_KEY, TESTFLIGHT_APP_ID, XCODE_CLOUD_PRODUCT_ID, XCODE_CLOUD_WORKFLOW_ID.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import { call } from './lib/asc.mjs';

export const FREE_TIER_CAP_HOURS = 20;   // 5 h under the included 25, for runs counted late
export const RUN_ESTIMATE_HOURS = 0.25;  // one Release archive of Plain
const WINDOW_DAYS = 31;                  // covers any monthly cycle, whatever day it resets
const WORKFLOW_NAME = 'TestFlight';
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
// Compute time of one run since `from`: the sum of its actions (Apple bills each action), running
// ones up to now, each cut at `from`. A run that has not started counts as one estimate, since it
// will use about that much.
export function runHours(run, actions, now, from = 0) {
  const a = run.attributes;
  if (a.executionProgress === 'PENDING' || !a.startedDate) return RUN_ESTIMATE_HOURS;
  const spans = actions?.length ? actions.map(x => x.attributes) : [a];
  let ms = 0;
  for (const s of spans) {
    if (!s.startedDate) continue;
    const end = s.finishedDate ? Date.parse(s.finishedDate) : now;
    ms += Math.max(0, end - Math.max(from, Date.parse(s.startedDate)));
  }
  return hours(ms);
}
export function monthStart(now) { const d = new Date(now); return new Date(d.getFullYear(), d.getMonth(), 1).getTime(); }
export function windowStart(now) { return now - WINDOW_DAYS * 86_400_000; }
// Runs are listed from this far before the window, so one that began earlier still counts for the
// part it ran inside the window. Two days is far longer than any archive run takes.
const LOOKBACK_MS = 2 * 86_400_000;
// runs: [{ run, actions }]. Returns hours for the calendar month and for the trailing window.
export function usageHours(runs, now) {
  let month = 0, window = 0;
  for (const { run, actions } of runs) {
    window += runHours(run, actions, now, windowStart(now));
    month += runHours(run, actions, now, monthStart(now));
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
      const fresh = page.data.filter(r => Date.parse(r.attributes.createdDate) >= windowStart(now) - LOOKBACK_MS);
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
  if (process.env.XCODE_CLOUD_PRODUCT_ID) return { id: process.env.XCODE_CLOUD_PRODUCT_ID };
  const res = await api('GET', `/v1/ciProducts?filter${q('[app]')}=${process.env.TESTFLIGHT_APP_ID}&fields${q('[ciProducts]')}=name&limit=1`);
  return res.data[0] || null;
}

// The workflow's settings. Manual starts only: no branch, tag, pull request or schedule
// condition, so it never spends compute hours by itself. One archive, uploaded by Xcode Cloud for
// internal testing (it can't go to external groups); no tests.
export const WORKFLOW = {
  name: WORKFLOW_NAME,
  description: 'Manual start only: archive Plain and upload to TestFlight (internal).',
  branchStartCondition: null, tagStartCondition: null, pullRequestStartCondition: null, scheduledStartCondition: null,
  manualBranchStartCondition: { source: { isAllMatch: true, patterns: [] } },
  manualTagStartCondition: null, manualPullRequestStartCondition: null,
  actions: [{
    name: 'Archive - iOS', actionType: 'ARCHIVE', destination: 'ANY_IOS_DEVICE', buildDistributionAudience: 'INTERNAL_ONLY',
    testConfiguration: null, scheme: 'Plain', platform: 'IOS', isRequiredToPass: true,
  }],
  isEnabled: true, isLockedForEditing: false, clean: false, containerFilePath: 'Plain.xcodeproj',
};
// The attributes that differ from WORKFLOW, ignoring the API's read-only extras.
export function workflowDiff(actual) {
  // Key order doesn't matter, and a missing field equals null.
  const canon = v => Array.isArray(v) ? v.map(canon)
    : v && typeof v === 'object' ? Object.fromEntries(Object.keys(v).sort().filter(k => v[k] != null).map(k => [k, canon(v[k])]))
    : v ?? null;
  const norm = v => JSON.stringify(canon(v));
  return Object.keys(WORKFLOW).filter(k => norm(actual[k]) !== norm(WORKFLOW[k]));
}

async function setup(dry) {
  need('TESTFLIGHT_APP_ID');
  const prod = await product();
  if (!prod) die('no Xcode Cloud product for this app yet. The owner creates it once in Xcode (docs/development.md, Xcode Cloud), then rerun setup.', 4);
  const flows = (await all(`/v1/ciProducts/${prod.id}/workflows?limit=200&fields${q('[ciWorkflows]')}=name,isEnabled`)).data;
  let flow = flows.find(f => f.id === process.env.XCODE_CLOUD_WORKFLOW_ID) || flows.find(f => f.attributes.name === WORKFLOW_NAME);
  const act = async (what, fn) => { say((dry ? 'would ' : '') + what); if (!dry) await fn(); };

  // First, before anything can fail: any other workflow (Xcode's default one starts on every
  // push) would spend hours on its own.
  for (const f of flows) {
    if (f.id === flow?.id || !f.attributes.isEnabled) continue;
    await act(`disable workflow "${f.attributes.name}"`, () =>
      api('PATCH', `/v1/ciWorkflows/${f.id}`, { data: { type: 'ciWorkflows', id: f.id, attributes: { isEnabled: false } } }));
  }

  if (flow) {
    const actual = (await api('GET', `/v1/ciWorkflows/${flow.id}`)).data.attributes;
    const diff = workflowDiff(actual);
    if (!diff.length) say(`workflow "${WORKFLOW_NAME}" is as it should be`);
    else await act(`repair workflow "${actual.name}": ${diff.join(', ')}`, () =>
      api('PATCH', `/v1/ciWorkflows/${flow.id}`, { data: { type: 'ciWorkflows', id: flow.id, attributes: WORKFLOW } }));
  } else {
    // Only when the owner's workflow is gone. "Latest Release" follows each new Xcode release.
    const repos = (await api('GET', `/v1/ciProducts/${prod.id}/primaryRepositories?limit=10&fields${q('[scmRepositories]')}=repositoryName`)).data;
    const repo = repos.find(r => r.attributes.repositoryName === 'plainbrowser') || repos[0];
    if (!repo) die('the Xcode Cloud product has no repository; grant Xcode Cloud access to the GitHub repo', 4);
    const xcode = (await api('GET', `/v1/ciXcodeVersions?limit=50&fields${q('[ciXcodeVersions]')}=name`)).data.find(x => x.attributes.name === 'Latest Release');
    const macos = (await api('GET', `/v1/ciMacOsVersions?limit=50&fields${q('[ciMacOsVersions]')}=name`)).data.find(x => x.attributes.name === 'Latest Release');
    if (!xcode || !macos) die('Xcode Cloud lists no "Latest Release" Xcode or macOS');
    const attributes = Object.fromEntries(Object.entries(WORKFLOW).filter(([, v]) => v !== null));
    await act(`create workflow "${WORKFLOW_NAME}"`, async () => {
      flow = (await api('POST', '/v1/ciWorkflows', { data: { type: 'ciWorkflows', attributes, relationships: {
        product: { data: { type: 'ciProducts', id: prod.id } },
        repository: { data: { type: 'scmRepositories', id: repo.id } },
        xcodeVersion: { data: { type: 'ciXcodeVersions', id: xcode.id } },
        macOsVersion: { data: { type: 'ciMacOsVersions', id: macos.id } },
      } } })).data;
    });
  }
  if (flow && flow.id !== process.env.XCODE_CLOUD_WORKFLOW_ID) say(`set in scripts/local.env:\nXCODE_CLOUD_WORKFLOW_ID=${flow.id}`);
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
    type: 'ciBuildRuns',
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
  let last = '', commit = '';
  for (;;) {
    const a = (await api('GET', `/v1/ciBuildRuns/${id}?fields${q('[ciBuildRuns]')}=number,executionProgress,completionStatus,sourceCommit`)).data.attributes;
    commit = a.sourceCommit?.commitSha || '';
    const state = a.executionProgress === 'COMPLETE' ? a.completionStatus : a.executionProgress;
    if (state !== last) { say(`${new Date().toTimeString().slice(0, 8)} run #${a.number}: ${state}`); last = state; }
    if (a.executionProgress === 'COMPLETE') {
      if (a.completionStatus !== 'SUCCEEDED') die(`run #${a.number} ended ${a.completionStatus}; see Xcode > Report navigator > Cloud`);
      break;
    }
    if (Date.now() > deadline) die(`run #${a.number} still ${state} after ${WAIT_MINUTES} minutes; rerun wait ${id}`);
    await new Promise(r => setTimeout(r, POLL_SECONDS * 1000));
  }
  // The App Store Connect build the run uploaded. It can show up a little after the run ends.
  let version = '';
  for (let i = 0; i < 20 && !version; i++) {
    const builds = (await api('GET', `/v1/ciBuildRuns/${id}/builds?limit=1&fields${q('[builds]')}=version`)).data;
    version = builds[0]?.attributes.version || '';
    if (!version) await new Promise(r => setTimeout(r, POLL_SECONDS * 1000));
  }
  if (!version) die(`run ${id} succeeded but no App Store Connect build appeared in 10 minutes`);
  // Last two lines, for callers: the commit the run built (when Apple reports it) and the build.
  say(`commit ${commit || 'unknown'}`);
  say(`build ${version}`);
}

async function main(argv) {
  const [cmd, ...rest] = argv;
  if (!['setup', 'usage', 'start', 'wait'].includes(cmd)) {
    die('usage: node scripts/xcode-cloud.mjs setup [--dry-run] | usage | start [branch] [--dry-run] | wait <run-id>', 2);
  }
  loadEnv();
  if (!process.env.ASC_KEY_ID || !process.env.ASC_ISS) die('ASC_KEY_ID and ASC_ISS are not set (environment or scripts/local.env)');
  const dry = rest.includes('--dry-run');
  const args = rest.filter(a => a !== '--dry-run');
  switch (cmd) {
    case 'setup': return setup(dry);
    case 'usage': return void await usage();
    case 'start': return start(args[0], dry);
    case 'wait': return wait(args[0]);
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  main(process.argv.slice(2)).catch(e => {
    console.error(`xcode-cloud.mjs: ${e.message}`);
    process.exit(e instanceof Exit ? e.code : 1);
  });
}
