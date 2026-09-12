# AGENTS.md —— dsh-api-balance

本文件补充工作区根目录 `AGENTS.md` 的通用规则，写清本项目**专属**的验证方式。

## 测试命令

```powershell
npm test
```

判定标准：`node --test` 退出码为 0 且 `fail 0`。默认套件**不联网、不开窗口**，
覆盖配置解析、参数一致性、脚本 BOM 与语法、子进程生命周期、token 折叠语义，
以及「session/event → usage.json」这条接线（用假 ctx 驱动）。

两个需要显式打开的验证（它们会联网 / 会在屏幕上显示真实窗口）：

```powershell
$env:DSH_API_BALANCE_LIVE = '1';   npm test   # 真实凭据抓一次余额
$env:DSH_API_BALANCE_WINDOW = '1'; npm test   # 真的拉起窗口，4 秒后收掉
```

涉及改动 `assets/balance-window.ps1` 或 `lib/config.js` 时，**两个都要跑**，因为默认套件
证明不了「窗口真的能起来」。

## 本地实际验证

1. 改完代码，`npm test` 必须全绿；
2. 桌面版 DSH 已通过 `$DSH_HOME/profiles/web` 的 junction 引用本目录（见 README「安装」），
   所以直接**重启 DSH**，桌面右上角就应当出现余额小窗；
3. 重启后确认：余额与 `npm run probe` 的输出一致、拖动后位置被记住、点 `×` 能关掉、
   退出 DSH 后窗口自动消失。

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
7. **token 折叠语义必须与 DSH token-meter 保持一致**（`assistant/chunk` 与
   `assistant/message` 对同一步报同一份用量，是替换而非叠加）。改动 `lib/usage.js` 的
   折叠逻辑前先读 `@deepseek-ai/dsh-token-meter` 的 `usage-projection`，并保证
   `tests/usage.test.mjs` 里的「不重复计数」用例仍然通过。
