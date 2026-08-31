import { createHash, timingSafeEqual } from 'node:crypto';
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { createServer } from 'node:http';
import { WebSocket, WebSocketServer } from 'ws';

const host = process.env.RELAY_HOST ?? '0.0.0.0';
const port = Number(process.env.RELAY_PORT ?? 8787);
const apiToken = process.env.RELAY_API_TOKEN ?? '';
const dataDir = process.env.RELAY_DATA_DIR ?? '/data';
const maxHttpBodyBytes = 2 * 1024 * 1024;
// An 8 MiB binary write is base64 encoded inside JSON before it reaches the
// relay. Leave room for that expansion and the frame envelope.
const maxWebSocketBytes = 16 * 1024 * 1024;
const maxRpcPayloadBytes = maxWebSocketBytes;
const requestRetentionMs = 30 * 60 * 1000;
const requestTimeoutMs = 15 * 60 * 1000;
const heartbeatTimeoutMs = 45 * 1000;
const operations = new Set([
  'exec',
  'process.start',
  'process.poll',
  'process.write',
  'process.stop',
  'file.read',
  'file.write',
  'file.replace',
  'status',
]);

if (!Number.isInteger(port) || port < 1 || port > 65535) {
  throw new Error('RELAY_PORT must be a valid TCP port');
}
if (!apiToken) {
  console.warn('RELAY_API_TOKEN is empty; phone management endpoints will reject requests');
}

mkdirSync(dataDir, { recursive: true });
const deviceFile = join(dataDir, 'devices.json');
const devices = new Map();
const deviceSockets = new Map();
const phoneSockets = new Set();
const requests = new Map();

loadDevices();

const server = createServer(async (request, response) => {
  try {
    await route(request, response);
  } catch (error) {
    if (!response.headersSent) {
      sendJson(response, error.statusCode ?? 500, {
        error: error instanceof Error ? error.message : String(error),
      });
    } else {
      response.destroy();
    }
  }
});

const deviceWss = new WebSocketServer({ noServer: true, maxPayload: maxWebSocketBytes });
const phoneWss = new WebSocketServer({ noServer: true, maxPayload: maxWebSocketBytes });

server.on('upgrade', (request, socket, head) => {
  let url;
  try {
    url = new URL(request.url ?? '/', `http://${request.headers.host ?? 'localhost'}`);
  } catch {
    rejectUpgrade(socket, 400, 'Bad Request');
    return;
  }
  if (url.pathname === '/device/ws') {
    deviceWss.handleUpgrade(request, socket, head, (client) => {
      deviceWss.emit('connection', client);
    });
    return;
  }
  const phonePrefix = '/v1/devices/';
  const phoneSuffix = '/ws';
  if (url.pathname.startsWith(phonePrefix) && url.pathname.endsWith(phoneSuffix)) {
    if (!isApiAuthorized(request)) {
      rejectUpgrade(socket, 401, 'Unauthorized');
      return;
    }
    const encodedDeviceId = url.pathname.slice(
      phonePrefix.length,
      -phoneSuffix.length,
    );
    let pathDeviceId;
    try {
      pathDeviceId = normalizeId(
        decodeURIComponent(encodedDeviceId),
        'device_id',
      );
    } catch {
      rejectUpgrade(socket, 400, 'Bad Request');
      return;
    }
    phoneWss.handleUpgrade(request, socket, head, (client) => {
      phoneWss.emit('connection', client, pathDeviceId);
    });
    return;
  }
  socket.destroy();
});

server.listen(port, host, () => {
  console.log(`computer relay listening on ${host}:${port}`);
});

setInterval(() => {
  const cutoff = Date.now() - requestRetentionMs;
  for (const [id, value] of requests) {
    if (value.updatedAt < cutoff) requests.delete(id);
  }
  for (const [deviceId, socket] of deviceSockets) {
    const device = devices.get(deviceId);
    if (!device || device.lastSeen == null || device.lastSeen + heartbeatTimeoutMs <= Date.now()) {
      deviceSockets.delete(deviceId);
      if (socket.readyState === WebSocket.OPEN) socket.close(4004, 'heartbeat timeout');
    }
  }
}, 15_000).unref();

