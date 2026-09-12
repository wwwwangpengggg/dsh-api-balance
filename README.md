# dsh-api-balance

DSH 桌面插件：**打开 DeepSeek Harness 时，在桌面右上角浮出一个置顶小窗，实时显示你
DeepSeek API 账户的余额。**

```
┌──────────────────────────────┐
│ ● DeepSeek 余额     刷新  ×  │
│ ¥11.49                       │
│ 本次开机 141.6K tokens       │
│ 09:44:39 已更新 · 每 60s …   │
└──────────────────────────────┘
```

## 它是什么形态

一个**独立的原生 Windows 窗口**（PowerShell + WinForms），不是主窗口里的浮层：

- 无边框、圆角、半透明深色卡片，`TopMost` 常驻最上层；
- 左键拖动移动，位置记在 `$DSH_HOME/plugins/dsh-api-balance/state.json`，下次启动回到原处；
- 双击或右键菜单立即刷新；右键可切 30s / 60s / 5min 刷新、取消置顶、打开充值页、关闭；
- 点 `×` 关掉后，本次运行不再出现（下次启动 DSH 会重新出现）；
- 主窗口最小化、切换会话都不影响它。

## token 那一行的口径

「本次开机 141.6K tokens」= **这次启动 DSH 以来，所有会话（含子代理）消耗的 token 总量**。

- 数据来自宿主事件 `session/event`。插件在启动时挂上监听，所以只会看到本次开机之后
  追加的事件——「本次开机」这个口径是订阅时机自带的，不需要记基线，也不会随历史会话
  增长而虚高。
- 每一步模型调用会先后产生两个用量样本（流式过程中的 `assistant/chunk` 与最终装配的
  `assistant/message`）。直接相加会翻倍，因此这里照搬 DSH 自己 token-meter 的折叠语义：
  **同 turn/step 的新样本替换旧样本，跨步才累加**（见 `lib/usage.js`）。
- 总数 = 输入 + 输出 + 缓存读 + 缓存写。DeepSeek 的缓存命中输入单价更低，所以 token
  总数不等于花费；花费看上面那行余额。
- 插件把它写进 `$DSH_HOME/plugins/dsh-api-balance/usage.json`（原子写），小窗每 2 秒读
  一次。两个文件的归属是分开的：`state.json` 只由小窗写（窗口位置），`usage.json`
  只由插件写。

## 生命周期

| 时机 | 行为 |
|---|---|
| DSH 启动（插件行 apply） | 拉起小窗进程 `powershell.exe -File assets/balance-window.ps1` |
| 插件卸载 / DSH 正常退出 | `ctx.effect` 的清理器杀掉小窗进程（2 秒不退则 `taskkill /T /F`） |
| DSH 被强杀 / 崩溃 | 小窗自带看门狗：每 2 秒检查父进程 PID，父进程没了就自己关闭 |
| 重复拉起 | 命名互斥量保证同一时刻只有一个余额小窗（DSH 重启时最多等 8 秒让旧窗退出） |

两条清理路径互为兜底，正常退出和异常退出都不会在桌面上留下孤儿窗口。

## 密钥从哪来

小窗进程**自己**读密钥，插件不碰、不经 IPC、不出现在任何命令行里（`tests/config.test.mjs`
有一条断言专门防这件事）。读取顺序：

1. 环境变量 `DEEPSEEK_API_KEY`（可用 `credentialEnv` 改名字）；
2. `$DSH_HOME/.credentials.yaml` 里的同名键（DSH 的凭据文件，默认位置）。

接口：`GET {baseUrl}/user/balance`，请求头 `Authorization: Bearer <key>`。

## 安装

已经装进 `$DSH_HOME/profiles/web`（桌面版 DSH 用的就是这个 profile）：

- `package.json` 里加了依赖 `"dsh-api-balance": "link:<本目录>"`；
- `dsh.profile.bundles` 里追加了 `dsh-api-balance`；
- `node_modules/dsh-api-balance` 是指向本目录的 junction（`link:` 依赖物化出来的就是这个）。

所以改这里的代码立刻生效，重启 DSH 即可看到新行为。

**注意**：DSH 运行期间不要在这个 profile 里跑 `pnpm install`。pnpm 会重写
`node_modules/@napi-rs/canvas-win32-x64-msvc`，而该原生模块被正在运行的 DSH 进程
锁定，install 会以 `ERR_PNPM_EPERM` 失败。要改成 pnpm 托管的正式安装，请**先完全退出
DSH**，再执行：

```powershell
dsh plugin --profile web install
```

## 配置

改 `cordis.patch.yml`（插件自带的那份是默认值），或在
`$DSH_HOME/profiles/<profile>/cordis.patch.yml` 里按 id 覆盖：

```yaml
- id: api-balance
  config:
    enabled: true
    refreshSeconds: 60      # 10 - 3600，超出会被夹紧
    corner: top-right       # top-right / top-left / bottom-right / bottom-left
    currency: ''            # 留空 = 用接口返回的第一种；可写 CNY / USD
    baseUrl: https://api.deepseek.com
    credentialEnv: DEEPSEEK_API_KEY
    credentialFile: ''      # 留空 = $DSH_HOME/.credentials.yaml
    stateDir: ''            # 留空 = $DSH_HOME/plugins/dsh-api-balance
    instanceName: DshApiBalanceWindow
```

## 开发

```powershell
npm test              # 离线：配置解析、参数一致性、脚本 BOM 与语法、进程生命周期
npm run probe         # 只抓一次余额并打印 JSON，不开窗口（会真的联网）
```

两个默认跳过的联网/上屏测试：

```powershell
$env:DSH_API_BALANCE_LIVE = '1';   npm test   # 用真实凭据抓一次余额
$env:DSH_API_BALANCE_WINDOW = '1'; npm test   # 真的拉起窗口，4 秒后再收掉
```

### 两个容易踩的坑

1. **`assets/balance-window.ps1` 必须带 UTF-8 BOM。** Windows PowerShell 5.1 对没有
   BOM 的 `.ps1` 按本地 ANSI 解码，脚本里的中文会全部变成乱码。编辑之后跑
   `npm run prepare` 补回 BOM，`npm test` 也会先自动补一次并断言存在。

2. **脚本的 `param(...)` 块和插件构造的开关必须对得上。** 参数名写错不会报错，只会
   让窗口起不来。`tests/config.test.mjs` 会解析脚本的 `param` 块，逐一核对插件传的每
   个开关，改一边忘改另一边会直接测试失败。

## 故障排查

| 现象 | 检查 |
|---|---|
| 小窗完全不出现 | `npm run probe` 能否拿到余额；`assets/balance-window.ps1` 是否被杀软/组策略拦了 `-ExecutionPolicy Bypass` |
| 小窗显示「未配置密钥」 | `$DSH_HOME/.credentials.yaml` 里是否有 `DEEPSEEK_API_KEY`，或环境变量是否带进了 DSH 进程 |
| 小窗显示「获取失败」 | 网络/代理；余额接口返回体里是否有 `balance_infos` |
| token 行一直是 0 或「暂无数据」 | `usage.json` 是否存在且 `updatedAt` 在变；没有它说明插件没装上（`dsh --profile web --dump-config` 里应当有 `api-balance` 行） |
| DSH 退出后小窗还在 | 看门狗依赖 `-ParentPid` 参数，检查插件是否真的传了 `ParentPid` |
