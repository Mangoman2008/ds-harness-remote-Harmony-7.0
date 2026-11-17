/**
 * 直连失败后的冷却策略。
 *
 * 单独拿出来是为了能测：这里错一次的表现是「自动重连反复撞同一条不通的直连」，
 * 用户看到的是重连计数停在「第 1/6 次」，很难从现象反推到这个系数。
 */

/** 首次失败：短冷却，够跑一次中继重连即可。 */
export const LAN_FIRST_COOLDOWN_MS: number = 60 * 1000;

/** 连续失败：长冷却，避免一整个会话都在试一条坏掉的直连。 */
export const LAN_REPEAT_COOLDOWN_MS: number = 10 * 60 * 1000;

/** 连续失败到这个次数就按「这条路暂时不可用」处理。 */
export const LAN_REPEAT_THRESHOLD: number = 2;

/** 给定连续失败次数，返回应当冷却多久。 */
export function lanCooldownMs(failureStreak: number): number {
  if (failureStreak >= LAN_REPEAT_THRESHOLD) {
    return LAN_REPEAT_COOLDOWN_MS;
  }
  return LAN_FIRST_COOLDOWN_MS;
}
