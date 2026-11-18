/**
 * 把主机/传输层抛出来的错误原文翻成「用户能据此做事」的一句话。
 *
 * 为什么单独成模块：主机返回的报错是英文协议文案（`endpoint is not allowed`、
 * `CONTEXT_WINDOW_EXCEEDED`…），直接弹给用户等于没说；而这类判断散在 AppRuntime 里
 * 会变成一堆 if，既改不动也测不了。这里只做纯字符串判定，不碰任何 Kit。
 *
 * 约定：
 *   - 规则按「越具体越靠前」排列，命中即返回；
 *   - 判定不区分大小写，兼容主机不同版本的大小写习惯；
 *   - 未命中时保留原文（截断到 160 字），不要吞掉细节。
 */

export const KIND_HOST_TOO_OLD: string = 'host-too-old';
export const KIND_CONTEXT_OVERFLOW: string = 'context-overflow';
export const KIND_BUSY: string = 'busy';
export const KIND_NETWORK: string = 'network';
export const KIND_AUTH: string = 'auth';
export const KIND_TOO_LARGE: string = 'too-large';
export const KIND_PATH_DENIED: string = 'path-denied';
export const KIND_UNKNOWN: string = 'unknown';

export interface ErrorExplanation {
  kind: string;
  /** 面向用户的一句话（中文原文；英文界面由调用方决定是否展示原文）。 */
  text: string;
  /** 原样重试有没有意义：网络/忙碌可以，其余得先改条件。 */
  retryable: boolean;
}

interface Rule {
  kind: string;
  needles: string[];
  text: string;
  retryable: boolean;
}

const RULES: Rule[] = [
  {
    kind: KIND_HOST_TOO_OLD,
    // 0.6.4 及更早的主机没有这些端点，网关统一回 endpoint is not allowed
    needles: ['endpoint is not allowed', 'not allowlisted', 'unknown endpoint'],
    text: '主机插件版本太旧，还不支持这个操作（把 Host 上的 ds-harness-remote 升到 0.6.5 以上）',
    retryable: false,
  },
  {
    kind: KIND_CONTEXT_OVERFLOW,
    needles: ['context_window_exceeded', 'context window', 'too many tokens', 'maximum context'],
    text: '上下文超出主机窗口了，先压缩会话（/compact）再发',
    retryable: false,
  },
  {
    kind: KIND_BUSY,
    needles: ['agent_busy', 'rate_limited', 'rate limited', 'too many requests', 'busy'],
    text: '主机正忙（或请求太频繁），等几秒再试',
    retryable: true,
  },
  {
    kind: KIND_TOO_LARGE,
    needles: ['payload too large', 'too large', 'exceeds', '413', 'request entity'],
    text: '这次提交的内容太大（附件或消息超出主机限制），换小一点再发',
    retryable: false,
  },
  {
    kind: KIND_PATH_DENIED,
    needles: ['outside', 'escape', 'not within', 'permission denied', 'forbidden', 'denied'],
    text: '主机拒绝这个路径：新版主机只允许读当前会话工作区内的文件',
    retryable: false,
  },
  {
    kind: KIND_AUTH,
    needles: ['unauthorized', '401', 'token expired', 'login required', 'not authenticated'],
    text: '登录状态失效了，重新登录后再试',
    retryable: false,
  },
  {
    kind: KIND_NETWORK,
    needles: ['econnrefused', 'econnreset', 'socket hang up', 'etimedout', 'timed out', 'network',
      'connection closed', 'connection_failed', 'transport_closed', 'no route'],
    text: '网络这条路不通（已自动换通道或等待重连），稍等再试',
    retryable: true,
  },
];

const MAX_RAW_LENGTH: number = 160;

/** 只留一句给用户看：命中规则就用规则文案，否则用原文（截断）。 */
export function explainError(raw: string): ErrorExplanation {
  const text: string = raw === undefined || raw === null ? '' : String(raw).trim();
  if (text.length === 0) {
    return { kind: KIND_UNKNOWN, text: '主机没有说明失败原因', retryable: true };
  }
  const haystack: string = text.toLowerCase();
  for (const rule of RULES) {
    for (const needle of rule.needles) {
      if (haystack.indexOf(needle) >= 0) {
        return { kind: rule.kind, text: rule.text, retryable: rule.retryable };
      }
    }
  }
  const clipped: string = text.length > MAX_RAW_LENGTH ? text.substring(0, MAX_RAW_LENGTH) + '…' : text;
  return { kind: KIND_UNKNOWN, text: clipped, retryable: false };
}
