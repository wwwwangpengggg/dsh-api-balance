/**
 * lib/window.js 的单测：用假的 spawn 覆盖启动、日志、以及 stop() 的幂等与兜底强杀，
 * 不真正开任何窗口。
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { EventEmitter } from 'node:events'

import { startBalanceWindow } from '../lib/window.js'

/** 造一个够用的子进程替身。 */
function fakeChild(pid = 4321) {
  const child = new EventEmitter()
  child.pid = pid
  child.stdout = new EventEmitter()
  child.stderr = new EventEmitter()
  child.killCalls = 0
  child.kill = () => {
    child.killCalls += 1
    return true
  }
  return child
}

/** 收集日志的替身。 */
function fakeLog() {
  const lines = { info: [], warn: [] }
  return {
    lines,
    info: (message) => lines.info.push(message),
    warn: (message) => lines.warn.push(message),
  }
}

test('正常启动：把 command/args/cwd 原样交给 spawn，返回 pid', () => {
  const child = fakeChild(777)
  const seen = {}
  const log = fakeLog()
  const handle = startBalanceWindow({
    command: 'powershell.exe',
    args: ['-File', 'x.ps1'],
    cwd: 'C:\\plugin',
    log,
    spawnImpl: (command, args, options) => {
      seen.command = command
      seen.args = args
      seen.options = options
      return child
    },
  })

  assert.equal(seen.command, 'powershell.exe')
  assert.deepEqual(seen.args, ['-File', 'x.ps1'])
  assert.equal(seen.options.cwd, 'C:\\plugin')
  assert.equal(seen.options.windowsHide, true, '不应闪出控制台窗口')
  assert.deepEqual(seen.options.stdio, ['ignore', 'pipe', 'pipe'])
  assert.equal(handle.pid, 777)
})

test('stop() 幂等：重复调用只杀一次进程', () => {
  const child = fakeChild()
  const handle = startBalanceWindow({
    command: 'powershell.exe',
    args: [],
    cwd: '.',
    log: fakeLog(),
    spawnImpl: () => child,
  })

  handle.stop()
  handle.stop()
  handle.stop()
  assert.equal(child.killCalls, 1)
})

test('进程退出后再 stop() 不再补刀', () => {
  const child = fakeChild()
  const log = fakeLog()
  const handle = startBalanceWindow({
    command: 'powershell.exe',
    args: [],
    cwd: '.',
    log,
    spawnImpl: () => child,
  })

  child.emit('exit', 0)
  handle.stop()
  assert.equal(child.killCalls, 0)
  assert.ok(log.lines.info.some((line) => line.includes('已关闭')), '应当在日志里留下退出记录')
})

test('子进程 error 事件只记警告，不抛出', () => {
  const child = fakeChild()
  const log = fakeLog()
  startBalanceWindow({
    command: 'nope.exe',
    args: [],
    cwd: '.',
    log,
    spawnImpl: () => child,
  })

  child.emit('error', new Error('ENOENT'))
  assert.ok(log.lines.warn.some((line) => line.includes('ENOENT')))
})

test('spawn 同步抛错时返回 null，而不是让插件加载失败', () => {
  const log = fakeLog()
  const handle = startBalanceWindow({
    command: 'nope.exe',
    args: [],
    cwd: '.',
    log,
    spawnImpl: () => {
      throw new Error('spawn 失败')
    },
  })

  assert.equal(handle, null)
  assert.ok(log.lines.warn.some((line) => line.includes('无法启动余额小窗')))
})

test('脚本的输出会被转成带前缀的日志', () => {
  const child = fakeChild()
  const log = fakeLog()
  startBalanceWindow({
    command: 'powershell.exe',
    args: [],
    cwd: '.',
    log,
    spawnImpl: () => child,
  })

  child.stderr.emit('data', Buffer.from('未找到凭据\n'))
  assert.ok(log.lines.info.some((line) => line.includes('未找到凭据')))
})
