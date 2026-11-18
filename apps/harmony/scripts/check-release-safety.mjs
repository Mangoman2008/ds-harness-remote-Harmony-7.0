#!/usr/bin/env node
// 发包前的两条安全检查（本地和 CI 都能跑，缺构建产物时自动跳过产物部分）：
//   1) 仓库里不许跟踪桌宠素材、签名材料或本机配置（它们是使用者自备/本机私有的，
//      一旦被提交，别人 clone 下来就会连带分发出去）。
//   2) 如果有构建产物，包里的 versionName / versionCode 必须和 AppScope/app.json5 一致
//      （发布前最容易忘的就是改完代码忘了 bump，装上去版本号还是旧的）。
//
// 用法：node apps/harmony/scripts/check-release-safety.mjs [hap 路径]
//   退出码 1 = 有硬性问题；桌宠素材出现在包里只提示不失败（个人构建带桌宠是正常的）。

import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync, statSync } from 'node:fs';
import { dirname, join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';
import { inflateRawSync } from 'node:zlib';

const root = join(dirname(fileURLToPath(import.meta.url)), '..');
const repoRoot = join(root, '..', '..');
/** 仓库内的路径显示成相对路径，仓库外的直接给绝对路径（/tmp 之类算出来全是 ../）。 */
const display = (path) => {
  const rel = relative(repoRoot, path);
  return rel.length === 0 || rel.startsWith('..') ? path : rel;
};
const problems = [];
const notes = [];

// ---- 1) git 跟踪文件里不该出现的东西 ----
const FORBIDDEN_TRACKED = [
  { pattern: /^apps\/harmony\/entry\/src\/main\/resources\/rawfile\/pets\//, why: '桌宠素材（使用者自备，须留在 .gitignore）' },
  { pattern: /\.(p12|p7b|cer|jks|keystore|pfx)$/i, why: '签名材料' },
  { pattern: /(^|\/)build-profile\.local\.json5$/, why: '本机签名配置' },
];

let tracked = '';
try {
  tracked = execFileSync('git', ['-C', repoRoot, 'ls-files', 'apps/harmony'], { encoding: 'utf8' });
} catch (error) {
  notes.push('跳过仓库检查：读不到 git 跟踪列表（' + String(error && error.message).split('\n')[0] + '）');
}

if (tracked.length > 0) {
  const hits = [];
  for (const line of tracked.split('\n')) {
    const file = line.trim();
    if (file.length === 0) continue;
    for (const rule of FORBIDDEN_TRACKED) {
      if (rule.pattern.test(file)) hits.push(file + '  ← ' + rule.why);
    }
  }
  if (hits.length > 0) {
    problems.push('仓库跟踪了不该进仓库的文件：\n    ' + hits.join('\n    '));
  }
}

// ---- 2) 构建产物里的版本号 ----
const DEFAULT_HAP = join(root, 'entry/build/default/outputs/default/entry-default-signed.hap');
const hapPath = process.argv[2] !== undefined ? process.argv[2] : DEFAULT_HAP;

const readAppJson5 = () => {
  const text = readFileSync(join(root, 'AppScope/app.json5'), 'utf8');
  const versionName = /"versionName"\s*:\s*"([^"]+)"/.exec(text);
  const versionCode = /"versionCode"\s*:\s*(\d+)/.exec(text);
  return {
    versionName: versionName !== null ? versionName[1] : '',
    versionCode: versionCode !== null ? Number(versionCode[1]) : 0,
  };
};

/** 极简 zip 读取：只解 central directory 里需要的那个条目，不引依赖。 */
const readZipEntry = (path, wanted) => {
  const buffer = readFileSync(path);
  // End of central directory：从尾部往前找签名 0x06054b50。
  let eocd = -1;
  for (let i = buffer.length - 22; i >= 0 && i > buffer.length - 66000; i -= 1) {
    if (buffer.readUInt32LE(i) === 0x06054b50) {
      eocd = i;
      break;
    }
  }
  if (eocd < 0) throw new Error('不是有效的 zip/HAP：找不到 central directory');
  const total = buffer.readUInt16LE(eocd + 10);
  let offset = buffer.readUInt32LE(eocd + 16);
  for (let index = 0; index < total; index += 1) {
    if (buffer.readUInt32LE(offset) !== 0x02014b50) throw new Error('central directory 损坏');
    const method = buffer.readUInt16LE(offset + 10);
    const compressedSize = buffer.readUInt32LE(offset + 20);
    const nameLength = buffer.readUInt16LE(offset + 28);
    const extraLength = buffer.readUInt16LE(offset + 30);
    const commentLength = buffer.readUInt16LE(offset + 32);
    const localOffset = buffer.readUInt32LE(offset + 42);
    const name = buffer.toString('utf8', offset + 46, offset + 46 + nameLength);
    if (name === wanted) {
      // 本地头长度不固定（有 extra 字段），按它自己的 name/extra 长度跳过。
      const localNameLength = buffer.readUInt16LE(localOffset + 26);
      const localExtraLength = buffer.readUInt16LE(localOffset + 28);
      const dataStart = localOffset + 30 + localNameLength + localExtraLength;
      const data = buffer.subarray(dataStart, dataStart + compressedSize);
      if (method === 0) return data;
      if (method === 8) return inflateRawSync(data);
      throw new Error('不支持的压缩方式 ' + method);
    }
    offset += 46 + nameLength + extraLength + commentLength;
  }
  return undefined;
};

if (!existsSync(hapPath)) {
  notes.push('跳过产物检查：没有找到 ' + display(hapPath) + '（先构建，或用参数指定 HAP 路径）');
} else {
  const expected = readAppJson5();
  try {
    const raw = readZipEntry(hapPath, 'module.json');
    if (raw === undefined) {
      problems.push('包里没有 module.json，不像一个正常的 HAP：' + hapPath);
    } else {
      const manifest = JSON.parse(raw.toString('utf8'));
      const app = manifest.app !== undefined ? manifest.app : {};
      const actualName = typeof app.versionName === 'string' ? app.versionName : '';
      const actualCode = typeof app.versionCode === 'number' ? app.versionCode : 0;
      if (actualName !== expected.versionName || actualCode !== expected.versionCode) {
        problems.push('包内版本与 app.json5 不一致：包内 ' + actualName + ' / ' + actualCode
          + '，仓库 ' + expected.versionName + ' / ' + expected.versionCode + '（忘了 bump 还是忘了重建？）');
      }
      const sizeMb = Math.round(statSync(hapPath).size / 1024 / 102.4) / 10;
      notes.push('产物：' + display(hapPath) + ' · ' + sizeMb + ' MB · 版本 '
        + actualName + ' / ' + actualCode);
    }
  } catch (error) {
    problems.push('读不了构建产物：' + String(error && error.message).split('\n')[0]);
  }
}

for (const note of notes) console.log('· ' + note);
if (problems.length > 0) {
  console.error('❌ 发包前检查未通过：');
  for (const problem of problems) console.error('  - ' + problem);
  process.exit(1);
}
console.log('✅ 发包前检查通过（无私有素材入库，包内版本与仓库一致）');