async function route(request, response) {
  const url = new URL(
    request.url ?? '/',
    `http://${request.headers.host ?? 'localhost'}`,
  );
  const parts = url.pathname.split('/').filter(Boolean);
  if (request.method === 'GET' && url.pathname === '/v1/health') {
    return sendJson(response, 200, { status: 'ok' });
  }
  if (parts[0] !== 'v1') return sendJson(response, 404, { error: 'not found' });
  if (!isApiAuthorized(request)) return sendJson(response, 401, { error: 'unauthorized' });

  if (request.method === 'GET' && parts[1] === 'devices' && parts.length === 2) {
    return sendJson(
      response,
      200,
      [...devices.entries()].map(([id, device]) => deviceSummary(id, device)),
    );
  }
  if (request.method === 'POST' && parts[1] === 'devices' && parts[2] && parts[3] === 'register') {
    return registerDevice(request, response, normalizeId(parts[2], 'device_id'));
  }
  if (parts[1] === 'devices' && parts[2]) {
    const deviceId = normalizeId(parts[2], 'device_id');
    if (request.method === 'GET' && parts[3] === 'status') {
      const device = devices.get(deviceId);
      if (!device) return sendJson(response, 404, { error: 'device not registered' });
      return sendJson(response, 200, deviceSummary(deviceId, device));
    }
  }
  if (request.method === 'GET' && parts[1] === 'requests' && parts[2]) {
    const value = requests.get(normalizeId(parts[2], 'request_id'));
    if (!value) return sendJson(response, 404, { error: 'request not found' });
    return sendJson(response, 200, publicRequest(value));
  }
  return sendJson(response, 404, { error: 'not found' });
}

async function registerDevice(request, response, deviceId) {
  const body = await readJson(request);
  const name = boundedText(body.name, 'name', 1, 120);
  const token = boundedText(body.device_token, 'device_token', 16, 512);
  devices.set(deviceId, {
    name,
    tokenHash: hashToken(deviceId, token),
    agentVersion: null,
    protocolVersion: null,
    lastSeen: null,
    capabilities: null,
  });
  saveDevices();
  return sendJson(response, 200, { registered: true, device_id: deviceId });
}

deviceWss.on('connection', (socket) => {
  let deviceId = null;
  let authenticated = false;
  const authenticationTimer = setTimeout(() => {
    if (!authenticated && socket.readyState <= WebSocket.OPEN) {
      socket.close(4001, 'authentication timeout');
    }
  }, 5_000);
  authenticationTimer.unref?.();

  socket.on('message', (raw, isBinary) => {
    if (isBinary) {
      socket.close(1003, 'text messages required');
      return;
    }
    let message;
    try {
      message = parseFrame(raw);
    } catch {
      socket.close(1007, 'invalid JSON');
      return;
    }
    void handleDeviceMessage(socket, message, {
      get deviceId() { return deviceId; },
      set deviceId(value) { deviceId = value; },
      get authenticated() { return authenticated; },
      set authenticated(value) { authenticated = value; },
      authenticationTimer,
    }).catch(() => {
      if (socket.readyState <= WebSocket.OPEN) socket.close(1011, 'device message failed');
    });
  });
  socket.once('close', () => {
    clearTimeout(authenticationTimer);
    if (deviceId && deviceSockets.get(deviceId) === socket) deviceSockets.delete(deviceId);
  });
  socket.on('error', () => {});
});

phoneWss.on('connection', (socket, pathDeviceId) => {
  phoneSockets.add(socket);
  let deviceId = null;
  let authenticated = false;
  const authenticationTimer = setTimeout(() => {
    if (!authenticated && socket.readyState <= WebSocket.OPEN) {
      socket.close(4001, 'hello required');
    }
  }, 5_000);
  authenticationTimer.unref?.();

  socket.on('message', (raw, isBinary) => {
    if (isBinary) {
      socket.close(1003, 'text messages required');
      return;
    }
    let message;
    try {
      message = parseFrame(raw);
    } catch {
      socket.close(1007, 'invalid JSON');
      return;
    }
    void handlePhoneMessage(socket, message, {
      get deviceId() { return deviceId; },
      set deviceId(value) { deviceId = value; },
      get authenticated() { return authenticated; },
      set authenticated(value) { authenticated = value; },
      pathDeviceId,
      authenticationTimer,
    }).catch(() => {
      if (socket.readyState <= WebSocket.OPEN) socket.close(1011, 'phone message failed');
    });
  });
  socket.once('close', () => {
    clearTimeout(authenticationTimer);
    phoneSockets.delete(socket);
    for (const value of requests.values()) {
      if (value.phone === socket) value.phone = null;
    }
  });
  socket.on('error', () => {});
});

