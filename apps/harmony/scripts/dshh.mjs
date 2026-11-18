#!/usr/bin/env node
// 鸿蒙客户端工程命令行：把散落在 scripts/ 里的动作收成一个入口。
//
//   node apps/harmony/scripts/dshh.mjs <命令> [参数]
//
// 命令一览（`dshh help` 也是这份）：
//   devices                列出 hdc 设备（区分本机 PC / 无线手机）
//   build [--clean]        构建 signed hap（--clean 先清 hvigor 工程缓存）
//   install [--all|--pc|--phone|<id>]   安装构建产物（默认：所有在线设备）
//   launch  [--pc|--phone|<id>]         冷启动 App 并读 combo 行确认版本与传输
//   logs    [--follow] [--lines N]      看 App 的 hilog（默认 40 行，--follow 跟踪）
//   shot    [-o 文件] [--pc|--phone]    截图并拉到本机
//   smoke   [--pc|--phone] [--wait 秒]  委托 scripts/smoke.sh 跑完整冒烟
//   verify                              跑全部门禁（i18n / 版本 / 发包安全）
//   version                             打印仓库版本、产物版本、git 短哈希
//   doctor                              环境体检（工具链 / 签名配置 / DSH_HOME 文件系统 / 插件补丁）
//   release [--notes|--tag [--push]]    委托 scripts/release.mjs
//
// 设备选择：优先 --pc / --phone / 直接给 id；没给就用唯一在线设备，多台时报错并列出候选。
// 手机 IP 可以让它自己连：export DSHH_PHONE=192.168.11.110:45327

