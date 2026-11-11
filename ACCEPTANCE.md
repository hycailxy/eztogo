# eztogo 验收记录

> 这是开发机上的原始验收记录，按时间倒序堆叠：里面保留了当时的机器细节（分辨率、PID、路径、逐条实测数字）。
> 目的是让"这功能真的跑过"可追溯，而不是一份整理过的宣传文档。

# 2026-11-09 · hybrid-aci 已退役

## 结论
一个 MCP = 复刻 Codex Computer Use 的 9 个工具（带动画叠加层）+ 浏览器操控（默认原生 ego，可选 Edge）+ ego 原生逃生口，共 23 个工具。
**hybrid-aci 已整体退役（改名 `hybrid-aci.retired-20261109`），eztogo 不再读取它任何文件。**

## 目录
```
eztogo/
  src/cu/         电脑操控 9 工具 + 叠加层桥
  src/ego/        ego 原生封装
  src/browser/    浏览器操控（ego 默认 / edge 可选）
  dist/src/edge/  Edge 宿主（browser/snapshot/policy/host/client 的已编译副本）
  desktop/        desktop-uia.ps1 + overlay/codex-cursor.ps1
  node_modules/   独立实体（不再联接到 hybrid-aci）
```

## 退役做的事
1. Edge 宿主源码编译产物搬进 `eztogo/dist/src/edge/`（共 41 个文件），运行时只从自己加载
2. `node_modules` 从指向 hybrid-aci 的 junction 改成实体拷贝，并补建 92 个 pnpm 顶层 junction
3. `cu/server.ts` 的桌面桥路径由写死 hybrid-aci 改成 `import.meta.url` 推导
4. DSH home patch 删除 ego-mcp / computer-use-mcp 两条，去掉 EZTOGO_EDGE_ROOT
5. OMB config 同步去掉 EZTOGO_EDGE_ROOT
6. `hybrid-aci/` → `hybrid-aci.retired-20261109/`

## 退役后全量实测（全部 ok）
```
桌面：list_apps / get_app_state / click / type_text / press_key / scroll / set_value / drag
ego ：navigate / type / click / evaluate / screenshot
edge：navigate / type(ref) / click(ref) / screenshot
ego 原生：ego_skill
```

## 这轮修的路径 bug（同类，都是相对层级算错）
- `import.meta.url` + `../../desktop/...` → 应为 `../../../desktop/...`（dist/src/cu 到 eztogo 要退三级）
- edge client 用 `../../edge/client` → 应为 `../edge/client`（dist/src/browser 退两级到 dist，再进 edge）

教训：**相对路径改完要打印实际解析结果并 existsSync 验证**，不能只看编译通过。

## 配置文件状态
- `~/.dsh/cordis.patch.yml`：rea-mcp / craft-anything-mcp / eztogo-mcp，无 hybrid-aci 残留，js-yaml 解析通过
- `~/.dsh/openmausbot/config.json`：mcpServers 只有 eztogo，ESC 环境变量仅 EZTOGO_EGO_SPACE，JSON 解析通过

## 仍然存在的边界
- edge 没有 `evaluate`（HostSession 无此方法），返回明确说明
- edge 的 select/assert 尚未逐一验证
## 补丁：叠加层不再"无脑常驻"（2026-11-10）

### 现象
一个只调了 browser_navigate + browser_evaluate、完全没碰电脑操控的会话，屏幕上照样出现了胶囊和边缘光。

### 根因
修冷启动时我在 `ensureOverlay()` 里加了一句 `write({ op: "hold" })`，位置在 spawn 之后。
`hold` 会把 `$script:holdVisible` 置真，而 tick 里有"hold 期间每帧确保胶囊和边缘光可见"的兜底 ——
于是**任何 eztogo 进程一启动，叠加层就常驻显示**，与是否发生桌面动作无关。

### 修法
删掉 spawn 后的那句 hold。进程照旧在服务器启动时 warm（解决冷启动），但**不显示任何东西**；
胶囊只在真正的动作 op（点/打字/滚/拖）到来时才出现——动作 op 自身带"确保可见"。

### 复测
```
只调浏览器：命令 {"seq":0,"op":"hide"}   diag vis=Collapsed   → 屏幕上什么都没有
调 get_app_state+click：命令 {"seq":2,"op":"act",...}  diag vis=Visible w=313 → 胶囊出现
```

## 光标旁的说明改成"实时说明"（2026-11-11）

### 改之前
光标右下角那行字取自状态文案（`Agent 正在控制` / `你正在控制`），一个任务从头到尾几乎不变，
看起来像装饰而不是"它现在在干嘛"。

### 改之后
每个动作把自己的说明写在同一条命令里（单文件通道只保留最后一次写入，所以必须原子跟着 op 走）：

| 动作 | 光标旁写 |
| --- | --- |
| click | `点击「保存」` |
| perform_secondary_action | `执行 Press「保存」` |
| scroll | `下滚「正文编辑区」`（上/下/左/右） |
| set_value | `填写「正文编辑区」` |
| press_key | `按键 ctrl+a` |
| type_text | `输入 12 个字`（只报字数，不把正文写屏） |
| drag | `拖拽「正文编辑区」→「保存」` |
| 每次动作后的重读 | `读取「记事本」`（finish 阶段立刻换字） |

- 元素名取 UIA `name`，没有就退回角色名（button/document…），超过 12 字截断成 `…`，说明框不会被拉成一条。
- 说明框贴屏幕右/下边时自动翻到指针左侧/上方（滑行过程中每次位置变化都重算）。
- 状态变化（接管/暂停/结束）会复位成状态文案，所以"谁在控制"和"在做什么"不会互相打架。
- 纯读工具（list_apps / get_app_state）只在叠加层已活着时写说明，不为了一行字去新起 WPF 进程。