async function handleDeviceMessage(socket, message, state) {
  if (!state.authenticated) {
    if (message?.type !== 'authenticate') {
      socket.close(4001, 'authentication required');
      return;
    }
    const id = normalizeId(message.device_id, 'device_id');
    const device = devices.get(id);
    if (!device || !safeEqual(device.tokenHash, hashToken(id, String(message.device_token ?? '')))) {
      socket.close(4003, 'device authentication failed');
      return;
    }
    const oldSocket = deviceSockets.get(id);
    if (oldSocket && oldSocket !== socket && oldSocket.readyState <= WebSocket.OPEN) {
      oldSocket.close(4002, 'device reconnected');
    }
    state.deviceId = id;
    state.authenticated = true;
    clearTimeout(state.authenticationTimer);
    deviceSockets.set(id, socket);
    touchDevice(device, message);
    saveDevices();
    send(socket, {
      type: 'authenticated',
      device_id: id,
      heartbeat_interval_ms: 15_000,
    });
    for (const value of requests.values()) {
      if (value.deviceId === id && value.status === 'running') {
        send(socket, {
          type: 'call',
          request_id: value.id,
          operation: value.operation,
          payload: value.payload,
        });
      }
    }
    return;
  }

  const device = devices.get(state.deviceId);
  if (!device) {
    socket.close(4003, 'device revoked');
    return;
  }
  if (message?.type === 'heartbeat') {
    touchDevice(device, message);
    send(socket, { type: 'heartbeat_ack', observed_at: Date.now() });
    return;
  }
  if (message?.type === 'capabilities') {
    device.capabilities = normalizeCapabilities(message.capabilities);
    device.lastSeen = Date.now();
    saveDevices();
    return;
  }
  if (message?.type === 'result') {
    acceptResult(state.deviceId, message);
    return;
  }
  socket.close(1008, 'unsupported device message');
}

async function handlePhoneMessage(socket, message, state) {
  if (!state.authenticated) {
    if (message?.type !== 'hello') {
      socket.close(4001, 'hello required');
      return;
    }
    const id = normalizeId(message.device_id, 'device_id');
    if (id !== state.pathDeviceId) {
      socket.close(4003, 'device path mismatch');
      return;
    }
    if (!devices.has(id)) {
      socket.close(4004, 'device not registered');
      return;
    }
    state.deviceId = id;
    state.authenticated = true;
    clearTimeout(state.authenticationTimer);
    send(socket, {
      type: 'authenticated',
      device_id: id,
      online: isDeviceOnline(id),
    });
    const pending = Array.isArray(message.pending_request_ids)
      ? message.pending_request_ids.map((value) => normalizeId(value, 'request_id')).slice(0, 64)
      : [];
    for (const requestId of pending) {
      const value = requests.get(requestId);
      if (value && value.deviceId === id && isTerminal(value.status)) {
        send(socket, resultFrame(value));
      }
    }
    return;
  }
  if (message?.type === 'request') {
    return createRequest(socket, state.deviceId, message);
  }
  if (message?.type === 'cancel') {
    return cancelRequest(socket, state.deviceId, message.request_id);
  }
  if (message?.type === 'ping') {
    send(socket, { type: 'pong' });
    return;
  }
  socket.close(1008, 'unsupported phone message');
}

function createRequest(phone, deviceId, message) {
  const requestId = normalizeId(message.request_id, 'request_id');
  const operation = boundedText(message.operation, 'operation', 1, 80);
  if (!operations.has(operation)) throw relayError(400, 'unsupported operation');
  const payload = message.payload && typeof message.payload === 'object' && !Array.isArray(message.payload)
    ? message.payload
    : {};
  const serializedPayload = JSON.stringify(payload);
  if (Buffer.byteLength(serializedPayload) > maxRpcPayloadBytes) throw relayError(413, 'request payload too large');

  const existing = requests.get(requestId);
  if (existing) {
    if (existing.deviceId !== deviceId || existing.operation !== operation) {
      throw relayError(409, 'request_id is already in use');
    }
    existing.phone = phone;
    send(phone, isTerminal(existing.status) ? resultFrame(existing) : acceptedFrame(existing));
    return;
  }
  const value = {
    id: requestId,
    deviceId,
    operation,
    payload,
    status: 'running',
    result: null,
    error: null,
    phone,
    createdAt: Date.now(),
    updatedAt: Date.now(),
    timeout: null,
  };
  requests.set(requestId, value);
  const device = deviceSockets.get(deviceId);
  if (!device || device.readyState !== WebSocket.OPEN) {
    finishRequest(value, false, null, 'Windows Agent 离线；调用未执行');
    send(phone, resultFrame(value));
    return;
  }
  value.timeout = setTimeout(() => {
    finishRequest(value, false, null, 'Windows Agent 调用超时；未自动重试');
    send(device, { type: 'cancel', request_id: value.id });
  }, requestTimeoutMs);
  value.timeout.unref?.();
  send(phone, acceptedFrame(value));
  send(device, {
    type: 'call',
    request_id: requestId,
    operation,
    payload,
  });
}

