import { randomUUID } from 'node:crypto';
import { EventEmitter } from 'node:events';
import { fileURLToPath } from 'node:url';
import fsp from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { spawn } from 'node:child_process';

const AGENT_VERSION = '1.0.0-beta.1';
const PROTOCOL_VERSION = '1';
const DEFAULT_CONFIG_NAME = 'config.json';

const MAX_COMMAND_BYTES = 1024 * 1024;
const MAX_INPUT_BYTES = 1024 * 1024;
const MAX_EXEC_OUTPUT_BYTES = 2 * 1024 * 1024;
const MAX_PROCESS_OUTPUT_BYTES = 16 * 1024 * 1024;
const MAX_POLL_BYTES = 256 * 1024;
const MAX_FILE_READ_BYTES = 1024 * 1024;
const MAX_FILE_WRITE_BYTES = 8 * 1024 * 1024;
const MAX_REPLACE_FILE_BYTES = 16 * 1024 * 1024;
const MAX_COMPLETED_CALLS = 128;
const MAX_COMPLETED_RESULT_BYTES = 8 * 1024 * 1024;
const MAX_COMPLETED_CACHE_BYTES = 32 * 1024 * 1024;
const MAX_TRACKED_PROCESSES = 64;
const DEFAULT_EXEC_TIMEOUT_MS = 2 * 60 * 1000;
const MAX_EXEC_TIMEOUT_MS = 10 * 60 * 1000;
const DEFAULT_HEARTBEAT_INTERVAL_MS = 30_000;
const MAX_HEARTBEAT_INTERVAL_MS = 5 * 60 * 1000;
const AGENT_OPERATIONS = [
  'exec',
  'process.start',
  'process.poll',
  'process.write',
  'process.stop',
  'file.read',
  'file.write',
  'file.replace',
  'status',
];

class AgentError extends Error {
  constructor(code, message, details) {
    super(message);
    this.name = 'AgentError';
    this.code = code;
    this.details = details;
  }
}

class CancelledError extends AgentError {
  constructor() {
    super('cancelled', '调用已取消');
    this.name = 'CancelledError';
  }
}

class CallContext {
  constructor(requestId) {
    this.requestId = requestId;
    this.cancelled = false;
    this.handlers = new Set();
  }

  onCancel(handler) {
    if (this.cancelled) {
      handler();
      return () => {};
    }
    this.handlers.add(handler);
    return () => this.handlers.delete(handler);
  }

  cancel() {
    if (this.cancelled) return;
    this.cancelled = true;
    for (const handler of this.handlers) {
      try {
        handler();
      } catch (error) {
        log('warn', `取消调用 ${this.requestId} 时发生错误`, error);
      }
    }
    this.handlers.clear();
  }

  throwIfCancelled() {
    if (this.cancelled) throw new CancelledError();
  }
}

class TrackedProcess extends EventEmitter {
  constructor({ processId, child, command, workingDirectory, stdoutPath, stderrPath }) {
    super();
    this.processId = processId;
    this.child = child;
    this.pid = child.pid ?? null;
    this.command = command;
    this.workingDirectory = workingDirectory;
    this.stdoutPath = stdoutPath;
    this.stderrPath = stderrPath;
    this.startedAt = new Date().toISOString();
    this.stdoutBytes = 0;
    this.stderrBytes = 0;
    this.stdoutStoredBytes = 0;
    this.stderrStoredBytes = 0;
    this.stdoutTruncated = false;
    this.stderrTruncated = false;
    this.stdoutWrites = Promise.resolve();
    this.stderrWrites = Promise.resolve();
    this.version = 0;
    this.running = true;
    this.exitCode = null;
    this.signal = null;
    this.error = null;
    this.cancelled = false;
    this._closePromise = new Promise((resolve) => {
      this._resolveClose = resolve;
    });
  }

  notify() {
    this.version += 1;
    this.emit('update');
  }

  append(channel, chunk) {
    const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    const isStdout = channel === 'stdout';
    const cap = MAX_PROCESS_OUTPUT_BYTES;
    const totalKey = isStdout ? 'stdoutBytes' : 'stderrBytes';
    const storedKey = isStdout ? 'stdoutStoredBytes' : 'stderrStoredBytes';
    const truncatedKey = isStdout ? 'stdoutTruncated' : 'stderrTruncated';
    const writesKey = isStdout ? 'stdoutWrites' : 'stderrWrites';
    const filePath = isStdout ? this.stdoutPath : this.stderrPath;

    this[totalKey] += buffer.length;
    const remaining = cap - this[storedKey];
    if (remaining > 0) {
      const slice = buffer.subarray(0, remaining);
      this[storedKey] += slice.length;
      this[writesKey] = this[writesKey]
        .then(() => fsp.appendFile(filePath, slice))
        .catch((error) => {
          this.error = this.error ?? error;
        });
    }
    if (buffer.length > remaining) this[truncatedKey] = true;
    this.notify();
  }

  async flush() {
    await Promise.all([this.stdoutWrites, this.stderrWrites]);
  }

  markClosed(code, signal, error = null) {
    this.running = false;
    this.exitCode = typeof code === 'number' ? code : null;
    this.signal = signal ?? null;
    this.error = this.error ?? error;
    this.notify();
    this._resolveClose();
  }

  async waitForClose(timeoutMs = 5_000) {
    if (!this.running) return;
    await Promise.race([
      this._closePromise,
      new Promise((resolve) => setTimeout(resolve, timeoutMs)),
    ]);
  }
}

