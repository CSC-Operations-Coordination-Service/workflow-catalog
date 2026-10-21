// Behaviour of the openbao-secrets action's devsecops layout (`tools`), run
// against a mock OpenBao over TLS. Started by tests/openbao_secrets_tools_test.sh,
// which extracts the action's script and makes a throwaway CA and certificate:
//   node openbao_secrets_tools_test.js <script.js> <action-dir> <key.pem> <cert.pem>
'use strict';
const fs = require('fs');
const https = require('https');

const [scriptFile, actionDir, keyFile, certFile] = process.argv.slice(2);
const script = fs.readFileSync(scriptFile, 'utf8');
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;

// --- mock OpenBao: roles ci-x and ci-x-release, a few secrets ----------------
const SECRETS = {
  'ci-x': {
    'devsecops/data/ci/dev/nexus': { host: 'nexus.ocs.local', port: 8082, username: 'dev-artifact', password: 'dev-pw', docker_registry: 'registry-dev.ocs-registry.local', url: 'http://ignored' },
    'devsecops/data/ci/dev/cosign': { private_key: '-----BEGIN KEY-----\nAAAA\nBBBB\n-----END KEY-----', password: 'cosign-pw' },
    'ocs/data/ci/repo-x/EXTRA': { value: 'extra-value' },
  },
  'ci-x-release': {
    'devsecops/data/ci/prod/nexus': { host: 'nexus.ocs.local', port: '8084', username: 'prod-artifact', password: 'prod-pw', docker_registry: 'registry.ocs-registry.local', goproxy: 'http://goproxy.ocs.local' },
  },
};
const requests = [];
const server = https.createServer({ key: fs.readFileSync(keyFile), cert: fs.readFileSync(certFile) }, (req, res) => {
  let body = '';
  req.on('data', (c) => { body += c; });
  req.on('end', () => {
    requests.push(`${req.method} ${req.url}`);
    const send = (status, json) => { res.writeHead(status, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(json)); };
    if (req.method === 'POST' && req.url === '/v1/auth/jwt/login') {
      const { role, jwt } = JSON.parse(body);
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
    ACTION_PATH: actionDir,
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
  try {
    await new AsyncFunction('core', 'require', script)(core, require);
  } catch (e) {
    out.error = e.message;
  } finally {
    for (const k of Object.keys(process.env)) if (!(k in saved)) delete process.env[k];
    Object.assign(process.env, saved);
  }
  out.requests = [...requests];
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

  let o = await run({ OPENBAO_TOOLS: 'nexus' });
  check('branch build: no error', o.error === null);
  check('branch build: logs in as the base role', o.requests.includes('POST /v1/auth/jwt/login') && o.exported.NEXUS_USERNAME === 'dev-artifact');
  check('branch build: reads devsecops/ci/dev/nexus', o.requests.includes('GET /v1/devsecops/data/ci/dev/nexus'));
  check('branch build: exports the mapped names, port as a string', o.exported.NEXUS_HOST === 'nexus.ocs.local' && o.exported.NEXUS_PORT === '8082' && o.exported.NEXUS_PASSWORD === 'dev-pw');
  check('branch build: docker_registry -> NEXUS_DOCKER_REGISTRY_DEV only', o.exported.NEXUS_DOCKER_REGISTRY_DEV === 'registry-dev.ocs-registry.local' && !('NEXUS_DOCKER_REGISTRY_PROD' in o.exported));
  check('an unmapped field (url) is not exported', !Object.values(o.exported).includes('http://ignored'));
  check('goproxy is optional: absent from the secret, no error and not exported', o.error === null && !('GOPROXY' in o.exported));
  check('every exported value is masked', allMasked(o));
  check('the OpenBao token is masked', o.masked.has('tok-ci-x'));

  o = await run({ OPENBAO_TOOLS: 'nexus', REF_TYPE: 'tag', REF_NAME: 'v1.2.3', OPENBAO_ENVIRONMENT: 'prod' });
  check('tag build: no error', o.error === null);
  check('tag build: logs in as <role>-release and reads prod', o.exported.NEXUS_USERNAME === 'prod-artifact' && o.requests.includes('GET /v1/devsecops/data/ci/prod/nexus'));
  check('tag build: docker_registry -> NEXUS_DOCKER_REGISTRY_PROD only', o.exported.NEXUS_DOCKER_REGISTRY_PROD === 'registry.ocs-registry.local' && !('NEXUS_DOCKER_REGISTRY_DEV' in o.exported));
  check('goproxy, when stored, is exported as GOPROXY', o.exported.GOPROXY === 'http://goproxy.ocs.local');

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

  o = await run({ OPENBAO_TOOLS: 'cosign' });
  check('a multi-line value is exported whole', o.exported.COSIGN_PRIVATE_KEY.split('\n').length === 4);
  check('a multi-line value is masked whole and line by line', o.masked.has(o.exported.COSIGN_PRIVATE_KEY) && o.masked.has('AAAA') && o.masked.has('BBBB'));

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

  server.close();
  process.exit(fail);
})();