import { spawnSync } from 'node:child_process';
import { existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { homedir, tmpdir } from 'node:os';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const APP_DIR = join(dirname(fileURLToPath(import.meta.url)), '..');
const REPO_ROOT = join(APP_DIR, '..', '..');
const HAP = join(APP_DIR, 'entry/build/default/outputs/default/entry-default-signed.hap');
const BUNDLE = 'cn.r2049.dshremote';
const ABILITY = 'EntryAbility';

const C = {
  dim: (s) => (process.stdout.isTTY ? `\u001b[2m${s}\u001b[0m` : s),
  bold: (s) => (process.stdout.isTTY ? `\u001b[1m${s}\u001b[0m` : s),
  green: (s) => (process.stdout.isTTY ? `\u001b[32m${s}\u001b[0m` : s),
  red: (s) => (process.stdout.isTTY ? `\u001b[31m${s}\u001b[0m` : s),
  yellow: (s) => (process.stdout.isTTY ? `\u001b[33m${s}\u001b[0m` : s),
};

class UsageError extends Error {}
class CommandError extends Error {}

const say = (line = '') => console.log(line);
const ok = (line) => console.log(C.green('✓ ') + line);
const warn = (line) => console.log(C.yellow('! ') + line);
const bad = (line) => console.log(C.red('✗ ') + line);

/** 跑一个命令，返回 {code, stdout, stderr}；不抛。 */
function run(command, args, options = {}) {
  const result = spawnSync(command, args, {
    cwd: options.cwd ?? REPO_ROOT,
    encoding: 'utf8',
    stdio: options.quiet === true ? 'pipe' : 'inherit',
    env: { ...process.env, ...(options.env ?? {}) },
    shell: false,
  });
  if (result.error !== undefined && result.error !== null) {
    return { code: 127, stdout: '', stderr: String(result.error.message) };
  }
  return { code: result.status ?? 1, stdout: result.stdout ?? '', stderr: result.stderr ?? '' };
}

/** 跑一个命令并返回布尔（不打印）。 */
function succeed(command, args) {
  const result = run(command, args, { quiet: true });
  return result.code === 0;
}

function resolveHdc() {
  if (process.env.HDC !== undefined && process.env.HDC.length > 0) return process.env.HDC;
  const candidates = [
    join(homedir(), '.harmonybrew/bin/hdc'),
    '/usr/local/bin/hdc',
    '/opt/harmony/hdc',
  ];
  for (const candidate of candidates) {
    if (existsSync(candidate)) return candidate;
  }
  return 'hdc';
}

const HDC = resolveHdc();

const hdc = (args, options = {}) => run(HDC, args, options);

function listDevices() {
  const result = hdc(['list', 'targets'], { quiet: true });
  if (result.code !== 0) {
    throw new CommandError('hdc list targets 失败：' + (result.stderr.trim() || result.stdout.trim()));
  }
  return result.stdout
    .split('\n')
    .map((line) => line.trim())
    .filter((line) => line.length > 0 && !line.startsWith('['))
    .map((id) => ({ id, kind: /^127\.0\.0\.1:/.test(id) ? 'pc' : 'phone' }));
}

function describeDevices(devices) {
  return devices.map((d) => (d.kind === 'pc' ? `${d.id}（本机 PC）` : `${d.id}（无线设备）`)).join('、');
}

/**
 * 把 --pc / --phone / <id> 解析成设备列表。
 * 手机没连上但配了 DSHH_PHONE 时自动 tconn 一次。
 */
function selectDevices(argv, { allWhenEmpty = true } = {}) {
  const wantsPc = argv.includes('--pc');
  const wantsPhone = argv.includes('--phone');
  // 只认「形如 ip:port」或者确实在设备列表里的参数：否则 `-o /tmp/a-b.jpg` 这种会被当成设备号。
  const ipPort = /^\d{1,3}(\.\d{1,3}){3}:\d+$/;
  let devices = listDevices();
  const explicit = argv.find((arg) => ipPort.test(arg) || devices.some((d) => d.id === arg)) ?? undefined;

  if (wantsPhone && devices.every((d) => d.kind !== 'phone') && process.env.DSHH_PHONE !== undefined) {
    say(C.dim('· 手机没连，尝试 tconn ' + process.env.DSHH_PHONE));
    hdc(['tconn', process.env.DSHH_PHONE], { quiet: true });
    devices = listDevices();
  }

  if (explicit !== undefined) {
    return [{ id: explicit, kind: /^127\.0\.0\.1:/.test(explicit) ? 'pc' : 'phone' }];
  }
  if (wantsPc) {
    const pc = devices.filter((d) => d.kind === 'pc');
    if (pc.length === 0) throw new CommandError('没有本机 PC 设备（hdc list targets 里没有 127.0.0.1:*）');
    return pc;
  }
  if (wantsPhone) {
    const phone = devices.filter((d) => d.kind === 'phone');
    if (phone.length === 0) {
      throw new CommandError('没有无线设备在线。先在手机上开启无线调试，或 export DSHH_PHONE=<ip:port>');
    }
    return phone;
  }
  if (devices.length === 0) {
    if (!allWhenEmpty) return [];
    throw new CommandError('没有在线设备');
  }
  return devices;
}

const appVersion = () => {
  const text = readFileSync(join(APP_DIR, 'AppScope/app.json5'), 'utf8');
  const name = /"versionName"\s*:\s*"([^"]+)"/.exec(text);
  const code = /"versionCode"\s*:\s*(\d+)/.exec(text);
  return { versionName: name !== null ? name[1] : '?', versionCode: code !== null ? Number(code[1]) : 0 };
};

const gitShort = () => {
  const result = run('git', ['-C', REPO_ROOT, 'rev-parse', '--short', 'HEAD'], { quiet: true });
  return result.code === 0 ? result.stdout.trim() : '?';
};

// ---------------------------------------------------------------- 命令

function cmdDevices() {
  const devices = listDevices();
  if (devices.length === 0) {
    warn('没有在线设备');
    return 0;
  }
  for (const device of devices) {
    const state = installedVersion(device.id);
    const label = device.kind === 'pc' ? '本机 PC' : '无线设备';
    const shown = state.installed
      ? (state.version.length > 0 ? '已安装 ' + state.version : '已安装（版本读不到）')
      : C.dim('未安装');
    say(`  ${C.bold(device.id)}  ${C.dim(label)}  ${shown}`);
  }
  say(C.dim(`\n仓库版本 ${appVersion().versionName} · 产物 ${existsSync(HAP) ? describeHap() : '未构建'}`));
  return 0;
}

/** 查一台设备上装没装、装的什么版本。有些系统 bm dump 的 versionName 是空串，只能报「已安装」。 */
function installedVersion(deviceId) {
  const result = hdc(['-t', deviceId, 'shell', `bm dump -n ${BUNDLE}`], { quiet: true });
  const installed = result.code === 0 && result.stdout.includes(BUNDLE);
  if (!installed) return { installed: false, version: '' };
  const matches = [...result.stdout.matchAll(/"versionName"\s*:\s*"([^"]*)"/g)]
    .map((m) => m[1])
    .filter((v) => v.length > 0);
  return { installed: true, version: matches.length > 0 ? matches[0] : '' };
}