class ComputerAgent {
  constructor(config) {
    this.config = config;
    this.websocketUrl = normalizeWebSocketUrl(config.relay_url);
    this.deviceId = config.device_id;
    this.deviceToken = config.device_token;
    this.agentVersion = config.agent_version || AGENT_VERSION;
    this.workingDirectory = path.resolve(config.working_directory);
    this.outputDirectory = path.join(
      os.tmpdir(),
      'pocket-server-ops-agent',
      `${sanitizeFileName(this.deviceId)}-${randomUUID()}`,
    );
    this.socket = null;
    this.authenticated = false;
    this.stopping = false;
    this.heartbeatTimer = null;
    this.heartbeatIntervalMs = DEFAULT_HEARTBEAT_INTERVAL_MS;
    this.missedHeartbeats = 0;
    this.processes = new Map();
    this.inFlightCalls = new Map();
    this.inFlightSockets = new Map();
    this.completedCalls = new Map();
    this.completedRequestIds = new Set();
    this.completedCallBytes = 0;
    this.reconnectDelayMs = 1_000;
  }

  async start() {
    await ensureDirectory(this.workingDirectory);
    await fsp.mkdir(this.outputDirectory, { recursive: true });
    log('info', `PocketServerOps Windows Agent ${this.agentVersion} 启动`);
    log('info', `工作目录: ${this.workingDirectory}`);
    await this.runConnectionLoop();
  }

  async stop() {
    if (this.stopping) return;
    this.stopping = true;
    this.clearHeartbeat();
    for (const context of this.inFlightCalls.values()) context.cancel();
    for (const process of this.processes.values()) {
      if (process.running) {
        await terminateProcess(process);
        await process.waitForClose();
      }
    }
    if (this.socket && this.socket.readyState === WebSocket.OPEN) {
      this.socket.close(1000, 'agent stopping');
    }
    await fsp.rm(this.outputDirectory, { recursive: true, force: true });
  }

  async runConnectionLoop() {
    while (!this.stopping) {
      try {
        await this.connectOnce();
      } catch (error) {
        if (this.stopping) break;
        log('warn', `中转连接断开: ${error.message}`);
      }
      if (this.stopping) break;
      const delay = this.reconnectDelayMs;
      log('info', `${delay}ms 后重连`);
      await sleep(delay);
      this.reconnectDelayMs = Math.min(this.reconnectDelayMs * 2, 30_000);
    }
  }

  connectOnce() {
    if (typeof WebSocket !== 'function') {
      throw new AgentError('node_version', '当前 Node.js 没有全局 WebSocket，请使用 Node.js 22');
    }

    return new Promise((resolve, reject) => {
      const socket = new WebSocket(this.websocketUrl);
      let authenticated = false;
      let authenticatedAt = 0;
      let settled = false;
      let handshakeTimer = null;
      this.socket = socket;
      this.authenticated = false;
      this.missedHeartbeats = 0;

      const finish = (error = null) => {
        if (settled) return;
        settled = true;
        if (handshakeTimer) clearTimeout(handshakeTimer);
        this.clearHeartbeat();
        if (authenticated && Date.now() - authenticatedAt >= 30_000) {
          this.reconnectDelayMs = 1_000;
        }
        if (this.socket === socket) {
          this.socket = null;
          this.authenticated = false;
        }
        if (error) reject(error);
        else resolve();
      };

      socket.addEventListener('open', () => {
        try {
          // This is deliberately the first frame sent on the device socket.
          socket.send(JSON.stringify({
            type: 'authenticate',
            device_id: this.deviceId,
            device_token: this.deviceToken,
            agent_version: this.agentVersion,
            protocol_version: PROTOCOL_VERSION,
          }));
          handshakeTimer = setTimeout(() => {
            socket.close(4000, 'authentication timeout');
            finish(new AgentError('auth_timeout', '认证响应超时'));
          }, 15_000);
        } catch (error) {
          finish(error);
        }
      });

      socket.addEventListener('message', (event) => {
        void this.handleFrame(socket, event.data, () => {
          authenticated = true;
          authenticatedAt = Date.now();
          this.authenticated = true;
          if (handshakeTimer) clearTimeout(handshakeTimer);
          this.startHeartbeat(socket);
          this.sendFrameIfOpen(socket, {
            type: 'capabilities',
            device_id: this.deviceId,
            capabilities: {
              operations: AGENT_OPERATIONS,
              platform: process.platform,
              agent_version: this.agentVersion,
            },
          });
          log('info', `设备 ${this.deviceId} 已认证`);
        }).catch((error) => {
          log('warn', `处理 relay 帧失败: ${error.message}`);
          if (socket.readyState === WebSocket.OPEN) socket.close(4002, 'invalid frame');
        });
      });

      socket.addEventListener('error', () => {
        if (!authenticated) finish(new AgentError('connection_error', 'WebSocket 连接失败'));
      });
      socket.addEventListener('close', (event) => {
        const reason = event.reason ? `: ${event.reason}` : '';
        finish(new AgentError('connection_closed', `WebSocket 已关闭 (${event.code})${reason}`));
      });
    });
  }

