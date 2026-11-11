# eztogo

一个 MCP server，把两件事装进同一条通道：

- **电脑操控**：按 Windows 辅助功能树（UIA）驱动任意桌面程序——列窗口、读控件树、点击、输入、滚动、拖拽，并在屏幕上画出光标滑行、点击涟漪、任务胶囊、边缘光，让人看得见 agent 在干什么。
- **浏览器操控**：默认走 [ego lite](https://egolite.com)（真实浏览器 + 登录态），也可以切到 Playwright/Edge 宿主。

23 个工具，一个进程，一个 stdio 连接。

> **English**: eztogo is a single MCP server for Windows computer control (UIA, with an on-screen cursor / click ripple / status pill overlay) and browser automation (ego lite by default, Playwright/Edge optional). Run `npx -y eztogo init` to register it into Claude Desktop / Cursor / Windsurf / VS Code automatically.

---

## 环境要求

| 项目 | 要求 |
| --- | --- |
| 操作系统 | 电脑操控：**Windows 10 / 11**。浏览器部分在 macOS / Linux 上也能用 |
| Node.js | ≥ 20 |
| PowerShell | Windows 自带 Windows PowerShell 5.1（`powershell.exe`），无需安装 |
| ego lite | 可选。只有用 `browser_*` 的默认引擎（ego）时才需要 |
| Playwright | 可选。只有 `engine="edge"` 时才需要（`npm i playwright`） |

非 Windows 平台上，桌面工具不会让进程崩溃，而是返回一条明确说明：`电脑操控只能在 Windows 上运行…`。

---

## 安装与配置

### 一键写进客户端配置（推荐）

```bash
npx -y eztogo init
```

它会逐个检测已安装的 MCP 客户端，把 eztogo 写成 **node 绝对路径 + 本包 server.js 绝对路径**，并打印做了什么：

```
eztogo 0.1.0
启动命令：C:\Program Files\nodejs\node.exe C:\Users\me\AppData\Local\npm-cache\_npx\...\server.js

✔ Claude Desktop  C:\Users\me\AppData\Roaming\Claude\claude_desktop_config.json
  原文件已备份：…claude_desktop_config.json.bak-20261111-181500
- Cursor  未检测到安装，跳过
```

- 支持的客户端：Claude Desktop、Cursor、Windsurf、VS Code（用户级 `mcp.json`）
- 写之前会备份原文件；配置里已有完全相同的条目则跳过，重复执行不会堆备份
- 目标文件不是合法 JSON 时**不写入**，只打印要手工合并的片段

### 只看配置，不改文件

```bash
npx -y eztogo --print-config
```

### 手工配置

Claude Desktop / Cursor / Windsurf（`mcpServers`）：

```json
{
  "mcpServers": {
    "eztogo": {
      "command": "node",
      "args": ["C:/path/to/eztogo/dist/src/server.js"]
    }
  }
}
```

VS Code（`.vscode/mcp.json` 或用户级 `mcp.json`，注意键是 `servers` 且要 `type`）：

```json
{
  "servers": {
    "eztogo": {
      "type": "stdio",
      "command": "node",
      "args": ["C:/path/to/eztogo/dist/src/server.js"]
    }
  }
}
```

从源码跑：

```bash
git clone https://github.com/hycailxy/eztogo.git
cd eztogo
npm install
npm run build
node dist/src/server.js        # 直接起 MCP（客户端配置里就写这条）
```

---

## 工具

### 电脑操控（9）

| 工具 | 作用 |
| --- | --- |
| `list_apps` | 每个可驱动窗口一行：`名字 — 进程 (pid N) [running, last-used=…, uses=…]` |
| `get_app_state` | 读一个程序的控件树，每个节点带 `element_index`，并附窗口截图 |
| `click` | 点某个 `element_index`（优先元素自带的 Invoke/Toggle，退化为移动指针+点击） |
| `perform_secondary_action` | Raise / Expand / Collapse / Press / Select |
| `scroll` | 按方向滚动元素或它的可滚动祖先 |
| `set_value` | 写值（ValuePattern）：文本框、滑块、下拉框 |
| `press_key` | 发组合键，`ctrl+a` 这种写法（`super`/`cmd` 自动映射到 ctrl） |
| `type_text` | 往当前焦点元素打字 |
| `drag` | 从元素 A 拖到元素 B（取中心点） |

### 浏览器（10）

`browser_navigate` / `browser_snapshot` / `browser_click` / `browser_type` / `browser_press_key` /
`browser_back` / `browser_wait` / `browser_screenshot` / `browser_evaluate` / `browser_engine`

`engine` 三个取值：`ego`（默认）、`edge`、`auto`。

### ego 原生逃生口（4）

`ego_run`（跑任意 ego 脚本）/ `ego_page` / `ego_skill` / `ego_doctor`（环境自检：CLI 在哪、版本、`taskSpace` 是否可用）。

---

## 屏幕上的东西

动作发生时，一个置顶透明窗口会画：

- **光标**：深色箭头 + 白描边，滑到目标点（`HYBRID_ACI_CU_REDUCED_MOTION=1` 关闭滑行与涟漪）
- **点击涟漪**：单圈扩散
- **光标旁的实时说明**：`点击「保存」` / `填写「正文编辑区」` / `按键 ctrl+a` / `输入 12 个字` / `拖拽「A」→「B」`，动作完成后立刻切成 `读取「记事本」`
- **底部胶囊**：任务名 + 状态 + 「接管 / 终止」按钮，可收成小太阳

只要不发动作，它什么都不显示（进程常驻只为省掉冷启动）。整体关掉：`HYBRID_ACI_CU_OVERLAY=0`。

---

## 环境变量

| 变量 | 默认 | 说明 |
| --- | --- | --- |
| `EZTOGO_POWERSHELL` | `powershell.exe` | PowerShell 的绝对路径，PATH 里找不到时用 |
| `HYBRID_ACI_CU_OVERLAY` | 开 | `0` = 不画任何叠加层 |
| `HYBRID_ACI_CU_REDUCED_MOTION` | 关 | `1` = 去掉滑行/涟漪（录屏、虚拟机） |
| `EZTOGO_UIA_BRIDGE` | 包内 `desktop/desktop-uia.ps1` | 自建/替换桌面桥（调试用） |
| `EZTOGO_ROOT` | 包根 | 叠加层脚本的搜索根 |
| `EGO_BROWSER_EXE` | 自动探测 | ego-browser 可执行文件路径 |
| `EZTOGO_EGO_SPACE` | `eztogo` | ego TaskSpace 名 |

---

## 排障

| 现象 | 原因与做法 |
| --- | --- |
| 客户端里看不到工具 | 配置没生效：`npx -y eztogo --print-config` 核对；重启客户端（Claude Desktop 要完全退出托盘） |
| 工具报 `找不到 powershell.exe` | PATH 里没有 PowerShell（精简 PATH、Server Core、非 Windows）。用 `EZTOGO_POWERSHELL` 指定绝对路径 |
| 工具报 `被安全软件拦住`（EACCES/EPERM） | 把 `powershell.exe` 和本包目录加入杀软白名单 |
| `engine="edge"` 报 host 没起来 | 装 `playwright`；edge 宿主是可选能力 |
| `browser_*` 报找不到 ego-browser | 装 ego lite，或用 `EGO_BROWSER_EXE` 指定；`ego_doctor` 会打印它找了哪些位置 |
| 屏幕上没有动画 | `HYBRID_ACI_CU_OVERLAY=0` 被设了？或叠加层进程被杀软拦了；不影响工具本身 |

---

## 已知限制

- 电脑操控只有 Windows；UIA 对 UWP/XAML 应用偶尔很慢（代码会自动回落到一次性调用）
- `edge` 引擎依赖 Playwright，没装就用不了（默认引擎 ego 不受影响）
- 每次动作后都会附一张窗口截图，长会话会积累图片（自动只保留最近 200 张 / 2 小时）
- 单实例假设：同一个客户端配置只会拉起一个进程；多个客户端各自拉起时会有多个叠加层窗口
- 首次动作前会先起一个常驻 PowerShell 进程（约 1 秒），用于复用 UIA 上下文

## 开发

```bash
npm run build            # tsc → dist/
npm run mcp              # 跑 server
npm run test:caption     # 叠加层"实时说明"像素级回归（Windows）
npm run test:caption:e2e # server → 叠加层命令的端到端检查（用假桌面桥，不动真实桌面）
```

`desktop/desktop-uia.ps1` 是桌面桥（UIA + 输入注入），`desktop/overlay/codex-cursor.ps1` 是叠加层。
两者都是 **UTF-8 with BOM** 的 PowerShell 脚本——用编辑器改完务必确认 BOM 还在，否则中文会乱码、脚本直接语法报错。

## 许可

MIT
