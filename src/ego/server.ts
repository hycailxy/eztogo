import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import {
  egoVersion,
  getEgoSkillGuide,
  resolveEgoCommandInfo,
  runEgo,
  type EgoRunResult,
} from "./runner.js";

/**
 * ego-browser 的 MCP 封装。
 *
 * ego 本身不提供 MCP server，这里把它的嵌入式 Node 运行时包装成 MCP 工具，
 * 让 DSH 会话能像调用其它 MCP 一样驱动 ego(lite)：
 *  - ego_run    跑任意 ego 脚本（完整 API 面，最通用）
 *  - ego_page   常用页面动作的快捷方式（不需要写脚本）
 *  - ego_skill  打印当前 ego 版本的使用指南（带缓存）
 *  - ego_doctor 通道自检：解析到的 exe、版本、运行时 helper、缓存状态
 *
 * 自检注意：ego **没有**名为 `ego` 的 npm 包，`require.resolve('ego')` 必然失败。
 * 判断通道是否健康看 ego_doctor 的 probe（typeof taskSpace）。
 */

const SPACE_NAME = process.env.EZTOGO_EGO_SPACE || process.env.HYBRID_ACI_EGO_SPACE || "eztogo";

export function mountEgo(server: McpServer): void {

function text(value: unknown): { content: Array<{ type: "text"; text: string }> } {
  return {
    content: [
      { type: "text", text: typeof value === "string" ? value : JSON.stringify(value, null, 2) },
    ],
  };
}

function fail(message: string): { isError: true; content: Array<{ type: "text"; text: string }> } {
  return { isError: true, content: [{ type: "text", text: message }] };
}

/** 失败信息统一带上 hint，避免 agent 再把它误读成「ego 通道坏了」。 */
function describeFailure(label: string, result: EgoRunResult): string {
  const parts = [
    `${label} 失败（exit=${result.exitCode}）`,
    `--- output ---`,
    result.output.trim() || "(empty)",
    `脚本：${result.scriptPath}`,
  ];
  if (result.hint) parts.push(`--- hint ---`, result.hint);
  return parts.join("\n");
}

server.registerTool(
  "ego_run",
  {
    title: "Run an ego-browser script",
    description:
      "Run an ego-browser (ego lite) Node script with the embedded runtime. The script is ESM with top-level await and can use taskSpace(name), task.page('p1'), page.goto(), page.snapshot(), page.click('ref=12') and the rest of the ego API. Print JSON to return structured data. Use this for anything the shortcut tools do not cover.",
    inputSchema: {
      script: z.string().min(1).describe("Full ESM script text, executed by `ego-browser nodejs`."),
      timeoutMs: z.number().int().positive().optional().describe("Hard timeout, default 120000."),
    },
    annotations: { readOnlyHint: false },
  },
  async ({ script, timeoutMs }) => {
    const result = await runEgo(script, { timeoutMs });
    const payload = {
      ok: result.ok,
      exitCode: result.exitCode,
      stdout: result.stdout.trim(),
      stderr: result.stderr.trim(),
      output: result.output.trim(),
      scriptPath: result.scriptPath,
    };
    if (!result.ok) return fail(describeFailure("ego_run", result));
    return text(payload);
  },
);

const pageAction = z.enum([
  "navigate",
  "url",
  "title",
  "snapshot",
  "click",
  "fill",
  "press",
  "scroll",
  "screenshot",
  "back",
  "forward",
  "wait",
]);

server.registerTool(
  "ego_page",
  {
    title: "Simple ego page action",
    description:
      "Convenience wrapper around one ego(lite) page in the shared TaskSpace. Actions: navigate(url), url, title, snapshot, click(refOrLocator), fill(refOrLocator,text), press(key), scroll(direction), screenshot, back, forward, wait(ms). Returns JSON; for `screenshot` the returned path is a PNG on disk.",
    inputSchema: {
      action: pageAction,
      target: z.string().optional().describe("URL for navigate, ref/locator for click/fill, key for press, direction for scroll."),
      value: z.string().optional().describe("Text for fill."),
      amount: z.number().optional().describe("Milliseconds for wait."),
    },
    annotations: { readOnlyHint: false },
  },
  async ({ action, target, value, amount }) => {
    const space = JSON.stringify(SPACE_NAME);
    const call = (expr: string) =>
      `const task = await taskSpace(${space});\nconst page = task.page("p1");\n${expr}`;

    const snippets: Record<string, string> = {
      navigate: `await page.goto(${JSON.stringify(target ?? "")}, { timeout: 30000 });\nconsole.log(JSON.stringify({ url: await page.url(), title: await page.title() }));`,
      url: `console.log(JSON.stringify({ url: await page.url() }));`,
      title: `console.log(JSON.stringify({ title: await page.title() }));`,
      snapshot: `const snap = await page.snapshot();\nconsole.log(typeof snap === "string" ? snap : JSON.stringify(snap));`,
      click: `await page.click(${JSON.stringify(target ?? "")});\nconsole.log(JSON.stringify({ clicked: ${JSON.stringify(target ?? "")}, url: await page.url() }));`,
      fill: `await page.fill(${JSON.stringify(target ?? "")}, ${JSON.stringify(value ?? "")});\nconsole.log(JSON.stringify({ filled: ${JSON.stringify(target ?? "")} }));`,
      press: `await page.press(${JSON.stringify(target ?? "Enter")});\nconsole.log(JSON.stringify({ pressed: ${JSON.stringify(target ?? "Enter")} }));`,
      scroll: `await page.mouse.wheel(0, ${target === "up" ? -600 : 600});\nconsole.log(JSON.stringify({ scrolled: ${JSON.stringify(target ?? "down")} }));`,
      screenshot: `const shot = await page.screenshot();\nconsole.log(JSON.stringify({ screenshot: typeof shot === "string" ? shot : "see stdout" , result: shot }));`,
      back: `await page.goBack({ timeout: 15000 }).catch(() => undefined);\nconsole.log(JSON.stringify({ url: await page.url() }));`,
      forward: `await page.goForward({ timeout: 15000 }).catch(() => undefined);\nconsole.log(JSON.stringify({ url: await page.url() }));`,
      wait: `await page.waitForTimeout(${Math.max(0, Math.min(Number(amount ?? 1000), 30000))});\nconsole.log(JSON.stringify({ waited: true }));`,
    };
    const snippet = snippets[action];
    if (!snippet) return fail(`未知动作：${action}`);

    const result = await runEgo(call(snippet), { timeoutMs: 180_000 });
    if (!result.ok) return fail(describeFailure(`ego_page(${action})`, result));
    return text({ ok: true, action, output: result.output.trim() });
  },
);

server.registerTool(
  "ego_skill",
  {
    title: "Print the ego-browser usage guide",
    description:
      "Return the usage guide that matches the installed ego lite version (same text as `ego-browser skill`). Cached after the first read; pass force=true after an ego upgrade. Read it before writing non-trivial ego scripts.",
    inputSchema: {
      force: z.boolean().optional().describe("Ignore the cache and re-read the guide from the CLI (use after an ego upgrade)."),
    },
    annotations: { readOnlyHint: true },
  },
  async ({ force }) => {
    const guide = getEgoSkillGuide({ force: force === true });
    if (!guide.text) return fail(guide.error ?? "ego 指南不可用");
    return text({
      version: guide.version,
      cached: guide.cached,
      bytes: guide.text.length,
      guide: guide.text,
    });
  },
);

server.registerTool(
  "ego_doctor",
  {
    title: "Check the ego(lite) channel",
    description:
      "Self-check the ego channel: which ego-browser.exe was resolved and how, the ego/Node versions, whether the embedded runtime exposes the taskSpace helper, and the skill-guide cache state. Use this instead of `require.resolve('ego')`, which always fails because ego ships no npm package named 'ego'.",
    inputSchema: {
      deep: z.boolean().optional().describe("Also create/resume the TaskSpace and report its id and page URL (default true)."),
    },
    annotations: { readOnlyHint: true },
  },
  async ({ deep }) => {
    const resolved = resolveEgoCommandInfo();
    const skill = getEgoSkillGuide();
    const report: Record<string, unknown> = {
      ok: false,
      exe: resolved.command,
      exeSource: resolved.source,
      version: egoVersion() ?? "(unknown)",
      space: SPACE_NAME,
      skillCache: { cached: skill.cached, version: skill.version, bytes: skill.text.length },
    };

    if (deep === false) {
      report.ok = resolved.source !== "bare";
      report.note = "未探测运行时 helper；deep 默认为 true。";
      return text(report);
    }

    const probe = await runEgo(
      [
        `const report = {`,
        `  hasTaskSpace: typeof taskSpace,`,
        `  hasClaimTaskSpace: typeof claimTaskSpace,`,
        `  node: process.version,`,
        `};`,
        `if (typeof taskSpace === "function") {`,
        `  const task = await taskSpace(${JSON.stringify(SPACE_NAME)});`,
        `  const page = task.page("p1");`,
        `  report.spaceId = task.spaceId;`,
        `  report.url = await page.url();`,
        `  report.title = await page.title();`,
        `}`,
        `console.log(JSON.stringify(report));`,
      ].join("\n"),
      { timeoutMs: 60_000 },
    );

    const stdout = probe.stdout.trim() || probe.stderr.trim();
    let probeReport: unknown = stdout;
    try {
      probeReport = JSON.parse(stdout.split(/\r?\n/).filter((line) => line.trim().startsWith("{")).pop() ?? "");
    } catch {
      /* 保留原始文本 */
    }

    report.exeResolvable = probe.exitCode !== null;
    report.probe = probeReport;
    report.ok =
      probe.ok &&
      typeof probeReport === "object" &&
      probeReport !== null &&
      (probeReport as { hasTaskSpace?: string }).hasTaskSpace === "function";
    if (!probe.ok) {
      report.failure = describeFailure("ego_doctor probe", probe);
    }
    return text(report);
  },
);

}
