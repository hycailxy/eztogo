#!/usr/bin/env node
/**
 * eztogo 的可执行入口（`npx eztogo` / 全局安装后的 `eztogo` 都走这里）。
 *
 * 刻意写得极短、且**不做静态 import**：cli.js 与 server.js 之间一旦形成模块环，
 * ESM 的顶层 await 会互相等待，Node 直接报 "Detected unsettled top-level await" 退出——
 * 那正是"装上了却连不上"的典型形态。这里用动态 import 把两棵依赖树完全隔开。
 */
const args = process.argv.slice(2);

let handled = false;
try {
  const { runCli } = await import("../dist/src/cli.js");
  handled = runCli(args);
} catch (error) {
  console.error(`[eztogo] CLI 引导失败：${error?.message ?? error}`);
  process.exitCode = 1;
  handled = true;
}

if (!handled) {
  const { startMcpServer } = await import("../dist/src/server.js");
  await startMcpServer();
}