  startHeartbeat(socket) {
    this.clearHeartbeat();
    const interval = clampInteger(
      this.heartbeatIntervalMs,
      5_000,
      MAX_HEARTBEAT_INTERVAL_MS,
    );
    this.heartbeatIntervalMs = interval;
    const sendHeartbeat = () => {
      if (socket.readyState !== WebSocket.OPEN || !this.authenticated) return;
      this.missedHeartbeats += 1;
      if (this.missedHeartbeats > 2) {
        socket.close(4001, 'heartbeat timeout');
        return;
      }
      this.sendFrameIfOpen(socket, { type: 'heartbeat', device_id: this.deviceId });
    };
    this.heartbeatTimer = setInterval(sendHeartbeat, interval);
  }

  clearHeartbeat() {
    if (this.heartbeatTimer) clearInterval(this.heartbeatTimer);
    this.heartbeatTimer = null;
  }

  async handleFrame(socket, rawData, onAuthenticated) {
    const text = await websocketDataToText(rawData);
    let frame;
    try {
      frame = JSON.parse(text);
    } catch {
      throw new AgentError('invalid_json', 'relay 返回了无效 JSON');
    }
    if (!frame || typeof frame !== 'object' || typeof frame.type !== 'string') {
      throw new AgentError('invalid_frame', 'relay 帧缺少 type');
    }

    switch (frame.type) {
      case 'authenticated':
        if (frame.device_id !== this.deviceId) {
          throw new AgentError('auth_device_mismatch', '认证设备 ID 不匹配');
        }
        this.heartbeatIntervalMs = numberOrDefault(
          frame.heartbeat_interval_ms,
          DEFAULT_HEARTBEAT_INTERVAL_MS,
        );
        onAuthenticated();
        return;
      case 'heartbeat_ack':
        this.missedHeartbeats = 0;
        return;
      case 'call':
        if (!this.authenticated) throw new AgentError('not_authenticated', '未认证时收到调用');
        void this.handleCall(socket, frame);
        return;
      case 'cancel':
        if (!this.authenticated) throw new AgentError('not_authenticated', '未认证时收到取消');
        this.handleCancel(frame);
        return;
      default:
        log('warn', `忽略未知 relay 帧: ${frame.type}`);
    }
  }

  handleCancel(frame) {
    if (typeof frame.request_id !== 'string' || frame.request_id.length === 0) return;
    const context = this.inFlightCalls.get(frame.request_id);
    if (context) context.cancel();
  }

  async handleCall(socket, frame) {
    const requestId = typeof frame.request_id === 'string' ? frame.request_id : '';
    if (!requestId) return;
    const operation = typeof frame.operation === 'string' ? frame.operation : '';
    const payload = frame.payload && typeof frame.payload === 'object' ? frame.payload : {};

    const completed = this.completedCalls.get(requestId);
    if (completed) {
      this.sendFrameIfOpen(socket, completed.frame);
      return;
    }
    if (this.completedRequestIds.has(requestId)) {
      this.sendFrameIfOpen(socket, {
        type: 'result',
        request_id: requestId,
        ok: false,
        error: {
          code: 'result_unavailable',
          message: '该请求已经执行过，但结果已不在 Agent 缓存中；为避免重复执行，未重放命令',
        },
      });
      return;
    }
    if (this.inFlightCalls.has(requestId)) {
      this.inFlightSockets.get(requestId)?.add(socket);
      return;
    }

    const context = new CallContext(requestId);
    this.inFlightCalls.set(requestId, context);
    this.inFlightSockets.set(requestId, new Set([socket]));
    let resultFrame;
    try {
      const result = await this.dispatch(operation, payload, context);
      resultFrame = { type: 'result', request_id: requestId, ok: true, result };
    } catch (error) {
      resultFrame = {
        type: 'result',
        request_id: requestId,
        ok: false,
        error: serializeError(error),
      };
    } finally {
      this.inFlightCalls.delete(requestId);
    }

    this.rememberCompleted(requestId, resultFrame);
    const sockets = this.inFlightSockets.get(requestId) ?? new Set([socket]);
    this.inFlightSockets.delete(requestId);
    for (const target of sockets) this.sendFrameIfOpen(target, resultFrame);
  }

  async dispatch(operation, payload, context) {
    switch (operation) {
      case 'exec':
        return this.exec(payload, context);
      case 'process.start':
        return this.startProcess(payload, context);
      case 'process.poll':
        return this.pollProcess(payload, context);
      case 'process.write':
        return this.writeProcess(payload, context);
      case 'process.stop':
        return this.stopProcess(payload, context);
      case 'file.read':
        return this.readFile(payload, context);
      case 'file.write':
        return this.writeFile(payload, context);
      case 'file.replace':
        return this.replaceFile(payload, context);
      case 'status':
        return this.status(context);
      default:
        throw new AgentError('unsupported_operation', `不支持的操作: ${operation}`);
    }
  }

  async exec(payload, context) {
    const command = requiredString(payload.command, 'command');
    ensureByteLimit(command, MAX_COMMAND_BYTES, 'command');
    const workingDirectory = await this.resolveWorkingDirectory(payload.working_directory);
    const input = optionalString(payload.input, 'input');
    if (input !== undefined) ensureByteLimit(input, MAX_INPUT_BYTES, 'input');
    const timeoutMs = clampInteger(
      numberOrDefault(payload.timeout_ms, DEFAULT_EXEC_TIMEOUT_MS),
      1_000,
      MAX_EXEC_TIMEOUT_MS,
    );

    const result = await runPowerShell(command, {
      workingDirectory,
      input,
      timeoutMs,
      context,
    });
    return {
      exit_code: result.exitCode,
      signal: result.signal,
      timed_out: result.timedOut,
      stdout: result.stdout.toString('utf8'),
      stderr: result.stderr.toString('utf8'),
      stdout_bytes: result.stdoutBytes,
      stderr_bytes: result.stderrBytes,
      stdout_stored_bytes: result.stdout.length,
      stderr_stored_bytes: result.stderr.length,
      stdout_offset: 0,
      stderr_offset: 0,
      stdout_next_offset: result.stdout.length,
      stderr_next_offset: result.stderr.length,
      stdout_truncated: result.stdoutTruncated,
      stderr_truncated: result.stderrTruncated,
    };
  }

