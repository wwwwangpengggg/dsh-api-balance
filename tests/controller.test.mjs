/**
 * 小窗控制器的单测：开关的幂等、失败回落，以及最要紧的一条——关掉再开之后，
 * 上一代进程迟到的 exit 回调不能把新一代的句柄清掉。
 */
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { EventEmitter } from 'node:events'

import { createWindowController, registerBalanceCommand } from '../lib/index.js'
import { resolveBalanceConfig } from '../lib/config.js'

/** 一份贴近真实的配置：buildWindowArgs 会读它的每个字段。 */
const cfg = resolveBalanceConfig(undefined, { env: { DSH_HOME: 'C:\\dsh-home' }, scriptPath: 'unused.ps1' })
const silentLog = { info: () => {}, warn: () => {} }

/** 假子进程：可以被「外部」杀掉以触发 exit。 */
function fakeChild(pid) {
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

/** 造一个 spawn 替身：每次调用产出一个新子进程，并记录调用次数。 */
function fakeSpawn() {
  const children = []
  const spawnImpl = (command, args) => {
    const child = fakeChild(1000 + children.length)
    children.push(child)
    return child
  }
  return { children, spawnImpl }
}

test('open/close 各自幂等，并报告发生了什么', () => {
  const fake = fakeSpawn()
  const controller = createWindowController(cfg, silentLog, { spawnImpl: fake.spawnImpl })

  assert.equal(controller.isOpen(), false)
  assert.equal(controller.close(), 'already-closed')
  assert.equal(controller.toggle(), 'opened')
  assert.equal(controller.isOpen(), true)
  assert.equal(controller.open(), 'already-open')
  assert.equal(controller.toggle(), 'closed')
  assert.equal(controller.isOpen(), false)
  assert.equal(fake.children[0].killCalls, 1)
})

test('从托盘退出后控制器能重新打开（exit 回调清掉句柄）', () => {
  const fake = fakeSpawn()
  const controller = createWindowController(cfg, silentLog, { spawnImpl: fake.spawnImpl })

  controller.open()
  assert.equal(controller.isOpen(), true)

  // 用户从托盘菜单退出：进程自己结束，插件靠 exit 回调感知。
  fake.children[0].emit('exit', 0)
  assert.equal(controller.isOpen(), false, '进程退出后控制器应当认为小窗已关闭')

  assert.equal(controller.open(), 'opened', '关掉之后必须还能再打开')
  assert.equal(fake.children.length, 2)
})

test('上一代进程迟到的 exit 不会误清新一代的句柄', () => {
  const fake = fakeSpawn()
  const controller = createWindowController(cfg, silentLog, { spawnImpl: fake.spawnImpl })

  controller.open()
  controller.close()            // 主动关：控制器已把句柄置空
  controller.open()             // 立刻重开，这一代才是当前的
  fake.children[0].emit('exit', 0)   // 上一代的退出事件现在才到

  assert.equal(controller.isOpen(), true, '新一代被上一代的 exit 回调误清了')
  assert.equal(controller.open(), 'already-open')
})

test('spawn 失败时报 failed，且不会把状态卡在「已打开」', () => {
  const controller = createWindowController(cfg, silentLog, {
    spawnImpl: () => {
      throw new Error('boom')
    },
  })

  assert.equal(controller.open(), 'failed')
  assert.equal(controller.isOpen(), false, '启动失败不能留下「正在开」的假状态')
})

test('进程 error 事件同样会清掉句柄', () => {
  const fake = fakeSpawn()
  const controller = createWindowController(cfg, silentLog, { spawnImpl: fake.spawnImpl })

  controller.open()
  fake.children[0].emit('error', new Error('ENOENT'))
  assert.equal(controller.isOpen(), false)
})

test('没有命令注册表时，/balance 只留下说明、不报错', () => {
  const controller = createWindowController(cfg, silentLog, { spawnImpl: fakeSpawn().spawnImpl })
  const logs = []
  const ctx = { get: () => undefined, effect: () => () => {} }

  registerBalanceCommand(ctx, controller, { info: (m) => logs.push(m), warn: (m) => logs.push(m) })
  assert.ok(logs.some((line) => line.includes('/balance')), '跳过时应当留下说明')
})

test('/balance 注册进命令表，并且能真的开关小窗', () => {
  const fake = fakeSpawn()
  const controller = createWindowController(cfg, silentLog, { spawnImpl: fake.spawnImpl })
  const registered = []
  let disposer = null

  const ctx = {
    get: (name) => (name === 'commands' ? {
      register: (definition) => {
        registered.push(definition)
        return () => { disposer = 'disposed' }
      },
    } : undefined),
    effect: (callback) => {
      callback()
      return () => {}
    },
  }

  registerBalanceCommand(ctx, controller, silentLog)

  assert.equal(registered.length, 1)
  assert.equal(registered[0].name, 'balance')
  assert.ok(registered[0].description.length > 0)

  const opened = registered[0].handler({})
  assert.equal(opened.kind, 'success')
  assert.match(opened.text, /已打开/)
  assert.equal(controller.isOpen(), true)

  const closed = registered[0].handler({})
  assert.match(closed.text, /已关闭/)
  assert.equal(controller.isOpen(), false)
})

test('命令表注册抛错时只降级，不把插件拖挂', () => {
  const controller = createWindowController(cfg, silentLog, { spawnImpl: fakeSpawn().spawnImpl })
  const logs = []
  const ctx = {
    get: () => ({ register: () => { throw new Error('registry exploded') } }),
    effect: (callback) => { callback(); return () => {} },
  }

  assert.doesNotThrow(() => registerBalanceCommand(ctx, controller, {
    info: (m) => logs.push(m),
    warn: (m) => logs.push(m),
  }))
  assert.ok(logs.some((line) => line.includes('注册 /balance 失败')))
})
