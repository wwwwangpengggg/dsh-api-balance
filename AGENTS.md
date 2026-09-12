# AGENTS.md —— dsh-api-balance

写给在本仓库工作的 AI 代理，也写给人类贡献者。这里的每一条约束都是踩过坑总结出来的，
**改代码之前先读一遍**，尤其是「硬约束」那一节。

---

## 这是什么

一个 DSH（DeepSeek Harness）桌面插件：启动后在桌面角落常驻一个置顶小窗，显示
DeepSeek API 余额与本次开机消耗的 token。

它由**两半**组成，改代码前先确认你要动的是哪一半：

| 半边 | 位置 | 跑在哪 | 职责 |
|---|---|---|---|
| 宿主插件 | `lib/` | DSH 的 Node 进程 | 启动/收掉小窗进程；统计 token 用量并写文件 |
| 小窗本体 | `assets/balance-window.ps1` | 独立的 `powershell.exe` 进程 | 取余额、画界面、托盘、右键菜单、位置记忆 |

**两侧唯一的通信方式是文件**，没有 IPC：宿主写 `usage.json`，小窗写 `state.json`
与 `spending.json`（今日消费的记账）。
这样设计是为了让密钥与抓取逻辑都留在一个进程里，也让小窗不依赖 DSH 主窗口。

## 项目结构

```
lib/index.js      插件入口：apply / 用量接线 / 小窗控制器 / 窗口生命周期
lib/config.js     配置解析（纯函数）+ 传给 PowerShell 的参数构造
lib/usage.js      token 用量折叠（纯函数；语义见硬约束第 15 条）
lib/window.js     子进程启动、退出通知、强制清理
assets/balance-window.ps1   小窗全部实现（单文件，约 1300 行）
cordis.patch.yml  组合层：把 api-balance 这一行插进 profile
tests/            测试；两个需要显式开关的验证不联网/不开窗口
scripts/ensure-bom.mjs      修正脚本的 UTF-8 BOM（原因见硬约束第 6 条）
```

两侧都**没有构建步骤**：`lib/` 是直接可加载的 ESM，`.ps1` 是直接可执行的脚本。
别引入打包器或转译步骤——安装方是 `dsh plugin add`，没有构建阶段。

## 测试与验证

```powershell
npm test        # 判定标准：退出码 0 且 fail 0
```

默认套件**不联网、不开窗口**，覆盖：配置解析、参数一致性、脚本 BOM 与语法、
子进程生命周期、小窗开关控制器、token 折叠语义、「session/event → usage.json」接线、
以及脚本自带的 `-LogicTest`（今日消费的累计口径）。

两个需要显式打开的验证（会联网 / 会在屏幕上显示真窗口）：

```powershell
$env:DSH_API_BALANCE_LIVE = '1';   npm test   # 真实凭据抓一次余额
$env:DSH_API_BALANCE_WINDOW = '1'; npm test   # 真窗口：拉起 → 点 × 收托盘 → 托盘叫回来
```

**改 `assets/balance-window.ps1` 或 `lib/config.js` 时两个都要跑**——默认套件证明不了
「窗口真的能起来」「× 真的只是收托盘」。

CI（`.github/workflows/ci.yml`）在 `windows-latest` 上只跑默认套件。用 Windows 是因为
小窗本体是 PowerShell + WinForms，解析检查与托盘自检只有 Windows 跑得起来。

### 装到本机手动验证

```powershell
# 1) 确认要装进哪个 profile（别猜）：桌面版读启动器里的 DSH_DESKTOP_DEFAULT_PROFILE，
#    通常就是 desktop；也可以用「启动时被改写的那个 <profile>/cordis.yml」反推。
# 2) 免启动检查这一行进没进组合树：
dsh --profile desktop --dump-config        # 里面应当恰好有一条 id: api-balance
# 3) 重启 DSH，看桌面右上角
```

窗口没出现时，**第一个该查的地方**是 `$DSH_HOME/plugins/dsh-api-balance/usage.json`
存不存在：它由插件 `apply` 的第一件事写出，**文件不存在就等于「这一行压根没挂上」**，
问题在 profile / loader；文件在而窗口不在，才去查 PowerShell。

---

## 硬约束

### 安全

