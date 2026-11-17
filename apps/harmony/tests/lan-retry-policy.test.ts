/**
 * 直连失败冷却策略的回归。
 *
 * 这条规则决定「自动重连会不会反复撞同一条不通的直连」。判错的症状是重连计数停在
 * 「第 1/6 次」，很难从现象反推，所以用用例钉死两档冷却与阈值。
 */
import { build } from 'esbuild'
import { writeFileSync, rmSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'

const here = dirname(fileURLToPath(import.meta.url))
const etsRoot = join(here, '..', 'entry', 'src', 'main', 'ets')
const bundlePath = join(here, '.lan-retry-bundle.mjs')

interface PolicyModule {
  LAN_FIRST_COOLDOWN_MS: number
  LAN_REPEAT_COOLDOWN_MS: number
  LAN_REPEAT_THRESHOLD: number
  lanCooldownMs(failureStreak: number): number
}

let mod!: PolicyModule

beforeAll(async () => {
  const result = await build({
    entryPoints: [join(etsRoot, 'net', 'LanRetryPolicy.ets')],
    bundle: true,
    format: 'esm',
    write: false,
    platform: 'neutral',
    loader: { '.ets': 'ts' },
    resolveExtensions: ['.ets', '.ts', '.js']
  })
  writeFileSync(bundlePath, result.outputFiles[0].text, 'utf8')
  mod = (await import(`file://${bundlePath}`)) as PolicyModule
})

afterAll(() => {
  rmSync(bundlePath, { force: true })
})

describe('lanCooldownMs', () => {
  it('首次失败只冷却 60 秒', () => {
    expect(mod.lanCooldownMs(1)).toBe(60 * 1000)
  })

  it('连续两次失败进入 10 分钟长冷却', () => {
    expect(mod.lanCooldownMs(2)).toBe(10 * 60 * 1000)
    expect(mod.lanCooldownMs(5)).toBe(10 * 60 * 1000)
  })

  it('阈值就是 2，1 次不进入长冷却', () => {
    expect(mod.LAN_REPEAT_THRESHOLD).toBe(2)
    expect(mod.lanCooldownMs(mod.LAN_REPEAT_THRESHOLD - 1)).toBe(mod.LAN_FIRST_COOLDOWN_MS)
    expect(mod.lanCooldownMs(mod.LAN_REPEAT_THRESHOLD)).toBe(mod.LAN_REPEAT_COOLDOWN_MS)
  })

  it('次数为 0 时也返回短冷却（不会给出 0 让上层误以为不用冷却）', () => {
    expect(mod.lanCooldownMs(0)).toBe(mod.LAN_FIRST_COOLDOWN_MS)
  })
})
