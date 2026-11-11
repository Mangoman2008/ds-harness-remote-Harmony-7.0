/**
 * Host 版本车道（参考 dsh-harmony 的 compatibility lanes 思路）。
 *
 * 以前「哪个 Host 版本有什么能力」散落在各个 if 里（`harnessVersion` 判断、图片附件是否带完整
 * `ImageAttachmentRef` 等），出问题只能翻代码。这里改成一张显式表：给定 Host 版本，得到
 * 车道、能力标记和是否漂移；诊断面板与导出文件直接显示结论。
 *
 * 注意：车道只描述「客户端已经适配过的范围」，落在表外不等于不能用，只是会在诊断里标
 * `漂移`，提醒可能是新版本改了契约。
 */

/** 一条车道。 */
export class HostLane {
  id: string = '';
  label: string = '';
  /** 客户端侧会据此分支的能力标记。 */
  capabilities: string[] = [];
}

/** 一次判定的结论，给诊断面板用。 */
export class HostCompatReport {
  version: string = '';
  laneId: string = 'unknown';
  laneLabel: string = '未知版本（未适配）';
  /** true = 不在已知车道里：可用，但要提示契约可能已变。 */
  drift: boolean = false;
  capabilities: string[] = [];
  notes: string = '';

  summary(): string {
    if (this.version.length === 0) {
      return '未读到 Host 版本';
    }
    const caps: string = this.capabilities.length > 0 ? this.capabilities.join('/') : '基础';
    return this.version + ' · ' + this.laneLabel + ' · 能力 ' + caps + (this.drift ? ' · 漂移' : '');
  }
}

/** `0.2.2-rc.1` → [0,2,2, 1, 1]（末位 1 表示预发布，正式版为 0）。 */
function parseVersion(value: string): number[] {
  const text: string = value.trim().replace(/^v/i, '');
  if (text.length === 0) {
    return [];
  }
  const dash: number = text.indexOf('-');
  const core: string = dash >= 0 ? text.substring(0, dash) : text;
  const pre: string = dash >= 0 ? text.substring(dash + 1) : '';
  const parts: string[] = core.split('.');
  const out: number[] = [];
  for (let i = 0; i < 3; i += 1) {
    const raw: string = i < parts.length ? parts[i] : '0';
    const num: number = Number.parseInt(raw);
    out.push(Number.isNaN(num) ? 0 : num);
  }
  // 正式版 > 同号预发布版
  out.push(pre.length === 0 ? 1 : 0);
  return out;
}

/** 语义化比较：a < b 返回 -1，相等 0，a > b 返回 1。 */
export function compareVersions(a: string, b: string): number {
  const left: number[] = parseVersion(a);
  const right: number[] = parseVersion(b);
  if (left.length === 0 || right.length === 0) {
    return 0;
  }
  for (let i = 0; i < 4; i += 1) {
    const l: number = left[i] !== undefined ? left[i] : 0;
    const r: number = right[i] !== undefined ? right[i] : 0;
    if (l !== r) {
      return l < r ? -1 : 1;
    }
  }
  return 0;
}

/** 已知车道，按版本从旧到新。 */
const LANES: HostLane[] = [
  makeLane('legacy', '0.1.x（旧契约）', []),
  makeLane('0.2.0', '0.2.0（Session V3）', ['session-v3']),
  makeLane('0.2.2', '0.2.2（附件完整引用）', ['session-v3', 'attachment-full-ref'])
];

function makeLane(id: string, label: string, capabilities: string[]): HostLane {
  const lane: HostLane = new HostLane();
  lane.id = id;
  lane.label = label;
  lane.capabilities = capabilities;
  return lane;
}

export class HostCompat {
  /** 给定 Host 版本，判断所属车道与漂移情况。 */
  static report(version: string): HostCompatReport {
    const report: HostCompatReport = new HostCompatReport();
    report.version = version;
    if (version.length === 0) {
      return report;
    }
    if (compareVersions(version, '0.2.2') < 0) {
      if (compareVersions(version, '0.2.0') >= 0) {
        report.laneId = '0.2.0';
        report.laneLabel = '0.2.0（Session V3）';
        report.capabilities = ['session-v3'];
      } else if (compareVersions(version, '0.1.0') >= 0) {
        report.laneId = 'legacy';
        report.laneLabel = '0.1.x（旧契约）';
      } else {
        report.drift = true;
        report.notes = '比已知最旧车道还老';
      }
      return report;
    }
    if (compareVersions(version, '0.3.0') < 0) {
      report.laneId = '0.2.2';
      report.laneLabel = '0.2.2（附件完整引用）';
      report.capabilities = ['session-v3', 'attachment-full-ref'];
      return report;
    }
    // 0.3+ 还没有适配过：能力先按最新车道给，但标记漂移
    report.laneId = 'future';
    report.laneLabel = '0.3+（未适配）';
    report.capabilities = ['session-v3', 'attachment-full-ref'];
    report.drift = true;
    report.notes = '不在已适配车道内，契约可能已变';
    return report;
  }

  /** 是否具备某能力（未知版本按最新车道处理，另有漂移提示）。 */
  static has(version: string, capability: string): boolean {
    return HostCompat.report(version).capabilities.includes(capability);
  }

  /** 所有车道，给设置页/诊断列用。 */
  static lanes(): HostLane[] {
    return LANES;
  }
}
