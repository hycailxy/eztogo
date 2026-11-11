#!/usr/bin/env node
import { copyFileSync, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { homedir } from "node:os";
import { fileURLToPath } from "node:url";

/**
 * eztogo 的命令行入口。
 *
 * 三种用法：
 *   eztogo                     → 启动 MCP（stdio），给客户端用
 *   eztogo --print-config      → 打印各客户端要贴的配置片段，不动任何文件
 *   eztogo init [--npx]        → 检测已安装的 MCP 客户端并把 eztogo 写进它们的配置
 *
 * 为什么要 init：MCP 没有统一的"安装即注册"机制，每个客户端各写各的 JSON 文件。
 * 与其让用户手抄路径，不如让包自己把绝对路径写进去——这样不依赖 PATH、不依赖 npx 缓存、
 * 换 node 版本管理器也不会失效。
 */

const SERVER_JS = resolve(fileURLToPath(new URL("./server.js", import.meta.url)));
const PACKAGE_ROOT = resolve(dirname(SERVER_JS), "..", "..");

interface ClientTarget {
  id: string;
  label: string;
  /** 配置文件绝对路径。 */
  path: string;
  /** 目录存在即认为装了该客户端。 */
  detect: string;
  /** 配置里的容器键：mcpServers（Claude/Cursor/Windsurf）或 servers（VS Code）。 */
  key: "mcpServers" | "servers";
  /** VS Code 的 mcp.json 需要显式 type:"stdio"。 */
  withType?: boolean;
  /** 官方文档地址，写进日志方便用户核对。 */
  doc?: string;
}

interface ServerEntry {
  command: string;
  args: string[];
  type?: "stdio";
}

function packageVersion(): string {
  try {
    return JSON.parse(readFileSync(join(PACKAGE_ROOT, "package.json"), "utf8")).version ?? "0.0.0";
  } catch {
    return "0.0.0";
  }
}

function clientTargets(): ClientTarget[] {
  const home = homedir();
  const appData = process.env.APPDATA || join(home, "AppData", "Roaming");
  const list: ClientTarget[] = [
    {
      id: "claude-desktop",
      label: "Claude Desktop",
      path: join(appData, "Claude", "claude_desktop_config.json"),
      detect: join(appData, "Claude"),
      key: "mcpServers",
      doc: "https://modelcontextprotocol.io/quickstart/user",
    },
    {
      id: "cursor",
      label: "Cursor",
      path: join(home, ".cursor", "mcp.json"),
      detect: join(home, ".cursor"),
      key: "mcpServers",
      doc: "https://docs.cursor.com/context/model-context-protocol",
    },
    {
      id: "windsurf",
      label: "Windsurf",
      path: join(home, ".codeium", "windsurf", "mcp_config.json"),
      detect: join(home, ".codeium"),
      key: "mcpServers",
    },
    {
      id: "vscode",
      label: "VS Code（用户级 mcp.json）",
      path: join(appData, "Code", "User", "mcp.json"),
      detect: join(appData, "Code", "User"),
      key: "servers",
      withType: true,
    },
  ];
  return list;
}

/** 默认用 node 的绝对路径 + 本包 server.js 的绝对路径：不依赖 PATH、不依赖 npx 缓存。 */
function serverEntry(useNpx: boolean): ServerEntry {
  if (useNpx) return { command: "npx", args: ["-y", "eztogo"] };
  return { command: process.execPath, args: [SERVER_JS] };
}

function shaped(target: ClientTarget, entry: ServerEntry): ServerEntry {
  return target.withType ? { type: "stdio", ...entry } : entry;
}

function readJson(path: string): { ok: true; data: Record<string, unknown> } | { ok: false; reason: string } {
  if (!existsSync(path)) return { ok: true, data: {} };
  try {
    const raw = readFileSync(path, "utf8");
    if (!raw.trim()) return { ok: true, data: {} };
    const parsed = JSON.parse(raw);
    if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) {
      return { ok: false, reason: "顶层不是 JSON 对象" };
    }
    return { ok: true, data: parsed as Record<string, unknown> };
  } catch (error) {
    return { ok: false, reason: (error as Error).message };
  }
}