function cancelRequest(phone, deviceId, rawRequestId) {
  const requestId = normalizeId(rawRequestId, 'request_id');
  const value = requests.get(requestId);
  if (!value || value.deviceId !== deviceId) {
    send(phone, { type: 'result', request_id: requestId, ok: false, error: 'request not found' });
    return;
  }
  if (isTerminal(value.status)) {
    send(phone, resultFrame(value));
    return;
  }
  finishRequest(value, false, null, '调用已取消');
  const device = deviceSockets.get(deviceId);
  if (device?.readyState === WebSocket.OPEN) send(device, { type: 'cancel', request_id: requestId });
  send(phone, resultFrame(value));
}

function acceptResult(deviceId, message) {
  const requestId = normalizeId(message.request_id, 'request_id');
  const value = requests.get(requestId);
  if (!value || value.deviceId !== deviceId || isTerminal(value.status)) return;
  const result = message.result && typeof message.result === 'object' && !Array.isArray(message.result)
    ? message.result
    : null;
  if (message.ok === true) finishRequest(value, true, result, null);
  else finishRequest(value, false, null, safeError(message.error));
  if (value.phone) send(value.phone, resultFrame(value));
}

function finishRequest(value, ok, result, error) {
  if (isTerminal(value.status)) return;
  clearTimeout(value.timeout);
  value.timeout = null;
  value.status = ok ? 'completed' : 'failed';
  value.result = ok ? result : null;
  value.error = ok ? null : error || 'Windows Agent 调用失败';
  value.updatedAt = Date.now();
}

function acceptedFrame(value) {
  return { type: 'accepted', request_id: value.id, status: value.status };
}

function resultFrame(value) {
  return {
    type: 'result',
    request_id: value.id,
    ok: value.status === 'completed',
    result: value.result,
    ...(value.error ? { error: value.error } : {}),
  };
}

function isDeviceOnline(deviceId) {
  const socket = deviceSockets.get(deviceId);
  const device = devices.get(deviceId);
  return Boolean(
    socket?.readyState === WebSocket.OPEN &&
    device?.lastSeen != null &&
    device.lastSeen + heartbeatTimeoutMs > Date.now(),
  );
}

function touchDevice(device, message) {
  device.lastSeen = Date.now();
  if (typeof message.agent_version === 'string') device.agentVersion = message.agent_version.slice(0, 80);
  if (typeof message.protocol_version === 'string') device.protocolVersion = message.protocol_version.slice(0, 40);
}

function deviceSummary(id, device) {
  return {
    device_id: id,
    name: device.name,
    online: isDeviceOnline(id),
    last_seen: device.lastSeen == null ? null : new Date(device.lastSeen).toISOString(),
    agent_version: device.agentVersion,
    protocol_version: device.protocolVersion,
    capabilities: device.capabilities,
  };
}

function normalizeCapabilities(value) {
  if (!value || typeof value !== 'object' || Array.isArray(value)) return {};
  return {
    operations: Array.isArray(value.operations)
      ? [...new Set(value.operations.map(String).filter((item) => operations.has(item)))].slice(0, 32)
      : [],
    platform: typeof value.platform === 'string' ? value.platform.slice(0, 40) : null,
    agent_version: typeof value.agent_version === 'string' ? value.agent_version.slice(0, 80) : null,
  };
}

function isTerminal(status) {
  return status === 'completed' || status === 'failed' || status === 'cancelled';
}

function parseFrame(raw) {
  const text = Buffer.from(raw).toString('utf8');
  const value = JSON.parse(text);
  if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error('frame must be an object');
  return value;
}

function send(socket, value) {
  if (socket?.readyState !== WebSocket.OPEN) return false;
  const text = JSON.stringify(value);
  if (Buffer.byteLength(text) > maxWebSocketBytes) {
    socket.close(1009, 'message too large');
    return false;
  }
  socket.send(text);
  return true;
}