1. **API Key 不得进入命令行、日志或 DSH 的 IPC。** 小窗进程自己去读环境变量或凭据文件。
   `tests/config.test.mjs` 有一条断言 `sk-` 不出现在参数里——别把它删了。
2. **状态文件的写者不能混：一个文件只能有一个写者。** `state.json`（位置/主题/背景）与
   `spending.json`（今日消费的记账）只由小窗写，`usage.json` 只由宿主插件写。
   让两个进程写同一个文件会互相覆盖；要加状态就另开文件。

### 组合与安装

3. **`api-balance` 这一行全流程只能插一次。** 它由本包自带的 `cordis.patch.yml` 插入；
   使用者的 profile 补丁层里**不要**再插一遍——loader 撞到重复 id 会抛
   `duplicate loader entry id`，而补丁文件出错是在启动时 fail-loud 的，等于把 profile 搞挂。
   要调配置就按 id 覆盖。改完用 `--dump-config` 数一遍，必须是 1。
4. **不要假设改配置会热加载。** `dsh-app-boot` 里有 `watchUserPatches`，但实测改
   `cordis.patch.yml` 不触发重组。所有安装/配置改动都以「重启 DSH 后生效」为准。
5. **不要在 DSH 运行期间对 profile 跑 `pnpm install`。** pnpm 要重写被运行中进程锁定的
   `@napi-rs/canvas-win32-x64-msvc`，会以 `ERR_PNPM_EPERM` 失败并可能留下 `*_tmp_*` 目录。
   这是装任何 DSH 插件都会遇到的，不是本插件特有；README 里已把它写成安装前置步骤。

### 小窗本体（PowerShell / WinForms）

6. **`assets/balance-window.ps1` 必须保持 UTF-8 BOM。** Windows PowerShell 5.1 对无 BOM 的
   `.ps1` 按本地 ANSI 代码页解码，脚本里的中文字符串会变乱码，**直接把脚本解析坏掉**，
   症状是「窗口完全不出现、日志里又没有任何明显错误」。
   → 改完脚本、启动它之前，先跑 `node scripts/ensure-bom.mjs`（`npm test` 会顺带跑）。
   插件启动时也会检查并大声警告（`warnIfScriptLacksBom`）。
7. **消息循环只能用「`DoEvents` + 短睡」的手工泵**，别换成 `ShowDialog` 或 `Application.Run`。
   两者都实测不可用：`ShowDialog` 的模态循环在窗体变「不可见」时就结束，于是「× 收进托盘」
   会顺手结束进程；`Application.Run`（含空 `ApplicationContext`）在这个宿主里会立刻返回。
   手工泵是唯一同时满足「能隐藏窗口」和「定时器照常触发」的方案。
8. **WinForms 事件处理器里不要用 `Write-Output`**——它的输出没有管道接收，会被静默丢掉；
   要打印就用 `[Console]::Out.WriteLine`（见 `Write-SelfTest`）。同理，处理器里给变量赋值
   必须带 `$script:` 前缀，否则只写进处理器的局部作用域。这两个坑都让自检「看起来」失败过。
9. **绘制有三条规矩，别改回去：**
   - Paint 处理器里**必须先 `$g.Clear(...)` 或画满背景再画内容**。把底色留给 WinForms 去擦
     会产生「先闪一帧纯底色、再出现文字」，就是肉眼看到的闪烁。
   - 画布必须开双缓冲（`Enable-DoubleBuffering`，反射调 protected 的 `SetStyle`）。
   - **任何 `Invalidate` 之前先判断内容是否真的变了**。窗口每 2 秒醒一次读 token 用量，
     无条件重绘就是每 2 秒白闪一次。实测：空闲 10 秒的重绘从 6 次降到 2 次（只剩启动那两帧）。
10. **脚本要在最开头声明 DPI 感知，布局坐标一律走 `Px`。**
    `powershell.exe` 默认 DPI 不感知，Windows 会把整个窗口位图按缩放比拉伸（125% 下
    276 逻辑像素被拉成 345 物理像素），字会发虚。新增任何像素常量都要包一层 `Px`，
    否则在高 DPI 下会错位。字体用 point，GDI+ 自己按 DPI 换算，字号不用动。
    `state.json` 里的 `dpiScale` 用来把老坐标换算到当前坐标系——去掉会让窗口跳到左上角。
