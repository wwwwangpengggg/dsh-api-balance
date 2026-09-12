/**
 * 保证仓库里所有 .ps1 都带 UTF-8 BOM。
 *
 * Windows PowerShell 5.1 对没有 BOM 的 .ps1 按本地 ANSI 代码页解码，脚本里的中文会变成
 * 乱码——而乱码会落在**字符串字面量**里，直接把脚本解析坏掉。症状是「脚本完全不运行、
 * 又没有任何明显报错」，非常难查。所以 BOM 是脚本的一部分，不是编辑器偏好。
 *
 * 这里扫全仓库而不是只盯着那一个文件：新增一个 .ps1 却忘了加 BOM，是最容易复发的形态。
 *
 * @module dsh-api-balance/scripts/ensure-bom
 */
import { readFileSync, readdirSync, writeFileSync } from 'node:fs'
import { dirname, join, relative } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = dirname(dirname(fileURLToPath(import.meta.url)))
const BOM = Buffer.from([0xef, 0xbb, 0xbf])
const SKIP_DIRS = new Set(['.git', 'node_modules'])

/** 递归收集所有 .ps1 文件。 */
function collectPowerShellFiles(dir) {
  const found = []
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    if (SKIP_DIRS.has(entry.name)) continue
    const full = join(dir, entry.name)
    if (entry.isDirectory()) found.push(...collectPowerShellFiles(full))
    else if (entry.name.toLowerCase().endsWith('.ps1')) found.push(full)
  }
  return found
}

const targets = collectPowerShellFiles(root)
if (targets.length === 0) {
  process.stdout.write('仓库里没有 .ps1 文件\n')
  process.exit(0)
}

let fixed = 0
for (const target of targets) {
  const bytes = readFileSync(target)
  if (bytes.subarray(0, 3).equals(BOM)) continue
  if (bytes.length === 0) {
    process.stdout.write(`跳过空文件 ${relative(root, target)}\n`)
    continue
  }
  writeFileSync(target, Buffer.concat([BOM, bytes]))
  process.stdout.write(`已为 ${relative(root, target)} 补上 UTF-8 BOM\n`)
  fixed += 1
}

if (fixed === 0) process.stdout.write(`${targets.length} 个 .ps1 都已有 UTF-8 BOM\n`)