function describeHap() {
  if (!existsSync(HAP)) return '未构建';
  const sizeMb = Math.round(statSize(HAP) / 1024 / 102.4) / 10;
  const version = hapVersion();
  return `${sizeMb} MB · ${version.length > 0 ? version : '版本未知'}`;
}

function statSize(path) {
  const result = run('stat', ['-c', '%s', path], { quiet: true });
  return Number(result.stdout.trim()) || 0;
}

function hapVersion() {
  const result = run(process.execPath, [join(APP_DIR, 'scripts/check-release-safety.mjs'), HAP], { quiet: true });
  const match = /版本\s+(\S+)\s+\/\s+(\d+)/.exec(result.stdout);
  return match !== null ? `${match[1]} / ${match[2]}` : '';
}

function cmdBuild(argv) {
  if (argv.includes('--clean')) {
    clearHvigorCache();
  }
  const result = run(join(APP_DIR, 'scripts/build-local.sh'), []);
  if (result.code !== 0) throw new CommandError('构建失败（见上面的编译输出）');
  if (!existsSync(HAP)) throw new CommandError('构建返回成功但没有产物：' + HAP);
  ok(`构建完成：${describeHap()}`);
  return 0;
}

/** hvigor 的工程缓存偶尔会缺文件（ENOENT .../hvigor/bin/hvigor.js），清掉比排查快。 */
function clearHvigorCache() {
  const base = join(homedir(), '.hvigor/project_caches');
  if (!existsSync(base)) {
    warn('没有 hvigor 工程缓存目录，跳过 --clean');
    return;
  }
  const result = run('rm', ['-rf', base], { quiet: true });
  if (result.code !== 0) throw new CommandError('清 hvigor 缓存失败：' + result.stderr.trim());
  say(C.dim('· 已清空 ~/.hvigor/project_caches'));
}

function cmdInstall(argv) {
  const devices = selectDevices(argv);
  if (!existsSync(HAP)) throw new CommandError('没有构建产物，先跑 `dshh build`：' + HAP);
  const version = hapVersion();
  say(`· 装机：${describeHap()} → ${describeDevices(devices)}`);
  let failed = 0;
  for (const device of devices) {
    hdc(['tconn', device.id], { quiet: true });
    const result = hdc(['-t', device.id, 'install', '-r', HAP], { quiet: true });
    if (result.stdout.includes('install bundle successfully') || result.stderr.includes('install bundle successfully')) {
      ok(`${device.id} 安装成功${version.length > 0 ? '（' + version + '）' : ''}`);
    } else {
      failed += 1;
      bad(`${device.id} 安装失败`);
      say((result.stdout + result.stderr).trim().split('\n').slice(-4).map((l) => '    ' + l).join('\n'));
      if (/locked|screen/i.test(result.stdout + result.stderr)) {
        say(C.dim('    设备锁屏时装不了/起不来，先解锁。'));
      }
    }
  }
  return failed === 0 ? 0 : 1;
}

function cmdLaunch(argv) {
  const devices = selectDevices(argv);
  const device = devices[0];
  if (devices.length > 1) warn(`多台在线，只用 ${device.id}（要指定请加 --pc 或 --phone）`);
  hdc(['tconn', device.id], { quiet: true });
  // 先 force-stop：已在运行时 aa start 只是切前台，不会产生新的 combo 行。
  hdc(['-t', device.id, 'shell', `aa force-stop ${BUNDLE}`], { quiet: true });
  hdc(['-t', device.id, 'shell', 'hilog -r'], { quiet: true });
  const start = hdc(['-t', device.id, 'shell', `aa start -b ${BUNDLE} -a ${ABILITY}`], { quiet: true });
  if (!/start ability successfully/.test(start.stdout + start.stderr)) {
    const detail = (start.stdout + start.stderr).trim();
    bad('拉起失败');
    say(detail.split('\n').slice(0, 3).map((l) => '    ' + l).join('\n'));
    if (/screen is locked|锁屏/i.test(detail)) say(C.dim('    设备锁屏：解锁后重试。'));
    return 1;
  }
  ok(`${device.id} 已拉起`);
  const combo = waitForCombo(device.id, 40);
  if (combo === undefined) {
    warn('40 秒内没看到 combo 行（可能还没连上主机，或主机不在线）');
    return 0;
  }
  say('  ' + combo);
  return 0;
}