11. **测量窗口尺寸时，测量进程自己也要 DPI 感知。** 不感知的进程拿到的 `GetWindowRect`
    是被系统缩放过的**虚拟**坐标（345 会读成 276），据此会得出「DPI 没生效」的错误结论。
12. **背景图要在载入时就缩小**（缩到卡片物理尺寸的 2 倍）。4K 壁纸整张常驻内存要 38MB，
    且每次重绘都现缩一遍要 25ms，肉眼能看出卡顿。缩放后是 1.2MB / 2.5ms。

### 配置与数据口径

13. **脚本的 `param` 块与 `buildWindowArgs` 必须同步。** 新增参数时两边都要改，
    `tests/config.test.mjs` 会把不一致直接变成测试失败。
    **状态文件路径尤其要盯住**：v0.2.0 发出去过一个「`-SpendPath` 只加进了配置对象、忘了加进
    参数数组」的错，后果是「今日消费」整页永远显示「等待取数」，而**所有测试仍然全绿**——
    因为当时没有任何断言看着它。现在三个状态文件的开关都被逐个点名断言（`-StatePath` /
    `-UsagePath` / `-SpendPath`），删掉任何一个都会立刻变红（已验证过）。
14. **主题表与蒙版表在 JS 和 PS 里各有一份，必须一致。** 漏同步会表现为「配置通过了但窗口
    不认识这个名字」——静默回落成默认值，很难查。测试会核对两份清单。
15. **token 折叠语义必须与 DSH 的 token-meter 保持一致**：`assistant/chunk` 与
    `assistant/message` 会对同一步各报一次用量，**是替换而非叠加**。改 `lib/usage.js` 的
    折叠逻辑前先读 `@deepseek-ai/dsh-token-meter` 的 `usage-projection`，并保证
    `tests/usage.test.mjs` 里「不重复计数」的用例仍然通过。
    总数 = 输入 + 输出 + 缓存读 + 缓存写；缓存命中单价更低，所以 **token 数不等于花费**。

16. **换页用「点金额区域」，不要改成左右滑动。** 卡片本身靠拖动移动位置，横向滑动会和拖拽
    抢同一个手势，怎么调都会有一边不跟手。命中区域是 `$script:FlipRect`，在 Paint 里按当前
    尺寸重算；「刷新」、「×」和最底下那一行必须留在区域外，否则会误翻页。
17. **`-LogicTest` 是 PowerShell 侧唯一的单测入口，别删也别绕开。**「余额下降才算消费、
    充值不计入、跨天与换币种重开」这套口径写在 `.ps1` 里，Node 侧调不动；
    `tests/window-script.test.mjs` 跑它并断言 `LOGICTEST PASS`。改记账逻辑必须同步改那里的用例。
18. **今日消费是近似值，不是账单。** 余额接口没有明细，只能按余额减少量倒推：充值不计入、
    换天与换币种从零重开、DSH 关着那段时间的花费不记入。任何文案都不能把它说成精确消费额。
19. **「一天」是「8 点起算的 24 小时」，不是自然日**（起点由 `dayStartHour` 配，默认 8）。
    判定只认 `Get-SpendingDayKey` 产出的 `dayKey`——它同时表示「哪一天」与「几点起算」，并且
    要显示在页面上（「08:00 起算」）。**别退回 `yyyy-MM-dd` 自然日**：那会把凌晨连续工作的
    那一夜按 0 点切成两天，用户看到的数字会莫名其妙减半。

---

## 提交约定

- **每次改动配套一次 commit**，信息里写清「为什么」而不只是「改了什么」。
- 交付前 `npm test` 必须全绿；动了小窗脚本或配置就再跑那两个显式开关的验证。
- 新增行为要配测试。**优先新增能被单测覆盖的纯函数**，把 PowerShell 侧留成薄薄一层——
  现在 `lib/` 里的东西几乎都是纯函数，这是刻意的。
- 无法单测的部分（真实的 Windows 消息、FormClosing 管线、托盘菜单）用 `-SelfTest` 开关
  驱动自检，并让 `tests/tray.test.mjs` 断言它的输出。这是目前唯一能覆盖那部分代码的手段。
