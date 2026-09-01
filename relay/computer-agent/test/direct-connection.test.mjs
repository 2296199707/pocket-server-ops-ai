import assert from 'node:assert/strict';
import fsp from 'node:fs/promises';
import net from 'node:net';
import os from 'node:os';
import path from 'node:path';
import test from 'node:test';
import { WebSocket } from 'ws';

import { ComputerAgent } from '../agent.mjs';

test('direct mode authenticates the phone and executes an RPC', async () => {
  const workingDirectory = await fsp.mkdtemp(
    path.join(os.tmpdir(), 'pocket-server-ops-direct-'),
  );
  const port = await availablePort();
  const token = 'direct-device-token-123456';
  const agent = new ComputerAgent({
    connection_mode: 'direct',
    direct_listen_host: '127.0.0.1',
    direct_listen_port: port,
    device_id: 'windows-direct-test',
    device_token: token,
    working_directory: workingDirectory,
  });
  const running = agent.start();

  try {
    await waitForHealth(port);
    const unauthorized = await fetch(
      `http://127.0.0.1:${port}/v1/devices/windows-direct-test/status`,
    );
    assert.equal(unauthorized.status, 401);

    const statusResponse = await fetch(
      `http://127.0.0.1:${port}/v1/devices/windows-direct-test/status`,
      { headers: { authorization: `Bearer ${token}` } },
    );
    assert.equal(statusResponse.status, 200);
    assert.equal((await statusResponse.json()).online, true);

    const socket = new WebSocket(
      `ws://127.0.0.1:${port}/v1/devices/windows-direct-test/ws`,
      { headers: { authorization: `Bearer ${token}` } },
    );
    await once(socket, 'open');
    const authenticated = nextFrame(socket);
    socket.send(JSON.stringify({
      type: 'hello',
      device_id: 'windows-direct-test',
      pending_request_ids: [],
    }));
    assert.equal((await authenticated).type, 'authenticated');

    const result = nextFrame(socket);
    socket.send(JSON.stringify({
      type: 'request',
      request_id: 'request-direct-status',
      operation: 'status',
      payload: {},
    }));
    const frame = await result;
    assert.equal(frame.type, 'result');
    assert.equal(frame.request_id, 'request-direct-status');
    assert.equal(frame.ok, true);
    assert.equal(frame.result.device_id, 'windows-direct-test');
    socket.close();
  } finally {
    await agent.stop();
    await running;
    await fsp.rm(workingDirectory, { recursive: true, force: true });
  }
});

async function availablePort() {
  const server = net.createServer();
  await new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(0, '127.0.0.1', resolve);
  });
  const address = server.address();
  await new Promise((resolve) => server.close(resolve));
  return address.port;
}

async function waitForHealth(port) {
  for (let attempt = 0; attempt < 20; attempt += 1) {
    try {
      const response = await fetch(`http://127.0.0.1:${port}/v1/health`);
      if (response.ok) return;
    } catch {}
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  throw new Error('direct health endpoint did not start');
}

function once(emitter, event) {
  return new Promise((resolve, reject) => {
    emitter.once(event, resolve);
    emitter.once('error', reject);
  });
}

function nextFrame(socket) {
  return new Promise((resolve, reject) => {
    socket.once('message', (data) => {
      try {
        resolve(JSON.parse(data.toString('utf8')));
      } catch (error) {
        reject(error);
      }
    });
    socket.once('error', reject);
  });
}