function isApiAuthorized(request) {
  return Boolean(apiToken) && request.headers.authorization === `Bearer ${apiToken}`;
}

function readJson(request) {
  return new Promise((resolve, reject) => {
    let size = 0;
    const chunks = [];
    request.on('data', (chunk) => {
      size += chunk.length;
      if (size > maxHttpBodyBytes) {
        reject(relayError(413, 'request body too large'));
        request.destroy();
        return;
      }
      chunks.push(chunk);
    });
    request.on('end', () => {
      if (size === 0) return resolve({});
      try {
        const value = JSON.parse(Buffer.concat(chunks).toString('utf8'));
        resolve(value && typeof value === 'object' && !Array.isArray(value) ? value : {});
      } catch {
        reject(relayError(400, 'invalid JSON'));
      }
    });
    request.on('error', reject);
  });
}

function sendJson(response, status, value) {
  const body = JSON.stringify(value);
  response.writeHead(status, {
    'Content-Type': 'application/json; charset=utf-8',
    'Content-Length': Buffer.byteLength(body),
    'Cache-Control': 'no-store',
  });
  response.end(body);
}

function loadDevices() {
  if (!existsSync(deviceFile)) return;
  try {
    const raw = JSON.parse(readFileSync(deviceFile, 'utf8'));
    for (const [id, value] of Object.entries(raw)) {
      if (!value || typeof value !== 'object') continue;
      const normalizedId = normalizeId(id, 'device_id', false);
      const tokenHash = typeof value.tokenHash === 'string'
        ? value.tokenHash
        : typeof value.token === 'string'
        ? hashToken(normalizedId, value.token)
        : null;
      if (!normalizedId || !tokenHash || typeof value.name !== 'string') continue;
      devices.set(normalizedId, {
        name: value.name,
        tokenHash,
        agentVersion: value.agentVersion ?? null,
        protocolVersion: value.protocolVersion ?? null,
        lastSeen: null,
        capabilities: value.capabilities ?? null,
      });
    }
  } catch (error) {
    console.error(`cannot load ${deviceFile}: ${error.message}`);
  }
}

function saveDevices() {
  const value = Object.fromEntries(
    [...devices.entries()].map(([id, device]) => [id, {
      name: device.name,
      tokenHash: device.tokenHash,
      agentVersion: device.agentVersion,
      protocolVersion: device.protocolVersion,
      capabilities: device.capabilities,
    }]),
  );
  writeFileSync(deviceFile, JSON.stringify(value, null, 2), { mode: 0o600 });
}

function hashToken(deviceId, token) {
  return createHash('sha256').update(`device:v1:${deviceId}:${token}`).digest('hex');
}

function safeEqual(left, right) {
  if (typeof left !== 'string' || typeof right !== 'string') return false;
  const a = Buffer.from(left);
  const b = Buffer.from(right);
  return a.length === b.length && timingSafeEqual(a, b);
}

function normalizeId(value, label, throwOnError = true) {
  const id = String(value ?? '');
  if (/^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/.test(id)) return id;
  if (!throwOnError) return '';
  throw relayError(400, `${label} is invalid`);
}

function boundedText(value, label, min, max) {
  if (typeof value !== 'string' || value.length < min || value.length > max || /[\u0000\u0001-\u001f\u007f]/.test(value)) {
    throw relayError(400, `${label} is invalid`);
  }
  return value;
}

function safeError(value) {
  const message = typeof value === 'string'
    ? value
    : value && typeof value.message === 'string'
    ? value.message
    : 'Windows Agent 调用失败';
  return message.replace(/[\u0000-\u001f\u007f]/g, ' ').slice(0, 300) || 'Windows Agent 调用失败';
}

function publicRequest(value) {
  return {
    request_id: value.id,
    device_id: value.deviceId,
    operation: value.operation,
    status: value.status,
    result: value.result,
    error: value.error,
  };
}

function rejectUpgrade(socket, status, message) {
  const body = `${message}\n`;
  socket.write(
    `HTTP/1.1 ${status} ${message}\r\nContent-Type: text/plain\r\nContent-Length: ${Buffer.byteLength(body)}\r\nConnection: close\r\n\r\n${body}`,
  );
  socket.destroy();
}

function relayError(statusCode, message) {
  return Object.assign(new Error(message), { statusCode });
}

process.on('SIGTERM', () => server.close(() => process.exit(0)));
process.on('SIGINT', () => server.close(() => process.exit(0)));