function waitForCombo(deviceId, seconds) {
  const deadline = Date.now() + seconds * 1000;
  while (Date.now() < deadline) {
    const result = hdc(['-t', deviceId, 'shell', 'hilog -x -T DSHREMOTE'], { quiet: true });
    const line = result.stdout.split('\n').filter((l) => l.includes('[combo]')).pop();
    if (line !== undefined && line.length > 0) {
      const payload = /\[combo\][^→]*→\s*(.*)$/.exec(line);
      return payload !== null ? payload[1] : line.trim();
    }
    run('sleep', ['2'], { quiet: true });
  }
  return undefined;
}

function cmdLogs(argv) {
  const lines = numericFlag(argv, '--lines') ?? 40;
  const follow = argv.includes('--follow') || argv.includes('-f');
  const tag = stringFlag(argv, '--tag') ?? 'DSHREMOTE';
  const devices = selectDevices(argv);
  const device = devices[0];
  if (follow) {
    say(C.dim(`· 跟踪 ${device.id} 的 ${tag} 日志，Ctrl+C 结束`));
    // 设备端不带 -x 的 hilog 是持续输出，直接接管终端即可。
    const result = run(HDC, ['-t', device.id, 'shell', `hilog -T ${tag}`]);
    return result.code;
  }
  const result = hdc(['-t', device.id, 'shell', `hilog -T ${tag} -x`], { quiet: true });
  if (result.code !== 0) throw new CommandError('读日志失败：' + (result.stderr.trim() || result.stdout.trim()));
  const body = tail(result.stdout, lines);
  if (body.trim().length === 0) {
    say(C.dim(`当前缓冲区没有 ${tag} 日志（App 空闲、或刚被 \`hilog -r\` 清过）。\n` +
      '想看新日志：`dshh launch` 冷启动一次，或加 --follow 持续跟踪。'));
    return 0;
  }
  process.stdout.write(body);
  return 0;
}

const tail = (text, count) => {
  const lines = text.split('\n').filter((l) => l.trim().length > 0);
  return lines.slice(Math.max(0, lines.length - count)).join('\n') + '\n';
};

function cmdShot(argv) {
  const output = stringFlag(argv, '-o') ?? stringFlag(argv, '--out') ?? join(REPO_ROOT, 'artifacts', `harmony-shot-${stamp()}.jpg`);
  const devices = selectDevices(argv);
  const device = devices[0];
  // PC 上的 snapshot_display 只认 .jpeg 后缀，写成 .jpg 会报 invalid suffix。
  const remote = '/data/local/tmp/dshh-shot.jpeg';
  const snap = hdc(['-t', device.id, 'shell', `snapshot_display -f ${remote}`], { quiet: true });
  if (!/success|write to/i.test(snap.stdout + snap.stderr)) {
    bad('截图失败');
    say((snap.stdout + snap.stderr).trim().split('\n').slice(0, 3).map((l) => '    ' + l).join('\n'));
    return 1;
  }
  const recv = hdc(['-t', device.id, 'file', 'recv', remote, output], { quiet: true });
  if (!existsSync(output)) {
    bad('拉取截图失败');
    say((recv.stdout + recv.stderr).trim().split('\n').slice(0, 3).map((l) => '    ' + l).join('\n'));
    return 1;
  }
  ok(`截图已保存：${output}`);
  return 0;
}

const stamp = () => new Date().toISOString().replace(/[:T]/g, '-').slice(0, 19);

function cmdSmoke(argv) {
  const wait = numericFlag(argv, '--wait') ?? 45;
  const device = selectDevices(argv)[0];
  const result = run(join(APP_DIR, 'scripts/smoke.sh'), [device.id, String(wait)]);
  return result.code;
}

