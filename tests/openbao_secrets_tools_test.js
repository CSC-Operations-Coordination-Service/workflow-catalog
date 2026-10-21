// Behaviour of the openbao-secrets action's devsecops layout (`tools`), run
// against a mock OpenBao over TLS. Started by tests/openbao_secrets_tools_test.sh,
// which extracts the action's script, makes a throwaway CA and certificate, and
// runs the action's CA step on that CA (<ca-step-output>: its GITHUB_OUTPUT):
//   node openbao_secrets_tools_test.js <script.js> <ca-step-output> <ca.crt> <key.pem> <cert.pem>
'use strict';
const fs = require('fs');
const https = require('https');
const path = require('path');

const [scriptFile, caOutputFile, caFile, keyFile, certFile] = process.argv.slice(2);
const script = fs.readFileSync(scriptFile, 'utf8');
// What the CA step wrote: one line, ca=<base64 of the CA>.
const caOutput = fs.readFileSync(caOutputFile, 'utf8');
const caFromStep = (caOutput.match(/^ca=(.*)$/m) || [])[1] || '';
// A CA that did not sign the mock's certificate: the one the action bundles.
const otherCa = Buffer.from(fs.readFileSync(path.join(__dirname, '..', '.github', 'actions', 'openbao-secrets', 'openbao-ca.crt'))).toString('base64');
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;

