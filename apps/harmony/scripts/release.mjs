#!/usr/bin/env node
// 鸿蒙客户端发版小工具：版本 → tag → 发布说明草稿，各一步，避免手工漏项。
//
//   node apps/harmony/scripts/release.mjs --notes        # 打印发布说明骨架（可重定向到文件）
//   node apps/harmony/scripts/release.mjs --tag          # 在本仓库打本地 tag（不推远端）
//   node apps/harmony/scripts/release.mjs --tag --push   # 打 tag 并推到 origin（需要已配好凭据）
//
// 说明：真机验收结果、地址、日志按仓库规范放 PR/Release 附件，不写进 docs。
import { execFileSync } from 'node:child_process'
import { readFileSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = join(dirname(fileURLToPath(import.meta.url)), '..')
const appJson = readFileSync(join(root, 'AppScope', 'app.json5'), 'utf8')
const versionName = /"versionName":\s*"([^"]+)"/.exec(appJson)?.[1] ?? ''
const versionCode = /"versionCode":\s*(\d+)/.exec(appJson)?.[1] ?? ''

if (!versionName || !versionCode) {
  console.error('读不到 AppScope/app.json5 的版本号')
  process.exit(2)
}

const tag = `client-v${versionName.replace(/-lan$/, '')}`
const push = process.argv.includes('--push')

function notes() {
  console.log(`# ${versionName}（${versionCode}）

## 本次更新

- <!-- 用户能感知的变化，一条一句；不要写测试数、构建命令 -->

## 升级须知

- 安装需要 DevEco Studio 自行构建，发布页只提供源码。
- 旧版本可直接覆盖安装；签名材料与桌宠素材不随仓库分发。

## 已知问题

- <!-- 尚未验收或有条件限制的点 -->
`)
}

function makeTag() {
  try {
    execFileSync('git', ['rev-parse', '--verify', '-q', `refs/tags/${tag}`], { cwd: root, stdio: 'ignore' })
    console.error(`tag 已存在：${tag}（先删掉再打，避免指向旧提交）`)
    process.exit(1)
  } catch {
    // 不存在才继续
  }
  execFileSync('git', ['tag', tag], { cwd: root, stdio: 'inherit' })
  console.log(`已打本地 tag：${tag}`)
  if (push) {
    execFileSync('git', ['push', 'origin', tag], { cwd: root, stdio: 'inherit' })
    console.log(`已推送 tag：${tag}`)
  } else {
    console.log(`推送：git push origin ${tag}`)
  }
}

if (process.argv.includes('--tag')) {
  makeTag()
} else {
  notes()
}