function cmdVerify() {
  const steps = [
    { name: 'i18n 文案', script: 'check-i18n.mjs', args: [] },
    { name: '版本号两处一致', script: 'bump-version.mjs', args: ['--check'] },
    { name: '发包安全（私有素材 / 包内版本）', script: 'check-release-safety.mjs', args: [] },
  ];
  let failed = 0;
  for (const step of steps) {
    const result = run(process.execPath, [join(APP_DIR, 'scripts', step.script), ...step.args], { quiet: true });
    if (result.code === 0) {
      ok(step.name + '：' + lastLine(result.stdout));
    } else {
      failed += 1;
      bad(step.name);
      say(indent((result.stdout + result.stderr).trim(), 4));
    }
  }
  return failed === 0 ? 0 : 1;
}

const lastLine = (text) => {
  const lines = text.split('\n').map((l) => l.trim()).filter((l) => l.length > 0);
  return lines.length > 0 ? lines[lines.length - 1] : '';
};
const indent = (text, spaces) => text.split('\n').map((l) => ' '.repeat(spaces) + l).join('\n');

function cmdVersion() {
  const version = appVersion();
  say(`  仓库版本   ${C.bold(version.versionName)}（versionCode ${version.versionCode}）`);
  say(`  构建产物   ${describeHap()}`);
  say(`  git        ${gitShort()}`);
  const devices = listDevices();
  if (devices.length > 0) {
    for (const device of devices) {
      const state = installedVersion(device.id);
      const shown = state.installed ? (state.version.length > 0 ? state.version : '已安装（版本读不到）') : C.dim('未安装');
      say(`  ${device.kind === 'pc' ? 'PC      ' : '设备    '}   ${device.id} → ${shown}`);
    }
  }
  return 0;
}

function cmdDoctor() {
  let problems = 0;
  say(C.bold('工具链'));
  say(`  node       ${process.version}`);
  const hdcVersion = hdc(['version'], { quiet: true });
  if (hdcVersion.code === 0) {
    ok('hdc ' + (hdcVersion.stdout.split('\n')[0] ?? '').trim());
  } else {
    problems += 1;
    bad('找不到可用的 hdc（设 HDC 环境变量或装到 ~/.harmonybrew/bin）');
  }
  const hvigorw = succeed('sh', ['-c', 'command -v hvigorw']);
  const devecocli = existsSync(join(homedir(), '.deveco/bin/devecocli'));
  if (hvigorw || devecocli) {
    ok('构建器 ' + (hvigorw ? 'hvigorw' : 'devecocli（回退）'));
  } else {
    problems += 1;
    bad('既没有 hvigorw 也没有 devecocli');
  }
  if (existsSync(join(APP_DIR, 'build-profile.local.json5'))) {
    ok('本机签名配置 build-profile.local.json5 已就位');
  } else {
    problems += 1;
    bad('缺少 build-profile.local.json5（DevEco 里配一次签名）');
  }

  say(C.bold('\n设备'));
  try {
    const devices = listDevices();
    if (devices.length === 0) {
      warn('没有在线设备');
    } else {
      for (const device of devices) {
        const state = installedVersion(device.id);
        const shown = state.installed ? (state.version.length > 0 ? ' · ' + state.version : ' · 已安装') : ' · 未安装';
        ok(`${device.id}（${device.kind === 'pc' ? '本机 PC' : '无线设备'}）${shown}`);
      }
    }
  } catch (error) {
    problems += 1;
    bad(String(error.message));
  }

  say(C.bold('\n仓库一致性'));
  const verifyCode = cmdVerify();
  if (verifyCode !== 0) problems += 1;

  say(C.bold('\nDSH_HOME 文件系统（影响 ds-harness-remote 插件）'));
  const dshHome = process.env.DSH_HOME ?? join(homedir(), '.dsh');
  if (existsSync(dshHome)) {
    const probe = join(dshHome, '.dshh-probe');
    try {
      writeFileSync(probe, 'x');
      const linked = join(dshHome, '.dshh-probe-link');
      const linkOk = succeed('ln', [probe, linked]);
      if (linkOk) {
        ok('支持硬链接');
        rmSync(linked, { force: true });
      } else {
        warn('不支持硬链接（hmdfs）：插件 0.6.5+ 需要补丁才能启动');
        const patcher = join(dshHome, 'patches/patch-remote-hmdfs.mjs');
        if (existsSync(patcher)) {
          const check = run(process.execPath, [patcher, '--check'], { quiet: true });
          if (check.code === 0) {
            ok('已打补丁：patch-remote-hmdfs.mjs --check 通过');
          } else {
            problems += 1;
            bad('插件补丁未打或版本已变：node ' + patcher);
          }
        } else {
          warn('没找到 ' + patcher);
        }
      }
    } finally {
      rmSync(probe, { force: true });
      rmSync(join(dshHome, '.dshh-probe-link'), { force: true });
    }
  } else {
    warn('没有 ' + dshHome + '（还没跑过 dsh）');
  }

  say(C.bold('\nhvigor 工程缓存'));
  const cacheDir = join(homedir(), '.hvigor/project_caches');
  if (!existsSync(cacheDir)) {
    ok('还没有缓存（首次构建会创建）');
  } else {
    const entries = run('ls', [cacheDir], { quiet: true }).stdout.split('\n').filter((l) => l.trim().length > 0);
    const broken = entries.filter((name) => !existsSync(join(cacheDir, name, 'workspace/node_modules/@ohos/hvigor/bin/hvigor.js')));
    if (broken.length === 0) {
      ok(`${entries.length} 个工程缓存看起来完整`);
    } else {
      warn(`${broken.length}/${entries.length} 个缓存缺 hvigor.js：构建报 ENOENT 时用 \`dshh build --clean\``);
    }
  }

  say('');
  if (problems === 0) {
    ok('体检通过');
    return 0;
  }
  bad(`体检发现 ${problems} 个需要处理的问题`);
  return 1;
}