  async startProcess(payload, context) {
    context.throwIfCancelled();
    const command = requiredString(payload.command, 'command');
    ensureByteLimit(command, MAX_COMMAND_BYTES, 'command');
    const workingDirectory = await this.resolveWorkingDirectory(payload.working_directory);
    const activeCount = [...this.processes.values()].filter((process) => process.running).length;
    if (activeCount >= 32) throw new AgentError('process_limit', '运行中的后台进程已达到 32 个');

    await fsp.mkdir(this.outputDirectory, { recursive: true });
    const processId = `process-${randomUUID()}`;
    const stdoutPath = path.join(this.outputDirectory, `${processId}.stdout`);
    const stderrPath = path.join(this.outputDirectory, `${processId}.stderr`);
    await fsp.writeFile(stdoutPath, '');
    await fsp.writeFile(stderrPath, '');
    const child = spawnPowerShell(command, workingDirectory, true);
    const tracked = new TrackedProcess({
      processId,
      child,
      command,
      workingDirectory,
      stdoutPath,
      stderrPath,
    });
    this.processes.set(processId, tracked);
    this.trimProcessRegistry();
    attachProcessOutput(tracked, child.stdout, 'stdout');
    attachProcessOutput(tracked, child.stderr, 'stderr');
    child.once('error', (error) => tracked.markClosed(null, null, error));
    child.once('close', (code, signal) => tracked.markClosed(code, signal));
    context.onCancel(() => {
      tracked.cancelled = true;
    });

    return {
      process_id: processId,
      pid: tracked.pid,
      running: tracked.running,
      command,
      working_directory: workingDirectory,
      pty: false,
      stdout_offset: 0,
      stderr_offset: 0,
    };
  }

  async pollProcess(payload, context) {
    context.throwIfCancelled();
    const tracked = this.getProcess(payload.process_id);
    const stdoutOffset = nonNegativeInteger(payload.stdout_offset, 0);
    const stderrOffset = nonNegativeInteger(payload.stderr_offset, 0);
    const waitMs = clampInteger(numberOrDefault(payload.wait_ms, 0), 0, 10_000);

    await tracked.flush();
    let output = await readProcessOutput(tracked, stdoutOffset, stderrOffset);
    if (waitMs > 0 && tracked.running && output.stdout.length === 0 && output.stderr.length === 0) {
      const version = tracked.version;
      await waitForProcessUpdate(tracked, version, waitMs, context);
      await tracked.flush();
      output = await readProcessOutput(tracked, stdoutOffset, stderrOffset);
    }
    context.throwIfCancelled();
    return {
      process_id: tracked.processId,
      pid: tracked.pid,
      running: tracked.running,
      exit_code: tracked.exitCode,
      signal: tracked.signal,
      error: tracked.error ? String(tracked.error.message ?? tracked.error) : null,
      started_at: tracked.startedAt,
      working_directory: tracked.workingDirectory,
      stdout: output.stdout.toString('utf8'),
      stderr: output.stderr.toString('utf8'),
      stdout_offset: stdoutOffset,
      stderr_offset: stderrOffset,
      stdout_next_offset: output.stdoutNextOffset,
      stderr_next_offset: output.stderrNextOffset,
      stdout_bytes: tracked.stdoutBytes,
      stderr_bytes: tracked.stderrBytes,
      stdout_truncated: tracked.stdoutTruncated,
      stderr_truncated: tracked.stderrTruncated,
    };
  }

  async writeProcess(payload, context) {
    context.throwIfCancelled();
    const tracked = this.getProcess(payload.process_id);
    const input = requiredString(payload.input, 'input');
    ensureByteLimit(input, MAX_INPUT_BYTES, 'input');
    if (!tracked.running || !tracked.child.stdin || tracked.child.stdin.destroyed) {
      throw new AgentError('process_not_running', '后台进程没有可写入的 stdin');
    }
    await new Promise((resolve, reject) => {
      tracked.child.stdin.write(input, 'utf8', (error) => (error ? reject(error) : resolve()));
    });
    return { process_id: tracked.processId, bytes_written: Buffer.byteLength(input, 'utf8') };
  }

  async stopProcess(payload, context) {
    context.throwIfCancelled();
    const tracked = this.getProcess(payload.process_id);
    if (tracked.running) {
      await terminateProcess(tracked);
      await tracked.waitForClose();
    }
    await tracked.flush();
    return {
      process_id: tracked.processId,
      pid: tracked.pid,
      running: tracked.running,
      exit_code: tracked.exitCode,
      signal: tracked.signal,
      stopped: true,
    };
  }

