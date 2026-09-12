/**
 * 保证 assets/balance-window.ps1 带 UTF-8 BOM。
 *
 * Windows PowerShell 5.1 对没有 BOM 的 .ps1 按本地 ANSI 代码页解码，脚本里的中文
 * 会变成乱码（窗口标题、状态文字全废）。所以 BOM 是这份资产的一部分，不是编辑器
 * 偏好；任何一次手改之后跑一下这个脚本即可复原。
 *
 * @module dsh-api-balance/scripts/ensure-bom
 */
import { readFileSync, writeFileSync } from 'node:fs'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

const root = dirname(dirname(fileURLToPath(import.meta.url)))
const target = join(root, 'assets', 'balance-window.ps1')
const BOM = Buffer.from([0xef, 0xbb, 0xbf])

const bytes = readFileSync(target)
if (bytes.subarray(0, 3).equals(BOM)) {
  process.stdout.write('balance-window.ps1 已有 UTF-8 BOM\n')
  process.exit(0)
}

writeFileSync(target, Buffer.concat([BOM, bytes]))
process.stdout.write('已为 balance-window.ps1 补上 UTF-8 BOM\n')
