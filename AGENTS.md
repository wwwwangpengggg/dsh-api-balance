# AGENTS.md —— dsh-api-balance

本文件补充工作区根目录 `AGENTS.md` 的通用规则，写清本项目**专属**的验证方式。

## 测试命令

```powershell
npm test
```

判定标准：`node --test` 退出码为 0 且 `fail 0`。默认套件**不联网、不开窗口**，
覆盖配置解析、参数一致性、脚本 BOM 与语法、子进程生命周期、小窗开关控制器
（含「关掉后再打开」的代际隔离）、token 折叠语义，以及「session/event → usage.json」
这条接线（用假 ctx 驱动）。

两个需要显式打开的验证（它们会联网 / 会在屏幕上显示真实窗口）：

```powershell
$env:DSH_API_BALANCE_LIVE = '1';   npm test   # 真实凭据抓一次余额
$env:DSH_API_BALANCE_WINDOW = '1'; npm test   # 真窗口：拉起 → 点 × 收托盘 → 从托盘叫回来
```

涉及改动 `assets/balance-window.ps1` 或 `lib/config.js` 时，**两个都要跑**，因为默认套件
证明不了「窗口真的能起来」「× 真的只是收托盘」。

## 本地实际验证

1. 改完代码，`npm test` 必须全绿；
2. 确认要装进哪个 profile（**别猜**）：桌面版读启动器
   `%APPDATA%\DSH Desktop\host-commands\desktop\bin\dsh.cmd` 里的
   `DSH_DESKTOP_DEFAULT_PROFILE`（当前是 `desktop`）；也可以用「启动时 `cordis.yml`
   被改写的那个 profile」反推。两个 profile 装着同一批其他插件，所以**不能**用
   「哪些插件生效」来判断当前用的是哪个；
3. 用 `dsh --profile <name> --dump-config` 免启动确认 `api-balance` 行进了组合树；
4. **重启 DSH**，桌面右上角就应当出现余额小窗；
5. 重启后确认：余额与 `npm run probe` 的输出一致、token 行随对话增长、拖动后位置被记住、
   **点 `×` 是收进托盘**（托盘图标双击能叫回来）、托盘「退出小窗」后 `/balance` 能再拉起来、
   退出 DSH 后窗口与托盘图标一起消失；
6. 窗口没出现时，先查 `$DSH_HOME/plugins/dsh-api-balance/usage.json` 存不存在。
   **它由 apply 的第一件事写出：文件不存在就等于「这一行压根没挂上」**，问题在
   profile / loader，不在脚本或窗口；文件在而窗口不在，才去查脚本与 PowerShell。

## 本项目的硬约束

1. **每次改动都要配套 commit**（沿用工作区根 `AGENTS.md` 的规则）。
2. **`assets/balance-window.ps1` 必须保持 UTF-8 BOM。** 很多编辑工具会静默去掉它，
   一旦去掉，PowerShell 5.1 会把中文读成乱码。改完跑 `npm run prepare`，`npm test`
   会断言 BOM 在不在。
3. **脚本 `param` 块与 `buildWindowArgs` 必须同步。** 新增参数时两边都要改，
   `tests/config.test.mjs` 会把不一致直接变成测试失败。
4. **API Key 不得进入命令行、日志或 DSH 的 IPC。** 小窗进程自己去读环境变量或凭据文件；
   `tests/config.test.mjs` 有一条断言 `sk-` 不出现在参数里。
5. **不要在 DSH 运行期间对该 profile 跑 `pnpm install`。** pnpm 会重写被运行中进程锁定的
   `@napi-rs/canvas-win32-x64-msvc`，以 `ERR_PNPM_EPERM` 失败，并可能留下
   `*_tmp_*` 目录（发现后应删除）。需要 pnpm 托管安装时先完全退出 DSH。
6. **两个状态文件的所有权不能混。** `state.json` 只由小窗写（窗口位置），`usage.json`
   只由宿主插件写（token 用量）。让两个进程写同一个文件会互相覆盖；新增状态时另开文件。
7. **`api-balance` 这一行全流程只能插一次。** 它由本包自带的 `cordis.patch.yml` 插入；
   profile 的 `cordis.patch.yml` 里**不要**再插一遍——loader 撞到重复 id 会抛
   `duplicate loader entry id`，而补丁文件出问题是在启动时 fail-loud 的，
   等于把这个 profile 整个搞挂。要调配置就按 id 覆盖。
   改完务必用 `dsh --profile <name> --dump-config` 数一遍 `id: api-balance` 出现几次，
   必须是 1。
8. **不要假设改配置会热加载。** `dsh-app-boot` 有 `watchUserPatches`，但桌面版实测
   改 `cordis.patch.yml` 不触发重组。所有安装/配置改动都以「重启 DSH 后生效」为准。
9. **token 折叠语义必须与 DSH token-meter 保持一致**（`assistant/chunk` 与
   `assistant/message` 对同一步报同一份用量，是替换而非叠加）。改动 `lib/usage.js` 的
   折叠逻辑前先读 `@deepseek-ai/dsh-token-meter` 的 `usage-projection`，并保证
   `tests/usage.test.mjs` 里的「不重复计数」用例仍然通过。
10. **消息循环只能用「DoEvents + 短睡」的手工泵，别换成 ShowDialog 或 Application.Run。**
    两者都实测不行：ShowDialog 的模态循环在窗体变不可见时就结束，于是「× 收进托盘」会
    顺手结束进程；Application.Run（含空 ApplicationContext）在这个宿主里会立刻返回，
    压根泵不起来。手工泵是唯一同时满足「能隐藏窗口」和「定时器照常触发」的方案。
11. **WinForms 事件处理器里不要用 `Write-Output`。** 它的输出没有管道接收，会被静默丢掉；
    要往外打印就用 `[Console]::Out.WriteLine`（`Write-SelfTest` 就是这么写的）。
    同理，处理器里给变量赋值必须带 `$script:` 前缀，否则只写进了处理器的局部作用域——
    这两个坑都让自检「看起来」失败过，各花了一轮排查。
12. **画东西的两条规矩，别改回去：**
    - Paint 处理器里**必须先 `$g.Clear(Card)` 把底色铺满再画内容**，不能只画边框和文字、
      把底色留给 WinForms 去擦——那会「先闪一帧纯底色、再出现文字」，就是用户看到的闪烁。
    - 面板必须开双缓冲（`Enable-DoubleBuffering`，反射调 protected 的 `SetStyle`）。
    - 任何 `Invalidate` 之前先判断内容是否真的变了（`Set-View` / `Update-UsageView` 里的
      比较）：窗口每 2 秒醒一次读 token 用量，无条件重绘就是每 2 秒白闪一次。
    实测：空闲 10 秒的重绘从 6 次降到 2 次（只剩启动那两帧），抓帧掉帧数从 3/836 降到 0/276。