  async readFile(payload, context) {
    context.throwIfCancelled();
    const filePath = await this.resolveFilePath(payload.path);
    const stat = await fsp.stat(filePath);
    if (!stat.isFile()) throw new AgentError('not_a_file', '目标路径不是文件');
    const offset = nonNegativeInteger(payload.offset, 0);
    if (offset > stat.size) throw new AgentError('invalid_offset', '文件偏移超过文件大小');
    const length = clampInteger(
      numberOrDefault(payload.length, MAX_FILE_READ_BYTES),
      1,
      MAX_FILE_READ_BYTES,
    );
    const bytesToRead = Math.min(length, stat.size - offset);
    const data = Buffer.alloc(bytesToRead);
    const handle = await fsp.open(filePath, 'r');
    try {
      const read = await handle.read(data, 0, bytesToRead, offset);
      const actual = data.subarray(0, read.bytesRead);
      const encoding = payload.encoding === 'base64' ? 'base64' : 'utf8';
      return {
        path: filePath,
        offset,
        length: actual.length,
        next_offset: offset + actual.length,
        total_bytes: stat.size,
        eof: offset + actual.length >= stat.size,
        encoding,
        content: encoding === 'base64' ? undefined : actual.toString('utf8'),
        content_base64: encoding === 'base64' ? actual.toString('base64') : undefined,
      };
    } finally {
      await handle.close();
    }
  }

  async writeFile(payload, context) {
    context.throwIfCancelled();
    const filePath = await this.resolveFilePath(payload.path);
    const data = decodeFileContent(payload);
    if (data.length > MAX_FILE_WRITE_BYTES) {
      throw new AgentError('file_too_large', `写入内容不能超过 ${MAX_FILE_WRITE_BYTES} 字节`);
    }
    const offsetProvided = payload.offset !== undefined;
    const offset = nonNegativeInteger(payload.offset, 0);
    const truncate = payload.truncate === undefined ? !offsetProvided || offset === 0 : payload.truncate === true;
    await fsp.mkdir(path.dirname(filePath), { recursive: true });
    if (offset === 0 && truncate) {
      await fsp.writeFile(filePath, data);
    } else {
      let handle;
      try {
        handle = await fsp.open(filePath, 'r+');
      } catch (error) {
        if (error.code !== 'ENOENT' || offset !== 0) throw error;
        handle = await fsp.open(filePath, 'w+');
      }
      try {
        if (truncate) await handle.truncate(0);
        await writeBufferAt(handle, data, offset);
      } finally {
        await handle.close();
      }
    }
    const stat = await fsp.stat(filePath);
    return {
      path: filePath,
      offset,
      bytes_written: data.length,
      next_offset: offset + data.length,
      total_bytes: stat.size,
    };
  }

  async replaceFile(payload, context) {
    context.throwIfCancelled();
    const filePath = await this.resolveFilePath(payload.path);
    const oldText = requiredString(payload.old, 'old');
    const newText = requiredString(payload.new, 'new', true);
    const stat = await fsp.stat(filePath);
    if (stat.size > MAX_REPLACE_FILE_BYTES) {
      throw new AgentError('file_too_large', `替换文件不能超过 ${MAX_REPLACE_FILE_BYTES} 字节`);
    }
    const current = await fsp.readFile(filePath, 'utf8');
    const first = current.indexOf(oldText);
    if (first < 0) throw new AgentError('text_not_found', '文件中没有找到 old 文本');
    if (current.indexOf(oldText, first + oldText.length) >= 0) {
      throw new AgentError('text_not_unique', 'old 文本出现多次，拒绝不确定替换');
    }
    const updated = `${current.slice(0, first)}${newText}${current.slice(first + oldText.length)}`;
    ensureByteLimit(updated, MAX_REPLACE_FILE_BYTES, '替换后的文件');
    await fsp.writeFile(filePath, updated, 'utf8');
    return {
      path: filePath,
      replaced: 1,
      old_bytes: Buffer.byteLength(oldText, 'utf8'),
      new_bytes: Buffer.byteLength(newText, 'utf8'),
      total_bytes: Buffer.byteLength(updated, 'utf8'),
    };
  }

  async status(context) {
    context.throwIfCancelled();
    const cpu = await sampleCpuUsage();
    context.throwIfCancelled();
    const disks = await queryWindowsDisks(context);
    const totalMemory = os.totalmem();
    const freeMemory = os.freemem();
    return {
      agent_version: this.agentVersion,
      protocol_version: PROTOCOL_VERSION,
      device_id: this.deviceId,
      hostname: os.hostname(),
      platform: process.platform,
      arch: process.arch,
      os_release: os.release(),
      node_version: process.version,
      working_directory: this.workingDirectory,
      cpu,
      memory: {
        total_bytes: totalMemory,
        free_bytes: freeMemory,
        used_bytes: totalMemory - freeMemory,
        usage_percent: percent(totalMemory - freeMemory, totalMemory),
      },
      disks,
      processes: {
        active: [...this.processes.values()].filter((process) => process.running).length,
        tracked: this.processes.size,
      },
    };
  }

  async resolveWorkingDirectory(value) {
    const candidate = typeof value === 'string' && value.trim().length > 0
      ? value.trim()
      : this.workingDirectory;
    const directory = path.isAbsolute(candidate)
      ? path.resolve(candidate)
      : path.resolve(this.workingDirectory, candidate);
    await ensureDirectory(directory);
    return directory;
  }

  async resolveFilePath(value) {
    const input = requiredString(value, 'path');
    const filePath = path.isAbsolute(input)
      ? path.normalize(input)
      : path.resolve(this.workingDirectory, input);
    return filePath;
  }

