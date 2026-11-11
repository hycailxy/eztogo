#!/usr/bin/env node
import { resolve } from "node:path";
import { fileURLToPath } from "node:url";

/**
 * eztogo — 一个 MCP 同时提供：
 *
 *   1) 电脑操控：list_apps / get_app_state / click / perform_secondary_action /
 *      scroll / set_value / press_key / type_text / drag
 *      —— 复刻 Codex Computer Use 的 9 个工具，动作时驱动叠加层动画
 *      （光标滑行、点击涟漪、状态胶囊、边缘光）。
 *
 *   2) 浏览器操控：browser_* —— 默认引擎是原生 ego-browser，
 *      engine="edge" 时走 Playwright/Edge 宿主（需要另装 playwright）。
 *
 *   3) ego 原生接口：ego_run / ego_page / ego_skill（需要写自由脚本时的逃生口）。
 *
 * 入口分两种：
 *   - 这个文件被直接执行（node dist/src/server.js）→ 起 stdio MCP server
 *   - 被 cli.js 导入 → 由 CLI 决定（init / print-config / 起 server）
 */
export async function startMcpServer(): Promise<void> {
  const { McpServer } = await import("@modelcontextprotocol/sdk/server/mcp.js");
  const { StdioServerTransport } = await import("@modelcontextprotocol/sdk/server/stdio.js");
  const { mountCu } = await import("./cu/server.js");
  const { ensureOverlay } = await import("./cu/overlay.js");
  const { mountEgo } = await import("./ego/server.js");
  const { mountBrowser } = await import("./browser/server.js");

  const server = new McpServer({ name: "eztogo", version: "0.1.0" });
  mountCu(server);
  mountEgo(server);
  mountBrowser(server);

  // 启动就把叠加层拉起来（进程常驻、默认不可见）：
  // 否则第一次动作要等 2-3 秒冷启动，动画整个错过——这正是"看不到动画"的主因之一。
  try {
    ensureOverlay();
  } catch {
    // 叠加层只是装饰，失败不影响工具
  }

  await server.connect(new StdioServerTransport());
}

/** 直接 `node dist/src/server.js` 启动（DSH 等现有配置就是这么写的，必须继续可用）。 */
async function main(): Promise<void> {
  const invokedDirectly = process.argv[1] ? resolve(process.argv[1]) === fileURLToPath(import.meta.url) : false;
  if (!invokedDirectly) return; // 被别人 import，调用方自己决定

  const args = process.argv.slice(2);
  const first = (args[0] ?? "").trim();
  // 有子命令就交给 CLI；注意这里是**动态** import——cli.js 与 server.js 之间绝不能有静态环，
  // 否则 ESM 顶层 await 会互等，Node 直接报 unsettled top-level await 退出。
  if (first && first !== "--mcp" && first !== "mcp") {
    const { runCli } = await import("./cli.js");
    if (runCli(args)) return;
  }

  if (process.platform !== "win32") {
    console.error("[eztogo] 非 Windows 平台：电脑操控工具会返回明确错误，浏览器工具照常可用");
  }
  await startMcpServer();
}

await main();