// --- mock OpenBao: roles ci-x, ci-x-release and ci-x-sign, a few secrets -----
// The signing key is held by ci-x-sign only, as the platform's policies hold it
// (the release role is denied it); the mock answers 403 for a path another role
// holds. Every value here is a dummy.
const SECRETS = {
  'ci-x': {
    'devsecops/data/ci/dev/nexus': { host: 'nexus.example.internal', port: 5000, username: 'ci-user-dev', password: 'dev-pw', docker_registry: 'registry-dev.example.internal', url: 'http://ignored' },
    'ocs/data/ci/repo-x/EXTRA': { value: 'extra-value' },
  },
  'ci-x-release': {
    'devsecops/data/ci/prod/nexus': { host: 'nexus.example.internal', port: '5001', username: 'ci-user-prod', password: 'prod-pw', docker_registry: 'registry.example.internal', goproxy: 'http://goproxy.example.internal' },
  },
  'ci-x-sign': {
    'devsecops/data/ci/prod/cosign': { private_key: '-----BEGIN KEY-----\nAAAA\nBBBB\n-----END KEY-----', password: 'cosign-pw' },
  },
};
const requests = [];
const logins = [];   // the role of each login request, in order
const server = https.createServer({ key: fs.readFileSync(keyFile), cert: fs.readFileSync(certFile) }, (req, res) => {
  let body = '';
  req.on('data', (c) => { body += c; });
  req.on('end', () => {
    requests.push(`${req.method} ${req.url}`);
    const send = (status, json) => { res.writeHead(status, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(json)); };
    if (req.method === 'POST' && req.url === '/v1/auth/jwt/login') {
      const { role, jwt } = JSON.parse(body);
      logins.push(role);
      if (jwt !== 'the-jwt' || !(role in SECRETS)) return send(400, { errors: [`role "${role}" could not be found`] });
      return send(200, { auth: { client_token: `tok-${role}` } });
    }
    const role = (req.headers['x-vault-token'] || '').replace(/^tok-/, '');
    if (!(role in SECRETS)) return send(403, { errors: ['permission denied'] });
    const p = req.url.replace(/^\/v1\//, '');
    for (const r of Object.keys(SECRETS)) {
      if (r !== role && p in SECRETS[r]) return send(403, { errors: ['permission denied'] });
    }
    if (!(p in SECRETS[role])) return send(404, { errors: [] });
    return send(200, { data: { data: SECRETS[role][p] } });
  });
});

// --- one run of the action's script with a fake @actions/core ----------------
async function run(envOverrides, { idToken = true } = {}) {
  const base = {
    OPENBAO_URL: `https://localhost:${server.address().port}`,
    OPENBAO_ROLE: 'ci-x', OPENBAO_AUDIENCE: 'https://openbao:8200', OPENBAO_AUTH_PATH: 'jwt',
    OPENBAO_TOOLS: '', OPENBAO_SHARED: '', OPENBAO_REPO: '', OPENBAO_ENVIRONMENT: '',
    REF_TYPE: 'branch', REF_NAME: 'develop', REPOSITORY: 'org/repo-x', REPO_NAME: 'repo-x',
    OPENBAO_CA: caFromStep,
    // What the script sees in a job with a container:, where neither holds the
    // CA: ACTION_PATH as the old steps filled it from the github.action_path
    // context (the runner's path, not translated into the container), and
    // GITHUB_ACTION_PATH, which inside github-script names github-script.
    ACTION_PATH: '/runner-side/_actions/no-such-dir',
    GITHUB_ACTION_PATH: '/__w/_actions/github-script/no-such-dir',
  };
  const saved = { ...process.env };
  Object.assign(process.env, base, envOverrides);
  const out = { exported: {}, masked: new Set(), error: null };
  const core = {
    getIDToken: async () => { if (!idToken) throw new Error('Unable to get ACTIONS_ID_TOKEN_REQUEST_URL env variable'); return 'the-jwt'; },
    setSecret: (v) => out.masked.add(v),
    exportVariable: (k, v) => { out.exported[k] = v; },
    info: () => {},
  };
  requests.length = 0;
  logins.length = 0;
  try {
    await new AsyncFunction('core', 'require', script)(core, require);
  } catch (e) {
    out.error = e.message;
  } finally {
    for (const k of Object.keys(process.env)) if (!(k in saved)) delete process.env[k];
    Object.assign(process.env, saved);
  }
  out.requests = [...requests];
  out.logins = [...logins];
  return out;
}

// The same run with extra secrets stored for ci-x, removed afterwards (the mock
// answers 403 for a path another role holds, so a broken copy cannot live under
// a second role).
async function runWith(extra, envOverrides) {
  Object.assign(SECRETS['ci-x'], extra);
  try {
    return await run(envOverrides);
  } finally {
    for (const p of Object.keys(extra)) delete SECRETS['ci-x'][p];
  }
}

let fail = 0;
const check = (name, ok) => { console.log(`${ok ? 'ok  ' : 'FAIL'} - ${name}`); if (!ok) fail = 1; };
const allMasked = (o) => Object.values(o.exported).every((v) => o.masked.has(v));

(async () => {
  await new Promise((r) => server.listen(0, 'localhost', r));

  // The CA, as the action's CA step hands it over.
  check("the action's CA step writes one line, ca=<the CA, base64 on one line>",
    /^ca=[A-Za-z0-9+/=]+\n$/.test(caOutput) && Buffer.from(caFromStep, 'base64').equals(fs.readFileSync(caFile)));

  let o = await run({ OPENBAO_TOOLS: 'nexus' });
  check("the CA from the action's CA step logs in over TLS, with ACTION_PATH and GITHUB_ACTION_PATH at directories that do not exist", o.error === null && o.logins.join() === 'ci-x');
  check('branch build: no error', o.error === null);
  check('branch build: logs in as the base role', o.logins.join() === 'ci-x' && o.exported.NEXUS_USERNAME === 'ci-user-dev');
  check('branch build: reads devsecops/ci/dev/nexus', o.requests.includes('GET /v1/devsecops/data/ci/dev/nexus'));
  check('branch build: exports the mapped names, port as a string', o.exported.NEXUS_HOST === 'nexus.example.internal' && o.exported.NEXUS_PORT === '5000' && o.exported.NEXUS_PASSWORD === 'dev-pw');
  check('branch build: docker_registry -> NEXUS_DOCKER_REGISTRY_DEV only', o.exported.NEXUS_DOCKER_REGISTRY_DEV === 'registry-dev.example.internal' && !('NEXUS_DOCKER_REGISTRY_PROD' in o.exported));
  check('an unmapped field (url) is not exported', !Object.values(o.exported).includes('http://ignored'));
  check('goproxy is optional: absent from the secret, no error and not exported', o.error === null && !('GOPROXY' in o.exported));
  check('every exported value is masked', allMasked(o));
  check('the OpenBao token is masked', o.masked.has('tok-ci-x'));

  o = await run({ OPENBAO_TOOLS: 'nexus', REF_TYPE: 'tag', REF_NAME: 'v1.2.3', OPENBAO_ENVIRONMENT: 'prod' });
  check('tag build: no error', o.error === null);
  check('tag build: logs in as <role>-release and reads prod', o.logins.join() === 'ci-x-release' && o.exported.NEXUS_USERNAME === 'ci-user-prod' && o.requests.includes('GET /v1/devsecops/data/ci/prod/nexus'));
  check('tag build: docker_registry -> NEXUS_DOCKER_REGISTRY_PROD only', o.exported.NEXUS_DOCKER_REGISTRY_PROD === 'registry.example.internal' && !('NEXUS_DOCKER_REGISTRY_DEV' in o.exported));
  check('goproxy, when stored, is exported as GOPROXY', o.exported.GOPROXY === 'http://goproxy.example.internal');

  o = await run({ OPENBAO_TOOLS: 'nexus', OPENBAO_ENVIRONMENT: 'prod' });
  check('branch build asking for prod stops, before any request', /tag builds only/.test(o.error || '') && o.requests.length === 0);

  o = await run({ OPENBAO_TOOLS: 'nexus', REF_TYPE: 'tag', OPENBAO_ENVIRONMENT: 'dev' });
  check('tag build asking for dev stops, before any request', /environment: prod for tag builds/.test(o.error || '') && o.requests.length === 0);

  o = await run({ OPENBAO_TOOLS: 'nexus', OPENBAO_ENVIRONMENT: 'staging' });
  check('an environment other than dev/prod stops', /must be 'dev' or 'prod'/.test(o.error || ''));

  o = await run({ OPENBAO_TOOLS: 'nexus nexsu' });
  check('an unknown tool stops, naming it, before any request', /Unknown tool\(s\).*nexsu/.test(o.error || '') && o.requests.length === 0);

  o = await run({ OPENBAO_TOOLS: 'constructor' });
  check("an Object property name ('constructor') is an unknown tool too", /Unknown tool\(s\).*constructor/.test(o.error || '') && o.requests.length === 0);

  o = await run({ OPENBAO_TOOLS: 'nexus', OPENBAO_SHARED: 'NEXUS_HOST' });
  check('tools with shared stops', /not both/.test(o.error || ''));

  o = await run({ OPENBAO_TOOLS: 'sonarqube' });
  check('a requested tool whose secret is missing stops (never skips)', /devsecops\/ci\/dev\/sonarqube does not exist/.test(o.error || '') && Object.keys(o.exported).length === 0);

  // Required fields. A workflow in openbao mode has no other source for these
  // (no secrets.* fallback), so a gap must stop the job here, by name.
  o = await runWith({ 'devsecops/data/ci/dev/sonarqube': { url: 'https://sonar.example' } }, { OPENBAO_TOOLS: 'sonarqube' });
  check('a secret missing a required field stops the job, naming the path and the field', /devsecops\/ci\/dev\/sonarqube lacks required field\(s\): token \(/.test(o.error || '') && Object.keys(o.exported).length === 0);
  check('  ...and the message holds no value', !(o.error || '').includes('https://sonar.example'));
  check('  ...and says how to write it by hand, value never as an argument', /bao kv put -mount=devsecops ci\/dev\/sonarqube/.test(o.error || '') && /never as an argument/.test(o.error || ''));

  o = await runWith({ 'devsecops/data/ci/dev/dockerhub': { username: 'hub-user', token: '' } }, { OPENBAO_TOOLS: 'nexus dockerhub' });
  check('an empty required field stops the job', /devsecops\/ci\/dev\/dockerhub lacks required field\(s\): token \(/.test(o.error || ''));
  check('  ...before anything is exported, even the tool read before it', o.requests.includes('GET /v1/devsecops/data/ci/dev/nexus') && Object.keys(o.exported).length === 0);
  check('  ...and the message holds no value', !(o.error || '').includes('hub-user'));

  o = await runWith({ 'devsecops/data/ci/dev/dependency-track': { url: '   ', api_key: true } }, { OPENBAO_TOOLS: 'dependency-track' });
  check('a blank or non-string/number required field stops the job, all named', /lacks required field\(s\): url, api_key \(/.test(o.error || '') && Object.keys(o.exported).length === 0);

  o = await runWith({ 'devsecops/data/ci/dev/dependency-track': { url: 'https://dt.example', api_key: 'dt-key', note: 'x' } }, { OPENBAO_TOOLS: 'dependency-track' });
  check('a complete secret passes, extra fields ignored', o.error === null && o.exported.DEPENDENCYTRACK_URL === 'https://dt.example' && o.exported.DEPENDENCYTRACK_API_KEY === 'dt-key' && Object.keys(o.exported).length === 2);

  o = await run({ OPENBAO_TOOLS: 'nexus', OPENBAO_ROLE: 'ci-nobody' });
  check('a refused login stops with the checklist', /login as role 'ci-nobody' failed.*SEALED/.test(o.error || ''));

  o = await run({ OPENBAO_TOOLS: 'nexus' }, { idToken: false });
  check('no OIDC token stops, naming id-token: write', /id-token: write/.test(o.error || ''));

  // The signing key: read alone, on tag builds only, with <role>-sign.
  const TAG = { REF_TYPE: 'tag', REF_NAME: 'v1.2.3', OPENBAO_ENVIRONMENT: 'prod' };
  o = await run({ OPENBAO_TOOLS: 'cosign', ...TAG });
  check('cosign alone on a tag build: no error', o.error === null);
  check('  ...logs in as <role>-sign, and only as that', o.logins.join() === 'ci-x-sign');
  check('  ...reads devsecops/ci/prod/cosign, nothing else', o.requests.filter((r) => r.startsWith('GET ')).join() === 'GET /v1/devsecops/data/ci/prod/cosign');
  check('  ...exports COSIGN_PRIVATE_KEY and COSIGN_PASSWORD only', Object.keys(o.exported).sort().join() === 'COSIGN_PASSWORD,COSIGN_PRIVATE_KEY');
  check('a multi-line value is exported whole', (o.exported.COSIGN_PRIVATE_KEY || '').split('\n').length === 4);
  check('a multi-line value is masked whole and line by line', o.masked.has(o.exported.COSIGN_PRIVATE_KEY) && o.masked.has('AAAA') && o.masked.has('BBBB'));
  check('  ...and the -sign token is masked', o.masked.has('tok-ci-x-sign'));

  o = await run({ OPENBAO_TOOLS: 'cosign', REF_TYPE: 'tag', REF_NAME: 'v1.2.3' });
  check('cosign alone on a tag build without environment: <role>-sign too', o.error === null && o.logins.join() === 'ci-x-sign' && 'COSIGN_PRIVATE_KEY' in o.exported);

  o = await run({ OPENBAO_TOOLS: 'cosign cosign', ...TAG });
  check('cosign named twice is cosign alone', o.error === null && o.logins.join() === 'ci-x-sign');

  o = await run({ OPENBAO_TOOLS: 'cosign nexus', ...TAG });
  check('cosign with another tool stops, naming the rule, before any request', /cosign is read alone, with the role 'ci-x-sign'.*got tools 'cosign nexus'/.test(o.error || '') && o.requests.length === 0);
  o = await run({ OPENBAO_TOOLS: 'nexus cosign', ...TAG });
  check('  ...whatever the order', /cosign is read alone/.test(o.error || '') && o.requests.length === 0);
  o = await run({ OPENBAO_TOOLS: 'nexus cosign' });
  check('  ...and on a branch build too', /cosign is read alone/.test(o.error || '') && o.requests.length === 0);

  o = await run({ OPENBAO_TOOLS: 'cosign', OPENBAO_REPO: 'EXTRA', ...TAG });
  check('cosign with repo names stops, before any request', /cosign is read alone.*got repo 'EXTRA'/.test(o.error || '') && o.requests.length === 0);

  o = await run({ OPENBAO_TOOLS: 'cosign' });
  check('cosign on a branch build stops, naming the rule, before any request', /cosign is read on tag builds only, and this is a branch build of 'develop'/.test(o.error || '') && o.requests.length === 0 && Object.keys(o.exported).length === 0);
  o = await run({ OPENBAO_TOOLS: 'cosign', OPENBAO_ENVIRONMENT: 'dev' });
  check('  ...also with environment: dev', /cosign is read on tag builds only/.test(o.error || '') && o.requests.length === 0);

  o = await run({ OPENBAO_TOOLS: 'nexus', ...TAG });
  check('nexus on a tag build still logs in as <role>-release, never -sign', o.error === null && o.logins.join() === 'ci-x-release');

  o = await run({ OPENBAO_TOOLS: 'cosign', OPENBAO_ROLE: 'ci-nobody', ...TAG });
  check('a refused -sign login names the role and its bindings (repository, tag, the catalog\'s docker-build.yml)', /login as role 'ci-nobody-sign' failed.*bound to org\/repo-x, to ref_type tag and to the jobs of the catalog's docker-build\.yml \(claim job_workflow_ref/.test(o.error || ''));
  check('  ...and asks first whether OpenBao is sealed, with no operational detail', /Check, in order: is OpenBao SEALED\? Does this job/.test(o.error || ''));
  check('  ...and says the nested-call binding (job_workflow_ref naming docker-build.yml) is not confirmed yet', /binding assumes the token's job_workflow_ref names docker-build\.yml, which is not confirmed yet: see docs\/openbao-secrets\.md/.test(o.error || ''));
  o = await run({ OPENBAO_TOOLS: 'nexus', OPENBAO_ROLE: 'ci-nobody', ...TAG });
  check('a refused -release login does not mention job_workflow_ref', /login as role 'ci-nobody-release' failed/.test(o.error || '') && !/job_workflow_ref/.test(o.error || ''));

  o = await run({ OPENBAO_TOOLS: 'nexus', OPENBAO_REPO: 'EXTRA' });
  check('repo names are read from ocs/ci/<repo> with the same login', o.error === null && o.exported.EXTRA === 'extra-value' && o.masked.has('extra-value'));

  // A repo name has one field, 'value', and the same rule as a required field.
  o = await runWith({ 'ocs/data/ci/repo-x/EMPTY': { value: '' } }, { OPENBAO_TOOLS: 'nexus', OPENBAO_REPO: 'EMPTY' });
  check("a repo name whose 'value' is empty stops the job, naming the path", /ocs\/ci\/repo-x\/EMPTY has no usable key 'value' \(/.test(o.error || ''));
  check('  ...before anything is exported, even the tool read before it', o.requests.includes('GET /v1/devsecops/data/ci/dev/nexus') && Object.keys(o.exported).length === 0);
  o = await runWith({ 'ocs/data/ci/repo-x/BLANK': { value: ' \n\t' } }, { OPENBAO_TOOLS: 'nexus', OPENBAO_REPO: 'BLANK' });
  check("a repo name whose 'value' is blank stops the job", /ocs\/ci\/repo-x\/BLANK has no usable key 'value' \(/.test(o.error || '') && Object.keys(o.exported).length === 0);
  o = await runWith({ 'ocs/data/ci/repo-x/NOVALUE': { other: 'x' } }, { OPENBAO_TOOLS: 'nexus', OPENBAO_REPO: 'NOVALUE' });
  check("a repo name without the key 'value' stops the job", /ocs\/ci\/repo-x\/NOVALUE has no usable key 'value' \(/.test(o.error || '') && Object.keys(o.exported).length === 0);

  o = await run({ OPENBAO_TOOLS: 'nexus', OPENBAO_URL: 'https://localhost:1' });
  check('an unreachable OpenBao stops with the checklist', /cannot be reached.*SEALED/.test(o.error || ''));

  // The CA is the one the step passes, and nothing stands in for it.
  o = await run({ OPENBAO_TOOLS: 'nexus', OPENBAO_CA: otherCa });
  check('a CA that did not sign the server\'s certificate: TLS refuses it, no login is sent', /cannot be reached/.test(o.error || '') && o.logins.length === 0);
  o = await run({ OPENBAO_TOOLS: 'nexus', OPENBAO_CA: '' });
  check("no CA from the CA step stops, naming that step, before any request", /The OpenBao CA did not reach this step.*'Read the bundled OpenBao CA'/.test(o.error || '') && o.requests.length === 0);
  o = await run({ OPENBAO_TOOLS: 'nexus', OPENBAO_CA: Buffer.from('not a certificate').toString('base64') });
  check('  ...and so does one that holds no PEM certificate', /The OpenBao CA did not reach this step/.test(o.error || '') && o.requests.length === 0);

  server.close();
  process.exit(fail);
})();