  getProcess(processId) {
    if (typeof processId !== 'string' || processId.length === 0) {
      throw new AgentError('invalid_process_id', 'process_id 无效');
    }
    const tracked = this.processes.get(processId);
    if (!tracked) throw new AgentError('process_not_found', `找不到后台进程: ${processId}`);
    return tracked;
  }

  trimProcessRegistry() {
    while (this.processes.size > MAX_TRACKED_PROCESSES) {
      const first = this.processes.entries().next().value;
      if (!first) return;
      const [processId, tracked] = first;
      if (tracked.running) return;
      this.processes.delete(processId);
      void Promise.all([
        fsp.rm(tracked.stdoutPath, { force: true }),
        fsp.rm(tracked.stderrPath, { force: true }),
      ]).catch(() => {});
    }
  }

  rememberCompleted(requestId, resultFrame) {
    const bytes = Buffer.byteLength(JSON.stringify(resultFrame), 'utf8');
    this.completedRequestIds.delete(requestId);
    this.completedRequestIds.add(requestId);
    const previous = this.completedCalls.get(requestId);
    if (previous) this.completedCallBytes -= previous.bytes;
    this.completedCalls.delete(requestId);
    if (bytes <= MAX_COMPLETED_RESULT_BYTES) {
      this.completedCalls.set(requestId, { frame: resultFrame, bytes });
      this.completedCallBytes += bytes;
    }
    while (this.completedCallBytes > MAX_COMPLETED_CACHE_BYTES) {
      const first = this.completedCalls.entries().next().value;
      if (!first) break;
      const [oldRequestId, cached] = first;
      this.completedCalls.delete(oldRequestId);
      this.completedCallBytes -= cached.bytes;
    }
    while (this.completedRequestIds.size > MAX_COMPLETED_CALLS) {
      const oldRequestId = this.completedRequestIds.values().next().value;
      if (!oldRequestId) break;
      this.completedRequestIds.delete(oldRequestId);
      const cached = this.completedCalls.get(oldRequestId);
      if (cached) {
        this.completedCalls.delete(oldRequestId);
        this.completedCallBytes -= cached.bytes;
      }
    }
  }

  sendFrame(socket, frame) {
    socket.send(JSON.stringify(frame));
  }

  sendFrameIfOpen(socket, frame) {
    if (socket.readyState !== WebSocket.OPEN) return false;
    try {
      this.sendFrame(socket, frame);
      return true;
    } catch (error) {
      log('warn', '发送 relay 帧失败', error);
      return false;
    }
  }
}

function attachProcessOutput(tracked, stream, channel) {
  if (!stream) return;
  stream.on('data', (chunk) => tracked.append(channel, chunk));
  stream.on('error', (error) => {
    tracked.error = tracked.error ?? error;
    tracked.notify();
  });
}

async function readProcessOutput(tracked, stdoutOffset, stderrOffset) {
  const [stdout, stderr] = await Promise.all([
    readOffset(tracked.stdoutPath, stdoutOffset, MAX_POLL_BYTES),
    readOffset(tracked.stderrPath, stderrOffset, MAX_POLL_BYTES),
  ]);
  return {
    stdout: stdout.data,
    stderr: stderr.data,
    stdoutNextOffset: stdout.nextOffset,
    stderrNextOffset: stderr.nextOffset,
  };
}

async function readOffset(filePath, offset, maxBytes) {
  const stat = await fsp.stat(filePath);
  if (offset > stat.size) throw new AgentError('invalid_offset', '输出偏移超过已保存输出大小');
  const length = Math.min(maxBytes, stat.size - offset);
  const buffer = Buffer.alloc(length);
  if (length === 0) return { data: buffer, nextOffset: offset };
  const handle = await fsp.open(filePath, 'r');
  try {
    const read = await handle.read(buffer, 0, length, offset);
    return { data: buffer.subarray(0, read.bytesRead), nextOffset: offset + read.bytesRead };
  } finally {
    await handle.close();
  }
}

function waitForProcessUpdate(tracked, version, waitMs, context) {
  if (tracked.version !== version || !tracked.running) return Promise.resolve();
  return new Promise((resolve, reject) => {
    let finished = false;
    let timer;
    let removeCancel = () => {};
    const finish = (error = null) => {
      if (finished) return;
      finished = true;
      clearTimeout(timer);
      tracked.removeListener('update', onUpdate);
      removeCancel();
      if (error) reject(error);
      else resolve();
    };
    const onUpdate = () => {
      if (tracked.version !== version || !tracked.running) finish();
    };
    timer = setTimeout(finish, waitMs);
    tracked.on('update', onUpdate);
    removeCancel = context.onCancel(() => finish(new CancelledError()));
  });
}

function spawnPowerShell(command, workingDirectory, keepStdinOpen) {
  const script = [
    '$OutputEncoding = New-Object System.Text.UTF8Encoding($false)',
    '[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)',
    command,
  ].join('; ');
  const encodedCommand = Buffer.from(script, 'utf16le').toString('base64');
  const child = spawn(
    'powershell.exe',
    [
      '-NoLogo',
      '-NoProfile',
      '-NonInteractive',
      '-ExecutionPolicy',
      'Bypass',
      '-EncodedCommand',
      encodedCommand,
    ],
    {
      cwd: workingDirectory,
      windowsHide: true,
      stdio: ['pipe', 'pipe', 'pipe'],
    },
  );
  if (!keepStdinOpen) child.stdin?.end();
  return child;
}

