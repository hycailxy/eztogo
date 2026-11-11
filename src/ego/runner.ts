import { spawn, spawnSync } from "node:child_process";
import { existsSync, mkdirSync, readdirSync, readFileSync, rmSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { homedir, tmpdir } from "node:os";

/**
 * ego-browser 的调用封装。
 *
 * ego 没有 MCP server，只提供一个嵌入式 Node 运行时：`ego-browser nodejs < script.mjs`。
 * 脚本里用它的 TaskSpace/Page API 操作真实浏览器。这里负责：
 *  - 找到 CLI（稳定 junction → 最新版本目录 → PATH）
 *  - 把脚本写成 UTF-8 .mjs 再执行（Windows PowerShell 5.1 会撕裂带引号的 -e 参数）
 *  - 收集 stdout/stderr 并返回
 *  - 缓存 `ego-browser skill` 指南，并清理历史脚本
 *
 * 注意（2026-11-09）：ego **不提供**名为 `ego` 的 npm 包。
 * `ego-browser nodejs -e "require.resolve('ego')"` 必然报 MODULE_NOT_FOUND，
 * 那条命令从来不是 ego 通道的健康指标。真正的探针是 `typeof taskSpace === "function"`，
 * 已封装为 ego_doctor 工具。
 */

export interface ResolvedEgo {
  command: string;
  /** 这条路径怎么来的，用于诊断。 */
  source: "env" | "active_version_dir" | "application_scan" | "path" | "bare";
}

const EGO_SHARE_DIR = join(homedir(), ".local", "share", "ego");
const ACTIVE_VERSION_DIR = join(EGO_SHARE_DIR, "active_version_dir");
const APPLICATION_DIRS = [
  join(process.env.ProgramFiles ?? "C:\\Program Files", "Citro Labs", "ego lite", "Application"),
  join(process.env["ProgramFiles(x86)"] ?? "C:\\Program Files (x86)", "Citro Labs", "ego lite", "Application"),
];

function exeExists(p: string): boolean {
  try {
    return existsSync(p) && statSync(p).isFile();
  } catch {
    return false;
  }
}

/** 从 Application 目录里挑版本号最高的子目录。ego 升级会新增版本目录，旧目录可能仍在。 */
function newestApplicationBinary(): string | undefined {
  let best: { version: number[]; path: string } | undefined;
  for (const dir of APPLICATION_DIRS) {
    if (!existsSync(dir)) continue;
    let entries: string[];
    try {
      entries = readdirSync(dir);
    } catch {
      continue;
    }
    for (const name of entries) {
      if (!/^\d+(\.\d+)+$/.test(name)) continue;
      const candidate = join(dir, name, "ego-browser.exe");
      if (!exeExists(candidate)) continue;
      const version = name.split(".").map((part) => Number(part));
      if (!best || compareVersions(version, best.version) > 0) best = { version, path: candidate };
    }
  }
  return best?.path;
}

function compareVersions(a: number[], b: number[]): number {
  const len = Math.max(a.length, b.length);
  for (let i = 0; i < len; i += 1) {
    const diff = (a[i] ?? 0) - (b[i] ?? 0);
    if (diff !== 0) return diff;
  }
  return 0;
}

/**
 * 解析 ego-browser 可执行文件。
 *
 * 优先级说明：
 *  1. EGO_BROWSER_EXE —— 显式覆盖，排障用。
 *  2. ~/.local/share/ego/active_version_dir —— ego 自维护的 junction，升级自动跟随，
 *     是最稳的入口（旧版硬编码 0.6.2.7 会在 ego 升级当天失效）。
 *  3. Program Files 下版本号最高的 Application 目录 —— junction 缺失时兜底。
 *  4. PATH 扫描 —— spawn(shell:false) 不走 PATHEXT，必须自己补 .exe/.cmd。
 *  5. 裸名 —— 让调用方拿到 spawn 的真实 ENOENT 而不是被静默吞掉。
 */
export function resolveEgoCommandInfo(): ResolvedEgo {
  const fromEnv = process.env.EGO_BROWSER_EXE;
  if (fromEnv && exeExists(fromEnv)) return { command: fromEnv, source: "env" };

  const junction = join(ACTIVE_VERSION_DIR, "ego-browser.exe");
  if (exeExists(junction)) return { command: junction, source: "active_version_dir" };

  const newest = newestApplicationBinary();
  if (newest) return { command: newest, source: "application_scan" };

  const path = process.env.PATH ?? "";
  for (const dir of path.split(";")) {
    if (!dir) continue;
    const trimmed = dir.replace(/[\\/]+$/, "");
    for (const name of ["ego-browser.exe", "ego-browser.cmd", "ego-browser.bat", "ego-browser"]) {
      const full = `${trimmed}\\${name}`;
      if (exeExists(full)) return { command: full, source: "path" };
    }
  }
  return { command: "ego-browser", source: "bare" };
}

export function resolveEgoCommand(): string {
  return resolveEgoCommandInfo().command;
}

let versionCache: { command: string; text: string } | undefined;

/** `ego-browser --version` 的第一行，例如 `ego-browser 0.6.2.7`。失败返回 undefined。 */
export function egoVersion(): string | undefined {
  const { command } = resolveEgoCommandInfo();
  if (versionCache?.command === command) return versionCache.text;
  try {
    const cli = spawnSync(command, ["--version"], { encoding: "utf8", windowsHide: true, timeout: 20_000 });
    const text = `${cli.stdout ?? ""}${cli.stderr ?? ""}`.trim();
    const first = text.split(/\r?\n/).find((line) => line.trim().length > 0)?.trim();
    if (first) {
      versionCache = { command, text: first };
      return first;
    }
  } catch {
    /* 版本拿不到不是致命错误 */
  }
  return undefined;
}

export interface EgoRunResult {
  ok: boolean;
  stdout: string;
  stderr: string;
  /** stdout + stderr：ego 在管道模式下把 console.log 也写到 stderr，所以必须合并看。 */
  output: string;
  exitCode: number | null;
  scriptPath: string;
  /** 失败时给 agent 的可执行建议。 */
  hint?: string;
}

const RUN_DIR = join(tmpdir(), "dsh-ego-runs");
const RUN_KEEP_COUNT = 40;
const RUN_KEEP_MS = 24 * 60 * 60 * 1000;

/** 清理历史脚本：保留最近 N 个和 24 小时内的，其余删掉。失败不影响执行。 */
function pruneRuns(): void {
  let entries: Array<{ path: string; mtime: number }>;
  try {
    entries = readdirSync(RUN_DIR)
      .filter((name) => name.endsWith(".mjs"))
      .map((name) => {
        const path = join(RUN_DIR, name);
        let mtime = 0;
        try {
          mtime = statSync(path).mtimeMs;
        } catch {
          mtime = 0;
        }
        return { path, mtime };
      })
      .sort((a, b) => b.mtime - a.mtime);
  } catch {
    return;
  }
  const now = Date.now();
  entries.forEach((entry, index) => {
    if (index < RUN_KEEP_COUNT && now - entry.mtime <= RUN_KEEP_MS) return;
    try {
      rmSync(entry.path, { force: true });
    } catch {
      /* 被占用就下次再删 */
    }
  });
}

/**
 * 把失败输出翻译成一条能直接照做的建议。
 *
 * 重点是那道假警报：ego 没有 `ego` 包，任何 `require('ego')` / `import 'ego'`
 * 都是错的写法。这个提示会写进 MCP 返回值，避免下次又把它当成通道故障。
 */
function diagnoseFailure(output: string): string | undefined {
  if (/Cannot find (module|package) 'ego'/.test(output)) {
    return [
      "ego 不提供名为 `ego` 的 npm 包，`require('ego')` / `import ... from \"ego\"` 必然失败，这不代表通道坏了。",
      "正确用法：脚本里直接用全局助手 taskSpace(name) / claimTaskSpace(id)，页面来自 task.page(\"p1\")。",
      "需要确认通道健康请调用 ego_doctor。",
    ].join("\n");
  }
  if (/EGO_TASK_SPACE_NAME_IN_USE/.test(output)) {
    return "该 TaskSpace 名属于用户自己开的空间。换一个新名字，或经用户同意后用 claimTaskSpace(id) 接管。";
  }
  if (/await is only valid in async functions/.test(output)) {
    return "语法错误通常意味着 shell 把脚本撕裂了。已改为 .mjs 文件 + await import() 形式，若仍报错说明脚本自身有语法问题。";
  }
  if (/no running instance|ECONNREFUSED|Failed to connect|not connected/i.test(output)) {
    return "连接不到运行中的 ego(lite)。确认 ego 桌面应用正在运行；ego.exe 未启动时嵌入式运行时无法附着。";
  }
  return undefined;
}

/**
 * 运行一段 ego 脚本。脚本是 ESM，支持顶层 await，可使用 taskSpace/page 等全局助手。
 */
export async function runEgo(
  script: string,
  options: { timeoutMs?: number; cwd?: string } = {},
): Promise<EgoRunResult> {
  mkdirSync(RUN_DIR, { recursive: true });
  pruneRuns();
  const scriptPath = join(RUN_DIR, `round-${Date.now()}-${Math.random().toString(36).slice(2, 7)}.mjs`);
  // 必须是 UTF-8 无 BOM；ego 的 Node 运行时按 UTF-8 解析。
  writeFileSync(scriptPath, script, { encoding: "utf8" });

  const { command, source } = resolveEgoCommandInfo();
  const url = `file:///${scriptPath.replace(/\\/g, "/")}`;
  const args = ["nodejs", "-e", `await import('${url}')`];
  const timeoutMs = options.timeoutMs ?? 120_000;

  return await new Promise<EgoRunResult>((resolve) => {
    let settled = false;
    let timer: NodeJS.Timeout | undefined;
    const finish = (result: EgoRunResult) => {
      if (settled) return;
      settled = true;
      if (timer) clearTimeout(timer);
      resolve(result);
    };

    let child: ReturnType<typeof spawn>;
    try {
      child = spawn(command, args, {
        cwd: options.cwd ?? process.cwd(),
        windowsHide: true,
        shell: false,
      });
    } catch (error) {
      const message = String(error);
      finish({
        ok: false,
        stdout: "",
        stderr: message,
        output: message,
        exitCode: null,
        scriptPath,
        hint: `无法启动 ego-browser（解析结果：${command}，来源：${source}）。设置 EGO_BROWSER_EXE 指向 ego-browser.exe 再试。`,
      });
      return;
    }

    let stdout = "";
    let stderr = "";
    timer = setTimeout(() => {
      child.kill();
    }, timeoutMs);

    child.stdout?.on("data", (chunk: Buffer) => {
      stdout += chunk.toString("utf8");
    });
    child.stderr?.on("data", (chunk: Buffer) => {
      stderr += chunk.toString("utf8");
    });
    child.on("error", (error) => {
      const merged = `${stdout}${stderr}${String(error)}`;
      finish({
        ok: false,
        stdout,
        stderr: `${stderr}${String(error)}`,
        output: merged,
        exitCode: null,
        scriptPath,
        hint: `无法启动 ego-browser（解析结果：${command}，来源：${source}）。设置 EGO_BROWSER_EXE 指向 ego-browser.exe 再试。`,
      });
    });
    child.on("close", (code) => {
      const output = `${stdout}${stderr}`;
      finish({
        ok: code === 0,
        stdout,
        stderr,
        output,
        exitCode: code,
        scriptPath,
        hint: code === 0 ? undefined : diagnoseFailure(output),
      });
    });
  });
}

const SKILL_CACHE = join(tmpdir(), "dsh-ego-skill.md");
const SKILL_END_MARKER = "[ego-browser:skill] end of guide";

export interface EgoSkillGuide {
  text: string;
  cached: boolean;
  version?: string;
  error?: string;
}

function readCachedGuide(): string | undefined {
  try {
    const text = readFileSync(SKILL_CACHE, "utf8");
    // 必须走完整个指南；被截断的缓存按未命中处理。
    if (text.includes(SKILL_END_MARKER)) return text;
  } catch {
    /* 无缓存 */
  }
  return undefined;
}

/**
 * 读取 `ego-browser skill` 的输出，并写入缓存。
 *
 * 旧实现只读不写，导致每次 ego_skill 都 spawn 一个 CLI 进程；同时它还会先空跑一次
 * runEgo（多开一个 ego 进程和任务空间）——这两处都已修掉。
 * force=true 时忽略缓存重新取（ego 升级后指南会变）。
 */
export function getEgoSkillGuide(options: { force?: boolean } = {}): EgoSkillGuide {
  if (!options.force) {
    const cached = readCachedGuide();
    if (cached) {
      const version = /end of guide (v[\d.]+)/.exec(cached)?.[1];
      return { text: cached, cached: true, version };
    }
  }

  const { command, source } = resolveEgoCommandInfo();
  try {
    const cli = spawnSync(command, ["skill"], { encoding: "utf8", windowsHide: true, timeout: 60_000 });
    const text = `${cli.stdout ?? ""}${cli.stderr ?? ""}`;
    if (cli.error || !text.includes(SKILL_END_MARKER)) {
      return {
        text: "",
        cached: false,
        error: `ego-browser skill 取指南失败（exit=${cli.status ?? "null"}，命令=${command}，来源=${source}）${
          cli.error ? `：${String(cli.error)}` : ""
        }`,
      };
    }
    writeFileSync(SKILL_CACHE, text, { encoding: "utf8" });
    const version = /end of guide (v[\d.]+)/.exec(text)?.[1];
    return { text, cached: false, version };
  } catch (error) {
    return { text: "", cached: false, error: `ego-browser skill 调用异常：${String(error)}` };
  }
}

/** 兼容旧调用点：只要文本。 */
export function readEgoSkillGuide(): { text: string; cached: boolean } {
  const guide = getEgoSkillGuide();
  return { text: guide.text, cached: guide.cached };
}
