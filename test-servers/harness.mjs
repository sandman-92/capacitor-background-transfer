// The test harness for the upload adapters: sets uploads up on MinIO (S3) and Azurite (Azure
// Blob), checks what they stored, and stands in front of both as a recording proxy that can cut,
// slow, refuse or swallow requests. The plugin's JVM tests, Swift tests and the example app's
// end-to-end runs all use it over HTTP, so there is one implementation of the signing.
//
// Node's standard library only. Runs in the compose file next to it; with the servers on this
// machine, `S3_UPSTREAM=http://127.0.0.1:9000 AZURE_UPSTREAM=http://127.0.0.1:10000 node harness.mjs`.
//
// The URLs it hands out point at the proxies, on the host name the caller used to reach the
// control port: `localhost` from this machine and the iOS simulator, `10.0.2.2` from the
// Android emulator. A presigned S3 URL signs that host, and the proxy passes it on unchanged.
import crypto from 'node:crypto';
import http from 'node:http';

const S3_UPSTREAM = process.env.S3_UPSTREAM || 'http://minio:9000';
const AZURE_UPSTREAM = process.env.AZURE_UPSTREAM || 'http://azurite:10000';
const CONTROL_PORT = Number(process.env.CONTROL_PORT || 8790);
const S3_PORT = Number(process.env.S3_PORT || 8791);
const AZURE_PORT = Number(process.env.AZURE_PORT || 8792);

// Well-known development credentials: MinIO's default root user and Azurite's built-in account.
const S3 = { accessKey: 'minioadmin', secretKey: 'minioadmin', region: 'us-east-1', bucket: 'uploads' };
const AZURE = {
  account: 'devstoreaccount1',
  key: 'Eby8vdM02xNOcqFlqUwJPLlmEtlCDXJ1OUzFT50uSRZ6IFsuFq2UVErCz4I6tq/K1SZFPTOtr/KBHBeksoGMGw==',
  container: 'uploads',
  version: '2021-08-06',
};
const MIB = 1024 * 1024;