async function runPowerShell(command, { workingDirectory, input, timeoutMs, context }) {
  context.throwIfCancelled();
  const child = spawnPowerShell(command, workingDirectory, Boolean(input));
  const stdoutChunks = [];
  const stderrChunks = [];
  let stdoutBytes = 0;
  let stderrBytes = 0;
  let stdoutStoredBytes = 0;
  let stderrStoredBytes = 0;
  let stdoutTruncated = false;
  let stderrTruncated = false;
  let timedOut = false;
  let spawnError = null;

  child.stdout?.on('data', (chunk) => {
    const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    stdoutBytes += buffer.length;
    if (stdoutStoredBytes < MAX_EXEC_OUTPUT_BYTES) {
      const slice = buffer.subarray(0, MAX_EXEC_OUTPUT_BYTES - stdoutStoredBytes);
      stdoutChunks.push(slice);
      stdoutStoredBytes += slice.length;
    }
    if (stdoutBytes > MAX_EXEC_OUTPUT_BYTES) stdoutTruncated = true;
  });
  child.stderr?.on('data', (chunk) => {
    const buffer = Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk);
    stderrBytes += buffer.length;
    if (stderrStoredBytes < MAX_EXEC_OUTPUT_BYTES) {
      const slice = buffer.subarray(0, MAX_EXEC_OUTPUT_BYTES - stderrStoredBytes);
      stderrChunks.push(slice);
      stderrStoredBytes += slice.length;
    }
    if (stderrBytes > MAX_EXEC_OUTPUT_BYTES) stderrTruncated = true;
  });
  child.once('error', (error) => {
    spawnError = error;
  });

  if (input !== undefined) child.stdin?.end(input, 'utf8');
  const terminate = () => {
    void terminateProcess(child);
  };
  const removeCancel = context.onCancel(terminate);
  const timeout = setTimeout(() => {
    timedOut = true;
    terminate();
  }, timeoutMs);
  const close = await new Promise((resolve) => {
    child.once('close', (exitCode, signal) => resolve({ exitCode, signal }));
  });
  clearTimeout(timeout);
  removeCancel();
  if (context.cancelled) throw new CancelledError();
  if (spawnError) throw spawnError;
  return {
    ...close,
    timedOut,
    stdout: Buffer.concat(stdoutChunks),
    stderr: Buffer.concat(stderrChunks),
    stdoutBytes,
    stderrBytes,
    stdoutTruncated,
    stderrTruncated,
  };
}

async function terminateProcess(processOrChild) {
  const child = processOrChild.child ?? processOrChild;
  if (!child || child.exitCode !== null || child.signalCode !== null) return;
  if (process.platform === 'win32' && child.pid) {
    await new Promise((resolve) => {
      const killer = spawn('taskkill.exe', ['/PID', String(child.pid), '/T', '/F'], {
        windowsHide: true,
        stdio: 'ignore',
      });
      killer.once('close', resolve);
      killer.once('error', resolve);
    });
  } else {
    child.kill('SIGTERM');
  }
}

async function sampleCpuUsage() {
  const before = os.cpus().map((cpu) => ({ ...cpu.times }));
  await sleep(100);
  const after = os.cpus().map((cpu) => ({ ...cpu.times }));
  const cores = after.map((times, index) => {
    const previous = before[index] ?? times;
    const total = sumCpuTimes(times) - sumCpuTimes(previous);
    const idle = (times.idle - previous.idle);
    return { index, usage_percent: percent(Math.max(0, total - idle), total) };
  });
  const usage = cores.length === 0
    ? 0
    : cores.reduce((sum, core) => sum + core.usage_percent, 0) / cores.length;
  return { usage_percent: round(usage), cores };
}

async function queryWindowsDisks(context) {
  if (process.platform !== 'win32') return [];
  const command = 'Get-CimInstance Win32_LogicalDisk -Filter "DriveType = 3" | Select-Object DeviceID,Size,FreeSpace,VolumeName | ConvertTo-Json -Compress';
  try {
    const result = await runPowerShell(command, {
      workingDirectory: process.cwd(),
      timeoutMs: 15_000,
      context,
    });
    if (result.exitCode !== 0) return [];
    const parsed = JSON.parse(result.stdout.toString('utf8').trim() || '[]');
    const items = Array.isArray(parsed) ? parsed : [parsed];
    return items.filter(Boolean).map((item) => {
      const total = Number(item.Size) || 0;
      const free = Number(item.FreeSpace) || 0;
      return {
        drive: item.DeviceID ?? '',
        volume_name: item.VolumeName ?? '',
        total_bytes: total,
        free_bytes: free,
        used_bytes: Math.max(0, total - free),
        usage_percent: percent(Math.max(0, total - free), total),
      };
    });
  } catch (error) {
    log('warn', '读取 Windows 磁盘状态失败', error);
    return [];
  }
}

function decodeFileContent(payload) {
  const hasText = typeof payload.content === 'string';
  const hasBase64 = typeof payload.content_base64 === 'string';
  if (hasText === hasBase64) {
    throw new AgentError('invalid_content', 'content 和 content_base64 必须二选一');
  }
  if (hasText) return Buffer.from(payload.content, 'utf8');
  if (Buffer.byteLength(payload.content_base64, 'ascii') > Math.ceil(MAX_FILE_WRITE_BYTES * 4 / 3) + 4) {
    throw new AgentError('file_too_large', `写入内容不能超过 ${MAX_FILE_WRITE_BYTES} 字节`);
  }
  return Buffer.from(payload.content_base64, 'base64');
}

