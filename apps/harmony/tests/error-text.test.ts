/**
 * 错误文案映射的回归。
 *
 * 这套规则决定「用户看到的是人话还是主机英文原文」，最容易回归的地方是：
 * 规则顺序（具体先于笼统）、大小写、以及未命中时不能把原文吞掉。
 */
import { build } from 'esbuild'
import { writeFileSync, rmSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, join } from 'node:path'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'

const here = dirname(fileURLToPath(import.meta.url))
const etsRoot = join(here, '..', 'entry', 'src', 'main', 'ets')
const bundlePath = join(here, '.error-text-bundle.mjs')

interface ErrorExplanation {
  kind: string
  text: string
  retryable: boolean
}

interface ErrorTextModule {
  explainError(raw: string): ErrorExplanation
  KIND_HOST_TOO_OLD: string
  KIND_CONTEXT_OVERFLOW: string
  KIND_BUSY: string
  KIND_NETWORK: string
  KIND_AUTH: string
  KIND_TOO_LARGE: string
  KIND_PATH_DENIED: string
  KIND_UNKNOWN: string
}

let mod!: ErrorTextModule

beforeAll(async () => {
  const result = await build({
    entryPoints: [join(etsRoot, 'services', 'ErrorText.ets')],
    bundle: true,
    format: 'esm',
    write: false,
    platform: 'neutral',
    loader: { '.ets': 'ts' },
    resolveExtensions: ['.ets', '.ts', '.js']
  })
  writeFileSync(bundlePath, result.outputFiles[0].text, 'utf8')
  mod = (await import(`file://${bundlePath}`)) as ErrorTextModule
})

afterAll(() => {
  rmSync(bundlePath, { force: true })
})

describe('explainError', () => {
  it('旧主机的 endpoint 拒绝：翻成「插件太旧」且不可重试', () => {
    const result = mod.explainError('The requested Harness Remote endpoint is not allowed')
    expect(result.kind).toBe(mod.KIND_HOST_TOO_OLD)
    expect(result.retryable).toBe(false)
    expect(result.text).toContain('0.6.5')
  })

  it('上下文超窗：给出 /compact 的动作建议', () => {
    const result = mod.explainError('{"code":"CONTEXT_WINDOW_EXCEEDED","message":"too long"}')
    expect(result.kind).toBe(mod.KIND_CONTEXT_OVERFLOW)
    expect(result.text).toContain('/compact')
  })

  it('大小写不影响判定', () => {
    expect(mod.explainError('agent_busy').kind).toBe(mod.KIND_BUSY)
    expect(mod.explainError('AGENT_BUSY').kind).toBe(mod.KIND_BUSY)
  })

  it('网络类错误可重试', () => {
    const result = mod.explainError('Error: connect ECONNREFUSED 127.0.0.1:8080')
    expect(result.kind).toBe(mod.KIND_NETWORK)
    expect(result.retryable).toBe(true)
  })

  it('路径越界：说明只能读会话工作区', () => {
    const result = mod.explainError('path escape detected: ../../etc/passwd is not within session cwd')
    expect(result.kind).toBe(mod.KIND_PATH_DENIED)
  })

  it('未命中时保留原文，不吞细节', () => {
    const result = mod.explainError('something odd happened in the host')
    expect(result.kind).toBe(mod.KIND_UNKNOWN)
    expect(result.text).toBe('something odd happened in the host')
    expect(result.retryable).toBe(false)
  })

  it('超过 160 字的原文会被截断', () => {
    const long = 'x'.repeat(400)
    const result = mod.explainError(long)
    expect(result.kind).toBe(mod.KIND_UNKNOWN)
    expect(result.text.length).toBe(161)
    expect(result.text.endsWith('…')).toBe(true)
  })

  it('空输入给一句可重试的兜底文案', () => {
    const result = mod.explainError('   ')
    expect(result.kind).toBe(mod.KIND_UNKNOWN)
    expect(result.retryable).toBe(true)
    expect(result.text).not.toBe('')
  })

  it('auth 规则命中 401 不影响网络规则的 4xx 判断顺序', () => {
    expect(mod.explainError('HTTP 401 Unauthorized').kind).toBe(mod.KIND_AUTH)
  })
})