const sha256 = (data) => crypto.createHash('sha256').update(data).digest('hex');
const hmac = (key, data) => crypto.createHmac('sha256', key).update(data).digest();
const enc = (s) => encodeURIComponent(s).replace(/[!'()*]/g, (c) => `%${c.charCodeAt(0).toString(16).toUpperCase()}`);
const unique = (prefix) => `${prefix}-${Date.now().toString(36)}-${crypto.randomBytes(3).toString('hex')}`;

// ---- S3: AWS Signature Version 4, query-string (presigned) form -----------------------------

/** A presigned URL for `method` on `key` in the bucket, for a client reaching S3 at `host`. */
function presign({ method, host, key = '', query = {}, expires = 3600, scheme = 'http' }) {
  const amzDate = new Date().toISOString().replace(/[:-]|\.\d{3}/g, '');
  const scope = `${amzDate.slice(0, 8)}/${S3.region}/s3/aws4_request`;
  const params = {
    ...query,
    'X-Amz-Algorithm': 'AWS4-HMAC-SHA256',
    'X-Amz-Credential': `${S3.accessKey}/${scope}`,
    'X-Amz-Date': amzDate,
    'X-Amz-Expires': String(expires),
    'X-Amz-SignedHeaders': 'host',
  };
  const canonicalQuery = Object.keys(params)
    .sort()
    .map((k) => `${enc(k)}=${enc(params[k])}`)
    .join('&');
  const path = `/${S3.bucket}${key ? `/${key.split('/').map(enc).join('/')}` : ''}`;
  const canonical = [method, path, canonicalQuery, `host:${host}\n`, 'host', 'UNSIGNED-PAYLOAD'].join('\n');
  const toSign = ['AWS4-HMAC-SHA256', amzDate, scope, sha256(canonical)].join('\n');
  let signingKey = hmac(`AWS4${S3.secretKey}`, amzDate.slice(0, 8));
  for (const part of [S3.region, 's3', 'aws4_request']) signingKey = hmac(signingKey, part);
  const signature = hmac(signingKey, toSign).toString('hex');
  return `${scheme}://${host}${path}?${canonicalQuery}&X-Amz-Signature=${signature}`;
}

const s3Host = new URL(S3_UPSTREAM).host;

/** A request to MinIO itself, signed for its own host. */
async function s3(method, key, query = {}, body) {
  const url = presign({ method, host: s3Host, key, query, expires: 300 }).replace(/^http:\/\/[^/]+/, S3_UPSTREAM);
  const response = await fetch(url, { method, body });
  return { status: response.status, body: Buffer.from(await response.arrayBuffer()) };
}

async function ensureBucket() {
  const r = await s3('PUT', '');
  if (r.status !== 200 && r.status !== 409) throw new Error(`creating the bucket: HTTP ${r.status} ${r.body}`);
}

const xmlValues = (xml, tag) => [...xml.matchAll(new RegExp(`<${tag}>([^<]*)</${tag}>`, 'g'))].map((m) => m[1]);

// ---- Azure: shared access signatures (version 2020-12-06 and later string-to-sign) ----------

const iso = (seconds) => new Date(Date.now() + seconds * 1000).toISOString().replace(/\.\d{3}Z$/, 'Z');
const azureSign = (text) => hmac(Buffer.from(AZURE.key, 'base64'), text).toString('base64');

/** A service SAS for one blob. */
function blobSas(blob, permissions, expires) {
  const se = iso(expires);
  const resource = `/blob/${AZURE.account}/${AZURE.container}/${blob}`;
  const fields = [permissions, '', se, resource, '', '', '', AZURE.version, 'b', '', '', '', '', '', '', ''];
  const sig = azureSign(fields.join('\n'));
  return `sv=${AZURE.version}&se=${enc(se)}&sr=b&sp=${permissions}&sig=${enc(sig)}`;
}

/** An account SAS, for the harness's own requests (making the container, reading blobs). */
function accountSas() {
  const se = iso(600);
  const fields = [AZURE.account, 'rwdlac', 'b', 'sco', '', se, '', '', AZURE.version, ''];
  const sig = azureSign(`${fields.join('\n')}\n`);
  return `sv=${AZURE.version}&ss=b&srt=sco&sp=rwdlac&se=${enc(se)}&sig=${enc(sig)}`;
}

async function azure(method, path, query = '', body) {
  const url = `${AZURE_UPSTREAM}/${AZURE.account}/${AZURE.container}${path}?${query ? `${query}&` : ''}${accountSas()}`;
  const response = await fetch(url, { method, body, headers: { 'x-ms-version': AZURE.version } });
  return {
    status: response.status,
    body: Buffer.from(await response.arrayBuffer()),
    contentType: response.headers.get('content-type'),
  };
}

async function ensureContainer() {
  const r = await azure('PUT', '', 'restype=container');
  if (r.status !== 201 && r.status !== 409) throw new Error(`creating the container: HTTP ${r.status} ${r.body}`);
}

// ---- The recording proxies --------------------------------------------------------------------

/** Every request the proxies saw, oldest first. */
let requests = [];
/** Faults still to apply: { target, method, query, skip, action, after, status, times }. */
let faults = [];
/** Bytes per second the proxies read request bodies at; 0 for full speed. */
let throttle = 0;
/** Until when the proxies drop every connection (a network outage). */
let outageUntil = 0;
const sockets = new Set();

function takeFault(target, method, rawQuery) {
  const i = faults.findIndex(
    (f) =>
      (f.target ?? target) === target &&
      (!f.method || f.method === method) &&
      (f.query === undefined || (f.query === '' ? rawQuery === '' : rawQuery.includes(f.query))),
  );
  if (i < 0) return null;
  const fault = faults[i];
  if (fault.skip > 0) {
    // Let this many matching requests through first.
    fault.skip -= 1;
    return null;
  }
  fault.times = (fault.times ?? 1) - 1;
  if (fault.times <= 0) faults.splice(i, 1);
  return fault;
}

function errorBody(target, status) {
  const code = status === 403 ? 'AccessDenied' : status === 404 ? 'NoSuchUpload' : 'InternalError';
  return target === 's3'
    ? `<?xml version="1.0" encoding="UTF-8"?><Error><Code>${code}</Code><Message>injected by the harness</Message></Error>`
    : `<?xml version="1.0" encoding="utf-8"?><Error><Code>${status === 403 ? 'AuthorizationFailure' : code}</Code><Message>injected by the harness</Message></Error>`;
}

function proxy(target, upstream) {
  const handle = (req, res) => {
    const [path, rawQuery = ''] = req.url.split('?');
    const query = Object.fromEntries(new URLSearchParams(rawQuery));
    const entry = {
      target,
      method: req.method,
      path,
      partNumber: query.partNumber ? Number(query.partNumber) : undefined,
      comp: query.comp,
      blockid: query.blockid,
      uploadId: query.uploadId,
      uploads: 'uploads' in query || undefined,
      bytes: 0,
      status: null,
      fault: null,
      at: Date.now(),
    };
    requests.push(entry);
    if (Date.now() < outageUntil) {
      entry.fault = 'outage';
      req.socket.destroy();
      return;
    }
    const fault = takeFault(target, req.method, rawQuery);
    if (fault?.action === 'status') {
      entry.fault = `status ${fault.status}`;
      const answer = () => {
        entry.status = fault.status;
        res.writeHead(fault.status, { 'Content-Type': 'application/xml' });
        res.end(errorBody(target, fault.status));
      };
      req.resume();
      // A client waiting for `100 Continue` gets the answer instead, as from a server that refuses early.
      if (/100-continue/i.test(req.headers.expect || '')) answer();
      else req.on('end', answer);
      return;
    }
    // A fresh upstream connection each time: a kept-alive one the server has closed would answer 502.
    const up = http.request(new URL(req.url, upstream), { method: req.method, headers: req.headers, agent: false });
    // `Expect: 100-continue`: the server's go-ahead (or its early refusal) reaches the client as it would directly.
    up.on('continue', () => res.writeContinue());
    let cut = false;
    const kill = (why) => {
      if (cut) return;
      cut = true;
      entry.fault = why;
      up.destroy();
      req.socket.destroy();
    };
    let answered = false;
    req.on('data', (chunk) => {
      if (cut) return;
      entry.bytes += chunk.length;
      // After an early answer (a refusal before the body is in), the rest is read and dropped, as
      // a server that keeps the connection does.
      if (answered) return;
      up.write(chunk);
      if (fault?.action === 'cut' && entry.bytes >= (fault.after ?? 0)) return kill('cut');
      if (throttle > 0) {
        req.pause();
        setTimeout(() => req.resume(), (chunk.length / throttle) * 1000);
      }
    });
    let bodyDone = false;
    req.on('end', () => {
      bodyDone = true;
      if (!cut && !answered) up.end();
    });
    req.on('error', () => kill('client gone'));
    up.on('response', (answer) => {
      answered = true;
      entry.status = answer.statusCode;
      // `delayMs` on a fault holds the server's answer that long before it is passed on (or dropped).
      const later = (fn) => (fault?.delayMs ? setTimeout(fn, fault.delayMs) : fn());
      if (fault?.action === 'drop-answer') {
        // The server did the work; its answer never reaches the client.
        answer.resume();
        answer.on('end', () => later(() => kill('drop-answer')));
        return;
      }
      if (fault?.action === 'delay-answer') entry.fault = `answer held ${fault.delayMs} ms`;
      const reply = () =>
        later(() => {
          res.writeHead(answer.statusCode, answer.headers);
          answer.pipe(res);
        });
      // An answer that comes before the body is in waits for the rest of it, unless the client
      // asked to hear it first (`Expect: 100-continue`). Closing on a client still sending, as
      // some servers do, leaves the Android emulator's network stack waiting forever.
      if (bodyDone || /100-continue/i.test(req.headers.expect || '')) reply();
      else req.on('end', reply);
    });
    up.on('error', (e) => {
      if (cut || answered) return;
      entry.fault = `upstream: ${e.message}`;
      if (!res.headersSent) res.writeHead(502).end();
      else res.destroy();
    });
  };
  const server = http.createServer(handle);
  server.on('checkContinue', handle);
  server.on('connection', (socket) => {
    sockets.add(socket);
    socket.on('close', () => sockets.delete(socket));
  });
  return server;
}

// ---- Device runs: commands for the example app, and what it reports ---------------------------

let commands = [];
let reports = [];
let seq = 0;

// ---- The control API ---------------------------------------------------------------------------

const MAX_BODY = 4 * MIB;

async function readJson(req) {
  const chunks = [];
  let size = 0;
  for await (const chunk of req) {
    size += chunk.length;
    if (size > MAX_BODY) throw Object.assign(new Error('body too large'), { status: 413 });
    chunks.push(chunk);
  }
  const text = Buffer.concat(chunks).toString('utf8');
  return text ? JSON.parse(text) : {};
}

/** The host the client reaches the proxies at: `host` in the request body, or the one it called the control port by. */
const clientHost = (req, body = {}) => body.host || (req.headers.host || 'localhost').replace(/:\d+$/, '');

const routes = {
  /** Healthy once both servers answer. */
  'GET /health': async () => {
    const minio = await fetch(`${S3_UPSTREAM}/minio/health/ready`).then(
      (r) => r.status,
      () => 0,
    );
    const azurite = await fetch(`${AZURE_UPSTREAM}/${AZURE.account}?comp=list`).then(
      (r) => r.status,
      () => 0,
    );
    if (minio !== 200 || azurite === 0) throw new Error(`not ready: MinIO ${minio}, Azurite ${azurite}`);
    return { ok: true };
  },

  /** Creates a multipart upload and presigns every part, the completion and ListParts. */
  'POST /s3/multipart': async (req, body) => {
    await ensureBucket();
    const key = body.key || unique('multipart');
    const partSize = body.partSize || 8 * MIB;
    const parts = body.parts ?? Math.max(1, Math.ceil((body.size ?? 0) / partSize));
    const created = await s3('POST', key, { uploads: '' });
    const [uploadId] = xmlValues(created.body.toString(), 'UploadId');
    if (created.status !== 200 || !uploadId)
      throw new Error(`CreateMultipartUpload: HTTP ${created.status} ${created.body}`);
    const host = `${clientHost(req, body)}:${S3_PORT}`;
    const expires = body.expires ?? 3600;
    return {
      key,
      uploadId,
      partSize,
      partUrls: Array.from({ length: parts }, (_, i) =>
        presign({ method: 'PUT', host, key, query: { partNumber: String(i + 1), uploadId }, expires }),
      ),
      url: presign({ method: 'POST', host, key, query: { uploadId }, expires: body.completeExpires ?? expires }),
      listPartsUrl: presign({ method: 'GET', host, key, query: { uploadId }, expires }),
    };
  },

  /** A presigned PUT of a whole object. */
  'POST /s3/put': async (req, body) => {
    await ensureBucket();
    const key = body.key || unique('put');
    return {
      key,
      url: presign({ method: 'PUT', host: `${clientHost(req, body)}:${S3_PORT}`, key, expires: body.expires ?? 3600 }),
    };
  },

  /** What MinIO holds under `key`, or the parts of an upload still open. */
  'GET /s3/object': async (req, body, query) => {
    const r = await s3('GET', query.get('key'));
    return r.status === 200
      ? { exists: true, size: r.body.length, sha256: sha256(r.body) }
      : { exists: false, status: r.status };
  },
  'GET /s3/parts': async (req, body, query) => {
    const r = await s3('GET', query.get('key'), { uploadId: query.get('uploadId') });
    const xml = r.body.toString();
    return {
      status: r.status,
      parts: xmlValues(xml, 'PartNumber').map(Number),
      sizes: xmlValues(xml, 'Size').map(Number),
    };
  },

  /** A blob SAS URL (permissions `rcw` unless asked otherwise: read for the block list, create and write). */
  'POST /azure/blob': async (req, body) => {
    await ensureContainer();
    const name = body.name || unique('blob');
    const sas = blobSas(name, body.permissions ?? 'rcw', body.expires ?? 3600);
    return {
      name,
      url: `http://${clientHost(req, body)}:${AZURE_PORT}/${AZURE.account}/${AZURE.container}/${name}?${sas}`,
    };
  },
  'GET /azure/blob': async (req, body, query) => {
    const r = await azure('GET', `/${query.get('name')}`);
    return r.status === 200
      ? { exists: true, size: r.body.length, sha256: sha256(r.body), contentType: r.contentType }
      : { exists: false, status: r.status };
  },
  'GET /azure/blocks': async (req, body, query) => {
    const r = await azure('GET', `/${query.get('name')}`, 'comp=blocklist&blocklisttype=all');
    const xml = r.body.toString();
    const section = (name) => (xml.split(`<${name}>`)[1] || '').split(`</${name}>`)[0];
    return {
      status: r.status,
      committed: xmlValues(section('CommittedBlocks'), 'Name'),
      uncommitted: xmlValues(section('UncommittedBlocks'), 'Name'),
    };
  },

  /**
   * Faults for the proxies, matched on `target` (s3, azure), `method` and a `query` substring, after
   * letting `skip` matches through, `times` times: `cut` the connection after `after` body bytes,
   * answer `status` instead of forwarding (with an error body; 200 gives S3's 200-with-an-error),
   * or `drop-answer`: forward the request, then close the connection without its answer.
   * `delay-answer` (or `delayMs` on `drop-answer`) holds the server's answer `delayMs` first.
   */
  'POST /faults': async (req, body) => {
    for (const f of Array.isArray(body) ? body : [body]) faults.push({ times: 1, ...f });
    return { faults };
  },
  'POST /throttle': async (req, body) => {
    throttle = body.bytesPerSecond || 0;
    return { throttle };
  },
  'POST /outage': async (req, body) => {
    outageUntil = Date.now() + (body.seconds ?? 10) * 1000;
    for (const s of sockets) s.destroy();
    return { until: outageUntil };
  },
  'GET /requests': async (req, body, query) => ({
    requests: requests.filter((r) => !query.get('target') || r.target === query.get('target')),
  }),
  /** Clears the request log, faults, throttle and outage (not the stored objects). */
  'POST /reset': async () => {
    requests = [];
    faults = [];
    throttle = 0;
    outageUntil = 0;
    return { ok: true };
  },

  // The example app's harness mode polls for commands and posts results and events.
  'POST /commands': async (req, body) => {
    const command = { seq: ++seq, ...body };
    commands.push(command);
    return { seq: command.seq };
  },
  'GET /commands/next': async () => commands.shift() ?? null,
  'POST /reports': async (req, body) => {
    reports.push({ ...body, received: Date.now() });
    if (reports.length > 5000) reports = reports.slice(-4000);
    return { ok: true };
  },
  'GET /reports': async (req, body, query) => ({
    reports: reports.filter((r) => r.received > Number(query.get('since') || 0)),
  }),
  'POST /reports/clear': async () => {
    reports = [];
    commands = [];
    return { ok: true };
  },
};

const control = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://x');
  const cors = {
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    'Access-Control-Allow-Headers': 'Content-Type',
  };
  if (req.method === 'OPTIONS') return res.writeHead(204, cors).end();
  const route = routes[`${req.method} ${url.pathname}`];
  if (!route) return res.writeHead(404, cors).end();
  try {
    const body = req.method === 'POST' ? await readJson(req) : {};
    const result = await route(req, body, url.searchParams);
    if (result === null) return res.writeHead(204, cors).end();
    res.writeHead(200, { ...cors, 'Content-Type': 'application/json' }).end(JSON.stringify(result));
  } catch (e) {
    res
      .writeHead(e.status || 500, { ...cors, 'Content-Type': 'application/json' })
      .end(JSON.stringify({ error: String(e.message || e) }));
  }
});

proxy('s3', S3_UPSTREAM).listen(S3_PORT);
proxy('azure', AZURE_UPSTREAM).listen(AZURE_PORT);
control.listen(CONTROL_PORT, () => console.log(`harness: control ${CONTROL_PORT}, S3 ${S3_PORT}, Azure ${AZURE_PORT}`));