function stamp(): string {
  const d = new Date();
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}-${pad(d.getHours())}${pad(d.getMinutes())}${pad(d.getSeconds())}`;
}

type InstallResult =
  | { status: "written"; path: string; backup?: string }
  | { status: "unchanged"; path: string }
  | { status: "absent"; path: string }
  | { status: "invalid"; path: string; reason: string }
  | { status: "failed"; path: string; reason: string };

function installInto(target: ClientTarget, entry: ServerEntry): InstallResult {
  if (!existsSync(target.detect)) return { status: "absent", path: target.path };

  const current = readJson(target.path);
  if (!current.ok) return { status: "invalid", path: target.path, reason: current.reason };

  const doc = current.data;
  const bucket = (doc[target.key] as Record<string, unknown> | undefined) ?? {};
  const next = shaped(target, entry);
  const existing = bucket.eztogo as ServerEntry | undefined;
  // 已经写成一样就跳过：重复跑 init 不该产生新的备份文件
  if (existing && JSON.stringify(existing) === JSON.stringify(next)) {
    return { status: "unchanged", path: target.path };
  }

  doc[target.key] = { ...bucket, eztogo: next };

  try {
    let backup: string | undefined;
    if (existsSync(target.path)) {
      backup = `${target.path}.bak-${stamp()}`;
      copyFileSync(target.path, backup);
    } else {
      mkdirSync(dirname(target.path), { recursive: true });
    }
    writeFileSync(target.path, `${JSON.stringify(doc, null, 2)}\n`, "utf8");
    return { status: "written", path: target.path, backup };
  } catch (error) {
    return { status: "failed", path: target.path, reason: (error as Error).message };
  }
}

function printConfig(useNpx: boolean): string {
  const entry = shaped({ withType: false } as ClientTarget, serverEntry(useNpx));
  const vscodeEntry = shaped({ withType: true } as ClientTarget, serverEntry(useNpx));
  const block = { mcpServers: { eztogo: entry } };
  const vscodeBlock = { servers: { eztogo: vscodeEntry } };
  return [
    "# Claude Desktop / Cursor / Windsurf：把这段并进它的配置文件",
    JSON.stringify(block, null, 2),
    "",
    "# VS Code（.vscode/mcp.json 或用户级 mcp.json）",
    JSON.stringify(vscodeBlock, null, 2),
    "",
    "# 走 npm 的写法（发布到 npm 后可用）",
    JSON.stringify({ mcpServers: { eztogo: { command: "npx", args: ["-y", "eztogo"] } } }, null, 2),
  ].join("\n");
}

function help(): string {
  return [
    `eztogo ${packageVersion()} — 电脑操控（Windows UIA）+ 浏览器操控的统一 MCP`,
    "",
    "用法：",
    "  eztogo                 启动 MCP server（stdio），由 MCP 客户端调用",
    "  eztogo init            检测已安装的 MCP 客户端，把 eztogo 写进它们的配置",
    "  eztogo init --npx      同上，但写 npx 形式（要求本包已发布到 npm）",
    "  eztogo --print-config  只打印配置片段，不改任何文件",
    "",
    "环境变量：",
    "  EZTOGO_POWERSHELL    powershell.exe 的绝对路径（默认从 PATH 找）",
    "  HYBRID_ACI_CU_OVERLAY=0        关闭屏幕上的光标/胶囊/边缘光叠加层",
    "  HYBRID_ACI_CU_REDUCED_MOTION=1 关闭滑行与涟漪动画（录屏用）",
    "  EGO_BROWSER_EXE     ego-browser 可执行文件路径（浏览器工具用）",
    "",
    "注意：电脑操控只在 Windows 10/11 上可用；其它平台上浏览器工具照常，桌面工具会返回明确错误。",
  ].join("\n");
}

/**
 * 处理 CLI 参数。
 * @returns true 表示这条命令已被处理（调用方应退出）；false 表示应当启动 MCP server。
 *
 * 判断方式是"白名单"：只有明确认识子命令才拦下来，其余一律当 MCP 启动。
 * 这样客户端往 args 里塞什么杂项参数都不会导致 server 起不来——起不来才是最糟的失败。
 */
export function runCli(argv: string[]): boolean {
  const first = (argv[0] ?? "").trim();
  const known = new Set(["init", "print-config", "--print-config", "help", "--help", "-h", "--version", "-v", "--mcp", "mcp"]);
  if (!known.has(first)) return false;

  if (first === "--help" || first === "-h" || first === "help") {
    console.log(help());
    return true;
  }

  if (first === "--version" || first === "-v") {
    console.log(packageVersion());
    return true;
  }

  if (first === "--print-config" || first === "print-config") {
    console.log(printConfig(argv.includes("--npx")));
    return true;
  }

  if (first === "init") {
    const useNpx = argv.includes("--npx");
    const entry = serverEntry(useNpx);
    console.log(`eztogo ${packageVersion()}`);
    console.log(`启动命令：${entry.command} ${entry.args.join(" ")}`);
    console.log("");
    let touched = 0;
    let invalid = 0;
    for (const target of clientTargets()) {
      const result = installInto(target, entry);
      switch (result.status) {
        case "written":
          touched += 1;
          console.log(`✔ ${target.label}  ${result.path}`);
          if (result.backup) console.log(`  原文件已备份：${result.backup}`);
          break;
        case "unchanged":
          console.log(`= ${target.label}  已经是这个配置，未改动  ${result.path}`);
          break;
        case "absent":
          console.log(`- ${target.label}  未检测到安装，跳过`);
          break;
        case "invalid":
          invalid += 1;
          console.log(`! ${target.label}  ${result.path} 不是合法 JSON（${result.reason}），未改动`);
          break;
        case "failed":
          invalid += 1;
          console.log(`✖ ${target.label}  写入失败：${result.reason}`);
          break;
      }
    }
    console.log("");
    if (touched === 0 || invalid > 0) {
      console.log("需要手工合并的片段：");
      console.log(printConfig(useNpx));
    }
    if (touched > 0) {
      console.log(`已更新 ${touched} 个客户端配置，重启客户端即可看到 eztogo 的工具。`);
    }
    return true;
  }

  // init / print-config 之外的认识项是 --mcp、mcp → 启动 server
  return false;
}