function cmdRelease(argv) {
  const forwarded = argv.filter((arg) => arg !== '--');
  const result = run(process.execPath, [join(APP_DIR, 'scripts/release.mjs'), ...forwarded]);
  return result.code;
}

function numericFlag(argv, name) {
  const index = argv.indexOf(name);
  if (index < 0 || index + 1 >= argv.length) return undefined;
  const value = Number(argv[index + 1]);
  return Number.isFinite(value) ? value : undefined;
}

function stringFlag(argv, name) {
  const index = argv.indexOf(name);
  if (index < 0 || index + 1 >= argv.length) return undefined;
  return argv[index + 1];
}

const HELP = `鸿蒙客户端工程命令行

  dshh devices                              列出设备（本机 PC / 无线设备，含已装版本）
  dshh build [--clean]                      构建 signed hap（--clean 先清 hvigor 缓存）
  dshh install [--pc|--phone|<id>]          安装构建产物（默认所有在线设备）
  dshh launch  [--pc|--phone|<id>]          冷启动并读 combo 行确认版本与传输
  dshh logs    [-f] [--lines N] [--tag T]   看 hilog（默认 40 行）
  dshh shot    [-o 文件] [--pc|--phone]     截图并拉到本机
  dshh smoke   [--pc|--phone] [--wait 秒]   完整冒烟（构建→装机→拉起→判定）
  dshh verify                               全部门禁：i18n / 版本 / 发包安全
  dshh version                              仓库版本、产物版本、各设备已装版本
  dshh doctor                               环境体检（工具链/签名/设备/一致性/文件系统/缓存/插件补丁）
  dshh release [--notes|--tag [--push]]     发版（转发 scripts/release.mjs）

环境变量：HDC（hdc 路径）、DSHH_PHONE（手机 ip:port，--phone 未连时自动 tconn）
`;

function main(argv) {
  const [command, ...rest] = argv;
  if (command === undefined || command === 'help' || command === '--help' || command === '-h') {
    process.stdout.write(HELP);
    return 0;
  }
  switch (command) {
    case 'devices': return cmdDevices();
    case 'build': return cmdBuild(rest);
    case 'install': return cmdInstall(rest);
    case 'launch': return cmdLaunch(rest);
    case 'logs': return cmdLogs(rest);
    case 'shot': return cmdShot(rest);
    case 'smoke': return cmdSmoke(rest);
    case 'verify': return cmdVerify();
    case 'version': return cmdVersion();
    case 'doctor': return cmdDoctor();
    case 'release': return cmdRelease(rest);
    default:
      throw new UsageError('未知命令：' + command);
  }
}

try {
  process.exit(main(process.argv.slice(2)));
} catch (error) {
  if (error instanceof UsageError) {
    bad(error.message);
    process.stdout.write('\n' + HELP);
    process.exit(2);
  }
  bad(error instanceof Error ? error.message : String(error));
  process.exit(1);
}
