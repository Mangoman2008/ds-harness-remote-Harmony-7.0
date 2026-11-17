/**
 * 暂存交互补发规则的回归。
 *
 * 规则本身很短，但它决定「审批会不会跟着一次断线一起消失」，以及「会不会让用户点一张
 * 早就作废的卡」。这里覆盖三条边界：保留期、跨连接、以及两者叠加。
 */
import { build } from 'esbuild'
import { writeFileSync, rmSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'

const here = dirname(fileURLToPath(import.meta.url))
const etsRoot = join(here, '..', 'entry', 'src', 'main', 'ets')
const bundlePath = join(here, '.replay-policy-bundle.mjs')

interface Verdict {
  expired: boolean
  crossConnection: boolean
  hint: string
}

interface PolicyModule {
  CROSS_CONNECTION_HINT: string
  classifyPending(arrivedAt: number, connectedAt: number, now: number, ttlMs: number): Verdict
}

let mod!: PolicyModule

beforeAll(async () => {
  const result = await build({
    entryPoints: [join(etsRoot, 'services', 'ReplayPolicy.ets')],
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

const TTL = 15 * 60 * 1000

describe('classifyPending', () => {
  it('同一条连接内到达：正常补发，不带提示', () => {
    const connectedAt = 1000
    const verdict = mod.classifyPending(2000, connectedAt, 3000, TTL)
    expect(verdict.expired).toBe(false)
    expect(verdict.crossConnection).toBe(false)
    expect(verdict.hint).toBe('')
  })

  it('连接建立之前到达：判为跨连接并给出提示', () => {
    const connectedAt = 5000
    const verdict = mod.classifyPending(1000, connectedAt, 6000, TTL)
    expect(verdict.crossConnection).toBe(true)
    expect(verdict.hint).toBe(mod.CROSS_CONNECTION_HINT)
  })

  it('连接还没建立（connectedAt=0）时不判跨连接', () => {
    const verdict = mod.classifyPending(1000, 0, 2000, TTL)
    expect(verdict.crossConnection).toBe(false)
  })

  it('超过保留期：标记过期，不再补发', () => {
    const verdict = mod.classifyPending(0, 0, TTL + 1, TTL)
    expect(verdict.expired).toBe(true)
  })

  it('刚好等于保留期：仍在窗口内', () => {
    const verdict = mod.classifyPending(0, 0, TTL, TTL)
    expect(verdict.expired).toBe(false)
  })

  it('过期优先于跨连接：已过期的卡不再提示', () => {
    const verdict = mod.classifyPending(1000, 5000, 5000 + TTL + 1, TTL)
    expect(verdict.expired).toBe(true)
    expect(verdict.crossConnection).toBe(false)
    expect(verdict.hint).toBe('')
  })
})
