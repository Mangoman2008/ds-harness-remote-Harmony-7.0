/**
 * 主机能力车道回归。
 *
 * 车道判定是「诊断显示得对不对」和「附件完整引用等能力开不开」的唯一依据，曾经因为
 * `0.2.2-rc.1` 被按语义化版本判到 `0.2.0` 车道（预发布版小于正式版），能力被静默降级。
 * ETS 不能被 Node 直接 import，这里用 esbuild 现场转译真正随 HAP 发布的那份源码。
 */
import { build } from 'esbuild'
import { writeFileSync, rmSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'

const here = dirname(fileURLToPath(import.meta.url))
const etsRoot = join(here, '..', 'entry', 'src', 'main', 'ets')
const bundlePath = join(here, '.hostcompat-bundle.mjs')

interface Report {
  version: string
  laneId: string
  laneLabel: string
  capabilities: string[]
  drift: boolean
}

interface HostCompatModule {
  compareVersions(a: string, b: string): number
  compareCore(a: string, b: string): number
  HostCompat: {
    report(version: string): Report
    has(version: string, capability: string): boolean
    lanes(): Array<{ id: string; label: string; capabilities: string[] }>
  }
}

let mod!: HostCompatModule

beforeAll(async () => {
  const result = await build({
    entryPoints: [join(etsRoot, 'services', 'HostCompat.ets')],
    bundle: true,
    format: 'esm',
    write: false,
    platform: 'neutral',
    loader: { '.ets': 'ts' },
    resolveExtensions: ['.ets', '.ts', '.js']
  })
  writeFileSync(bundlePath, result.outputFiles[0].text, 'utf8')
  mod = (await import(`file://${bundlePath}`)) as HostCompatModule
})

afterAll(() => {
  rmSync(bundlePath, { force: true })
})

describe('compareCore 忽略预发布标记', () => {
  const cases: Array<[string, string, number]> = [
    ['0.2.2-rc.1', '0.2.2', 0],
    ['0.2.2', '0.2.2', 0],
    ['0.2.1', '0.2.2', -1],
    ['0.2.3', '0.2.2', 1],
    ['0.3.0-alpha.2', '0.2.2', 1]
  ]
  it('按 core 版本比较', () => {
    for (const [a, b, expected] of cases) {
      expect(`${a} vs ${b}=${Math.sign(mod.compareCore(a, b))}`).toBe(`${a} vs ${b}=${expected}`)
    }
  })
})

describe('compareVersions 保留语义化版本顺序', () => {
  it('预发布版小于同号正式版', () => {
    expect(mod.compareVersions('0.2.2-rc.1', '0.2.2')).toBeLessThan(0)
  })
  it('同号预发布之间按序号比较', () => {
    expect(mod.compareVersions('0.2.2-rc.1', '0.2.2-rc.2')).toBeLessThan(0)
  })
})

describe('HostCompat.report 车道归属', () => {
  const cases: Array<[string, string, string[], boolean]> = [
    ['0.2.2-rc.1', '0.2.2', ['session-v3', 'attachment-full-ref'], false],
    ['0.2.2', '0.2.2', ['session-v3', 'attachment-full-ref'], false],
    ['0.2.1', '0.2.0', ['session-v3'], false],
    ['0.1.9', 'legacy', [], false],
    ['0.3.0', 'future', ['session-v3', 'attachment-full-ref'], true]
  ]
  it('按版本落到对应车道', () => {
    for (const [version, laneId, capabilities, drift] of cases) {
      const report = mod.HostCompat.report(version)
      expect(`${version}:${report.laneId}`).toBe(`${version}:${laneId}`)
      expect(report.capabilities.join(',')).toBe(capabilities.join(','))
      expect(report.drift).toBe(drift)
    }
  })

  it('未知版本（空串）不判车道，也不算漂移', () => {
    const report = mod.HostCompat.report('')
    expect(report.laneId).toBe('')
    expect(report.drift).toBe(false)
  })

  it('比最旧车道还老的版本标记漂移', () => {
    const report = mod.HostCompat.report('0.0.9')
    expect(report.drift).toBe(true)
    expect(report.notes.length).toBeGreaterThan(0)
  })
})

describe('HostCompat.has', () => {
  it('0.2.2 预发布版同样拿到附件完整引用', () => {
    expect(mod.HostCompat.has('0.2.2-rc.1', 'attachment-full-ref')).toBe(true)
  })
  it('0.2.0 车道没有附件完整引用', () => {
    expect(mod.HostCompat.has('0.2.0', 'attachment-full-ref')).toBe(false)
  })
})