function normalizeWebSocketUrl(value) {
  if (typeof value !== 'string' || value.trim().length === 0) {
    throw new AgentError('invalid_config', 'relay_url 不能为空');
  }
  const url = new URL(value.trim());
  if (url.protocol !== 'wss:') {
    throw new AgentError('invalid_config', 'relay_url 必须使用 wss://');
  }
  const currentPath = url.pathname.replace(/\/+$/, '');
  if (!currentPath.endsWith('/device/ws')) {
    url.pathname = `${currentPath}/device/ws`.replace(/^\/\/+/g, '/');
  }
  return url.toString();
}

async function loadConfig(configPath) {
  const source = await fsp.readFile(configPath, 'utf8');
  let config;
  try {
    config = JSON.parse(source.replace(/^\uFEFF/, ''));
  } catch {
    throw new AgentError('invalid_config', `配置文件不是有效 JSON: ${configPath}`);
  }
  for (const key of ['relay_url', 'device_id', 'device_token', 'working_directory']) {
    if (typeof config[key] !== 'string' || config[key].trim().length === 0) {
      throw new AgentError('invalid_config', `配置缺少 ${key}`);
    }
  }
  return { ...config, agent_version: config.agent_version || AGENT_VERSION };
}

function parseArgs(argv) {
  const args = { config: path.join(path.dirname(fileURLToPath(import.meta.url)), DEFAULT_CONFIG_NAME) };
  for (let index = 0; index < argv.length; index += 1) {
    const value = argv[index];
    if (value === '--config') {
      args.config = argv[++index];
    } else if (value === '--version') {
      args.version = true;
    } else if (value === '--help' || value === '-h') {
      args.help = true;
    } else {
      throw new AgentError('invalid_args', `未知参数: ${value}`);
    }
  }
  return args;
}

function printHelp() {
  console.log('PocketServerOps Windows Agent');
  console.log('用法: node agent.mjs [--config <config.json>]');
  console.log('配置字段: relay_url, device_id, device_token, working_directory');
}

function requiredString(value, name, allowEmpty = false) {
  if (typeof value !== 'string' || (!allowEmpty && value.trim().length === 0)) {
    throw new AgentError('invalid_argument', `${name} 必须是字符串`);
  }
  return value;
}

function optionalString(value, name) {
  if (value === undefined || value === null) return undefined;
  return requiredString(value, name, true);
}

function ensureByteLimit(value, limit, name) {
  if (Buffer.byteLength(value, 'utf8') > limit) {
    throw new AgentError('payload_too_large', `${name} 不能超过 ${limit} 字节`);
  }
}

function decodeInteger(value, fallback) {
  return Number.isSafeInteger(value) ? value : fallback;
}

function nonNegativeInteger(value, fallback) {
  const result = decodeInteger(value, fallback);
  if (result < 0) throw new AgentError('invalid_argument', '偏移量不能为负数');
  return result;
}

function numberOrDefault(value, fallback) {
  return Number.isFinite(value) ? value : fallback;
}

function clampInteger(value, min, max) {
  return Math.min(max, Math.max(min, Math.trunc(value)));
}

function sumCpuTimes(times) {
  return Object.values(times).reduce((sum, value) => sum + value, 0);
}

function percent(value, total) {
  return total > 0 ? round((value / total) * 100) : 0;
}

function round(value) {
  return Math.round(value * 10) / 10;
}

function sanitizeFileName(value) {
  return String(value).replace(/[^a-zA-Z0-9._-]/g, '_').slice(0, 80) || 'device';
}

async function ensureDirectory(directory) {
  const stat = await fsp.stat(directory);
  if (!stat.isDirectory()) throw new AgentError('invalid_directory', `不是目录: ${directory}`);
}

async function writeBufferAt(handle, buffer, offset) {
  let written = 0;
  while (written < buffer.length) {
    const result = await handle.write(buffer, written, buffer.length - written, offset + written);
    written += result.bytesWritten;
  }
}

async function websocketDataToText(data) {
  if (typeof data === 'string') return data;
  if (data instanceof ArrayBuffer) return Buffer.from(data).toString('utf8');
  if (ArrayBuffer.isView(data)) return Buffer.from(data.buffer, data.byteOffset, data.byteLength).toString('utf8');
  return String(data);
}

function serializeError(error) {
  if (error instanceof AgentError) {
    return {
      code: error.code,
      message: error.message,
      ...(error.details === undefined ? {} : { details: error.details }),
    };
  }
  return { code: 'agent_error', message: error?.message ? String(error.message) : String(error) };
}

function sleep(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

function log(level, message, error) {
  const suffix = error ? `: ${error.message ?? error}` : '';
  console[level === 'warn' ? 'warn' : 'log'](`[${new Date().toISOString()}] [${level}] ${message}${suffix}`);
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) {
    printHelp();
    return;
  }
  if (args.version) {
    console.log(AGENT_VERSION);
    return;
  }
  const config = await loadConfig(path.resolve(args.config));
  const agent = new ComputerAgent(config);
  const stop = () => {
    void agent.stop();
  };
  process.once('SIGINT', stop);
  process.once('SIGTERM', stop);
  await agent.start();
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    log('error', error.message ?? String(error), error);
    process.exitCode = 1;
  });
}
