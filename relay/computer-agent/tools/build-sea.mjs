import { copyFile, mkdir, readFile, writeFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const agentDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const distDir = path.join(agentDir, 'dist');
const bundlePath = path.join(distDir, 'agent.cjs');
const seaConfigPath = path.join(distDir, 'sea-config.json');
const blobPath = path.join(distDir, 'sea-prep.blob');
const sentinelFuse = 'NODE_SEA_FUSE_fce680ab2cc467b6e072b8b5df1996b2';

if (process.platform !== 'win32') {
  throw new Error('Windows EXE must be built on Windows with the matching Node.js 22 runtime');
}

const packageJson = JSON.parse(
  await readFile(path.join(agentDir, 'package.json'), 'utf8'),
);
const outputName = `PocketServerOps-Computer-v${packageJson.version}-win-x64.exe`;
const outputPath = path.join(distDir, outputName);

await mkdir(distDir, { recursive: true });
await writeFile(
  seaConfigPath,
  `${JSON.stringify({
    main: bundlePath,
    output: blobPath,
    disableExperimentalSEAWarning: true,
  }, null, 2)}\n`,
  'utf8',
);

run(process.execPath, ['--experimental-sea-config', seaConfigPath]);
await copyFile(process.execPath, outputPath);

const npx = process.platform === 'win32' ? 'npx.cmd' : 'npx';
run(npx, [
  '--no-install',
  'postject',
  outputPath,
  'NODE_SEA_BLOB',
  blobPath,
  '--sentinel-fuse',
  sentinelFuse,
]);

console.log(`Windows Agent EXE: ${outputPath}`);

function run(command, args) {
  const result = spawnSync(command, args, { stdio: 'inherit', windowsHide: true });
  if (result.error) throw result.error;
  if (result.status !== 0) {
    throw new Error(`${command} exited with code ${result.status}`);
  }
}
