import assert from 'node:assert/strict';
import test from 'node:test';

import { ComputerAgent } from '../agent.mjs';

test('unexpected call completion error closes the socket instead of escaping', async () => {
  const agent = new ComputerAgent({
    connection_mode: 'direct',
    direct_listen_host: '127.0.0.1',
    direct_listen_port: 8788,
    device_id: 'call-error-test',
    device_token: 'direct-device-token-123456',
    working_directory: process.cwd(),
  });
  agent.authenticated = true;
  agent.rememberCompleted = () => {
    throw new Error('simulated completion failure');
  };
  var closed = false;
  const socket = {
    readyState: 1,
    close() {
      closed = true;
    },
  };

  await agent.handleFrame(
    socket,
    JSON.stringify({
      type: 'call',
      request_id: 'call-error-1',
      operation: 'unsupported',
      payload: {},
    }),
    () => {},
  );
  await new Promise((resolve) => setImmediate(resolve));

  assert.equal(closed, true);
});
