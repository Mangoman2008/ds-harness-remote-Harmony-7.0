/**
 * 暂存交互（审批 / 提问）在补发时的判定规则。
 *
 * 这两条规则本身很简单，但都要靠时间比较，而且错了的表现很不直观：
 * 判定太严 → 审批跟着断线一起消失；判定太松 → 用户对着已经作废的卡片点半天。
 * 所以单独拿出来，让 Node 侧用例能直接测。
 */

/** 一条暂存交互的补发结论。 */
export class ReplayVerdict {
  /** 已经超过保留期：不再补发，直接从暂存里删掉。 */
  expired: boolean = false;
  /** 跨过连接建立的：主机很可能已经作废，界面上要提示。 */
  crossConnection: boolean = false;
  /** 给用户看的提示文案；空串表示不需要提示。 */
  hint: string = '';
}

/** 跨连接补发时卡片上的提示。 */
export const CROSS_CONNECTION_HINT: string = '连接已重连，这条确认可能已失效';

/**
 * 判定一条暂存交互该不该补发、要不要提示。
 *
 * @param arrivedAt   这条交互到达客户端的时刻
 * @param connectedAt 当前连接建立的时刻（0 表示还没连上）
 * @param now         当前时刻
 * @param ttlMs       暂存保留期
 */
export function classifyPending(arrivedAt: number, connectedAt: number, now: number,
  ttlMs: number): ReplayVerdict {
  const verdict: ReplayVerdict = new ReplayVerdict();
  if (ttlMs > 0 && now - arrivedAt > ttlMs) {
    verdict.expired = true;
    return verdict;
  }
  // 连接建立之前到达、却还留在暂存里，说明中间断过一次；主机多半已经把请求作废了。
  if (connectedAt > 0 && arrivedAt < connectedAt) {
    verdict.crossConnection = true;
    verdict.hint = CROSS_CONNECTION_HINT;
  }
  return verdict;
}