### 顺手修掉的一个真 bug
叠加层读命令文件用的是 `File.ReadAllText`（只允许共享读），会把 Node 的 `writeFileSync` 挡在门外，
偶发的 EBUSY 就是"命令被吞、说明没刷新"的来源。改成显式 `FileShare.ReadWrite` 的 FileStream。

### 复测（全部实测，不是看代码）
1. `pwsh -NoProfile -File scripts/caption-check.ps1` → `{"ok":true,"diffCaptionChange":365,"diffSecondAction":4037}`（说明变字时说明框像素真的变了）
2. `node tests/cu-caption-e2e.mjs` → 真 MCP server + 真叠加层，只把桌面桥换成 `tests/mock-uia-bridge.ps1`，7 条说明全部命中：`读取「MockApp」/点击「保存」/输入 5 个字/按键 ctrl+a/下滚「正文编辑区」/填写「正文编辑区」/拖拽「正文编辑区」→「保存」`
3. 真机：计算器点"六"，截屏实测说明框写 `点击「六」`（截图为 17:54:02 连拍的帧，说明框在 1.2s 内随光标淡出）

### 两个坑
- **`edit`/`write` 工具写 .ps1 会丢掉 UTF-8 BOM**：Windows PowerShell 5.1 按 ANSI 读无 BOM 的脚本，中文字符串直接乱码、脚本语法报错退出（叠加层起不来）。改完必须补 BOM：`[System.IO.File]::WriteAllText($f, $txt, (New-Object System.Text.UTF8Encoding($true)))`。
- **函数不能叫 `Diff`**：`diff` 是 `Compare-Object` 的内置别名，别名优先级高于函数，函数永远不会被调用（返回 null）。

## 开源打包前的可移植性审计（2026-11-11）

问题：这台机器跑得通，不代表一台"什么都没配"的电脑装上就能跑。逐项实测了 5 个场景。

### 修掉的 4 个硬伤

| # | 硬伤 | 实测表现 | 修法 |
| --- | --- | --- | --- |
| 1 | 桌面桥 spawn 失败没有 error listener | `spawn powershell.exe` ENOENT → **uncaughtException 直接杀掉 MCP 进程**，客户端报 "Connection closed"，23 个工具全没 | `Bridge.ensureChild()` 注册 `on("error")`，把错误转成这次调用的 reject；`callOneShot` 同样包装成可读错误；非 Windows 直接短路返回说明 |
| 2 | `private: true` + 没有 `bin` | `npm publish` 直接被拒；装完用户只能手抄 `dist/src/server.js` 绝对路径 | 去掉 private、加 `bin/eztogo.mjs`、加 `files`（精确到文件，避免 `.bak-*`/测试进包） |
| 3 | 没有一键配置入口 | "npm 装完自动配好"不成立：MCP 各客户端配置格式与路径都不同 | 新增 `eztogo init` / `eztogo --print-config`：检测 Claude Desktop / Cursor / Windsurf / VS Code，合并写入 + 备份原文件 + 非法 JSON 不写 |
| 4 | 启动就亮 2.5 秒胶囊 | 任何客户端一连上，屏幕上先闪一段"Agent 任务 / Agent 正在控制"，看起来像 bug | 叠加层加 `sessionOpened`：没收到过 start / 动作 op 一律不显示胶囊 |

### 顺带修的

- `eztogo init` 与 `server.js` 之间的**静态模块环**导致 ESM 顶层 await 互等，Node 报 `Detected unsettled top-level await` 直接退出（装上就连不上）。改成 `bin/eztogo.mjs` 用动态 import 隔开两棵依赖树，`server.js` 不再静态 import `cli.js`。
- 叠加层在服务会话（`SESSIONNAME=Services`）里不再起全屏窗口。
- `EZTOGO_POWERSHELL` 环境变量：PATH 里没有 powershell.exe 时可以指定绝对路径。

### 实测矩阵（都在 `%TEMP%` 里全新解包、`npm install` 后再跑）

| 场景 | 结果 |
| --- | --- |
| 干净安装 `node node_modules/eztogo/bin/eztogo.mjs` | connect ok，23 工具，`get_app_state` 真实读到窗口树 |
| 用 `init` 写出的配置（node + server.js 绝对路径）启动 | connect ok，23 工具，真实调用成功 |
| `EZTOGO_POWERSHELL` 指向不存在 | 工具返回「找不到 powershell.exe…请用 EZTOGO_POWERSHELL」，**进程存活**，浏览器工具照常 |
| `EGO_BROWSER_EXE` 指向坏文件 | `browser_navigate` 返回「spawn UNKNOWN + 解析结果 + 修法」，`ego_doctor` 报 ok:false，桌面工具之后仍可用 |
| 启动后 3 秒读叠加层 diag | `vis=Collapsed`（以前是 Visible） |
| `init` 对已有配置 | 合并保留其它 server、备份 `.bak-时间戳`、坏 JSON 不动、重复执行 `已经是这个配置，未改动` |
| `npm pack` 清单 | 80 文件 / 122KB，无 `.bak-*`、无 `src/`、无 `tests/` |

### 仍然只能靠文档说明的边界

- 电脑操控只有 Windows（UIA）；非 Windows 上桌面工具返回明确错误，浏览器工具照常
- `engine="edge"` 需要用户自己 `npm i playwright`（不放进 dependencies，否则每个用户凭空多几百 MB）
- 杀软把 `powershell.exe` 或全屏叠加层判可疑时，需要用户加白名单（错误信息已说明怎么处理）
- 多个 MCP 客户端同时拉起会有多个叠加层窗口


