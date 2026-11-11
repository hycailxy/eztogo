import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { z } from "zod";
import { runEgo } from "../ego/runner.js";
import { fileURLToPath, pathToFileURL } from "node:url";
import { writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

/**
 * eztogo 的浏览器操控层。
 *
 * 默认引擎是 ego lite（原生 ego-browser）：同一套动作走 ego 的自有 API，
 * 这样用户的登录态、窗口、可见性都在 ego 里，不另起一个无头浏览器。
 *
 * engine = "edge" 时，动作交给 Playwright/Edge 宿主
 * （需要用户自备 `npm i playwright`；默认 ego 引擎不依赖它）。
 */

const SPACE = process.env.EZTOGO_EGO_SPACE || "eztogo";

type Engine = "ego" | "edge";

function ok(text: string) {
  return { content: [{ type: "text" as const, text }] };
}

function fail(text: string) {
  return { content: [{ type: "text" as const, text }], isError: true };
}

/** 把字符串安全地塞进生成的 ego 脚本（JSON 转义，避免引号/换行炸脚本）。 */
function lit(value: string): string {
  return JSON.stringify(value);
}

async function ego(script: string, timeoutMs = 60_000): Promise<string> {
  const result = await runEgo(script, { timeoutMs });
  if (!result.ok) {
    throw new Error(
      `ego 执行失败（exit=${result.exitCode}）\n${result.output.slice(-2000)}${result.hint ? `\n提示: ${result.hint}` : ""}`,
    );
  }
  return result.output.trim();
}

/** 每次动作都在同一个 task space 里取第一页，保证连续动作作用在同一标签页。 */
function pageScript(body: string): string {
  return `const t = await taskSpace(${lit(SPACE)});
const page = t.page("p1");
${body}
`;
}

async function withEngine(
  engine: Engine,
  egoAction: () => Promise<string>,
  edgeAction: () => Promise<string>,
): Promise<string> {
  if (engine === "edge") return await edgeAction();
  return await egoAction();
}

/**
 * Edge 模式：交给 Playwright/Edge 宿主（可选依赖）。
 * 用动态 import + 绝对路径，避免 eztogo 自己再装一份 playwright。
 */
let edgeSession: any = null;

async function edgeHost(): Promise<{ session: any }> {
  // Edge 宿主现在就在 eztogo 自己身上：dist/src/edge/{client,host}
  const here = fileURLToPath(new URL("../edge/client", import.meta.url));
  const clientPath = join(here, "host-client.js");
  const sessionPath = join(here, "host-session.js");
  const { HostClient } = await import(pathToFileURL(clientPath).href);
  const { HostSession } = await import(pathToFileURL(sessionPath).href);
  if (!edgeSession) {
    const client = await HostClient.connect();
    edgeSession = new HostSession(client);
  }
  return { session: edgeSession };
}

export function mountBrowser(server: McpServer): void {
  const engineSchema = z
    .enum(["ego", "edge"])
    .default("ego")
    .describe("浏览器引擎：ego（默认，真实浏览器 + 登录态）/ edge（Playwright/Edge，需另装 playwright）");

  server.registerTool(
    "browser_engine",
    {
      title: "Browser engine",
      description:
        "查看 eztogo 浏览器操控当前走哪个引擎，以及 ego 是否可用。默认 ego（原生 ego-browser），需要 Edge 时各工具传 engine=\"edge\"。",
      inputSchema: {},
    },
    async () => {
      let egoOk = false;
      let egoVersion = "";
      try {
        const { resolveEgoCommand, egoVersion: v } = await import("../ego/runner.js");
        egoOk = Boolean(resolveEgoCommand());
        egoVersion = v() || "";
      } catch {
        egoOk = false;
      }
      return ok(
        [
          "engine: ego（默认）",
          `ego 可用: ${egoOk ? "是" : "否"}${egoVersion ? ` (${egoVersion})` : ""}`,
          "task space: " + SPACE,
          "edge 模式: 各工具传 engine=\"edge\"，走 Playwright/Edge 宿主（需另装 playwright）",
        ].join("\n"),
      );
    },
  );

  server.registerTool(
    "browser_navigate",
    {
      title: "Navigate",
      description: "打开一个网址并返回标题。默认 ego 引擎。",
      inputSchema: {
        url: z.string().describe("绝对 URL"),
        engine: engineSchema,
        timeout_ms: z.number().int().positive().optional(),
      },
    },
    async ({ url, engine, timeout_ms }) => {
      try {
        const text = await withEngine(
          engine as Engine,
          () =>
            ego(
              pageScript(
                `await page.goto(${lit(url)}, { timeout: ${timeout_ms ?? 25000} });
console.log("url:", await page.url());
console.log("title:", await page.title());`,
              ),
              (timeout_ms ?? 25000) + 15000,
            ),
          async () => {
            const { session } = await edgeHost();
            await session.navigate(url);
            return `navigated: ${url}`;
          },
        );
        return ok(text);
      } catch (error) {
        return fail(String((error as Error).message ?? error));
      }
    },
  );

  server.registerTool(
    "browser_snapshot",
    {
      title: "Snapshot",
      description:
        "取当前页面的结构化快照（ego 返回带 ref 的无障碍树；edge 返回同形态快照）。这是点击/输入前的定位依据，优先用它而不是坐标。",
      inputSchema: {
        engine: engineSchema,
      },
    },
    async ({ engine }) => {
      try {
        if (engine === "edge") {
          const { session } = await edgeHost();
          const snap = await session.snapshot();
          return ok(typeof snap === "string" ? snap : JSON.stringify(snap, null, 2));
        }
        const text = await ego(
          pageScript(
            `const snap = await page.snapshot();
console.log(typeof snap === "string" ? snap : JSON.stringify(snap));
console.log("url:", await page.url());`,
          ),
          90_000,
        );
        return ok(text);
      } catch (error) {
        return fail(String((error as Error).message ?? error));
      }
    },
  );

  server.registerTool(
    "browser_click",
    {
      title: "Click",
      description: "点击一个元素：传 CSS 选择器、可见文本，或快照里的 ref（ref=12）。默认 ego 引擎。",
      inputSchema: {
        target: z.string().describe("CSS 选择器 / 文本 / ref=12"),
        engine: engineSchema,
        timeout_ms: z.number().int().positive().optional(),
      },
    },
    async ({ target, engine, timeout_ms }) => {
      try {
        const text = await withEngine(
          engine as Engine,
          () =>
            ego(
              pageScript(
                `await page.click(${lit(target)}, { timeout: ${timeout_ms ?? 8000} });
console.log("clicked:", ${lit(target)});
console.log("url:", await page.url());`,
              ),
              (timeout_ms ?? 8000) + 15000,
            ),
          async () => {
            const { session } = await edgeHost();
            await session.click(target);
            return `clicked: ${target}`;
          },
        );
        return ok(text);
      } catch (error) {
        return fail(String((error as Error).message ?? error));
      }
    },
  );

  server.registerTool(
    "browser_type",
    {
      title: "Type",
      description: "往输入框填入文本。默认 ego 引擎。submit=true 时回车提交。",
      inputSchema: {
        target: z.string().describe("CSS 选择器 / 文本 / ref=12"),
        text: z.string().describe("要写入的内容"),
        submit: z.boolean().optional(),
        engine: engineSchema,
      },
    },
    async ({ target, text, submit, engine }) => {
      try {
        const out = await withEngine(
          engine as Engine,
          () =>
            ego(
              pageScript(
                `await page.fill(${lit(target)}, ${lit(text)}, { timeout: 8000 });
${submit ? `await page.press(${lit(target)}, "Enter");` : ""}
console.log("typed into:", ${lit(target)});
console.log("url:", await page.url());`,
              ),
              40_000,
            ),
          async () => {
            const { session } = await edgeHost();
            await session.type(target, text);
            return `typed into: ${target}`;
          },
        );
        return ok(out);
      } catch (error) {
        return fail(String((error as Error).message ?? error));
      }
    },
  );

  server.registerTool(
    "browser_press_key",
    {
      title: "Press key",
      description: "按键（Enter / Escape / Control+A 这类写法）。默认 ego 引擎。",
      inputSchema: {
        key: z.string(),
        engine: engineSchema,
      },
    },
    async ({ key, engine }) => {
      try {
        const out = await withEngine(
          engine as Engine,
          () =>
            ego(
              pageScript(
                `await page.keyboard.press(${lit(key)});
console.log("pressed:", ${lit(key)});`,
              ),
              30_000,
            ),
          async () => {
            const { session } = await edgeHost();
            await session.pressKey(key);
            return `pressed: ${key}`;
          },
        );
        return ok(out);
      } catch (error) {
        return fail(String((error as Error).message ?? error));
      }
    },
  );

  server.registerTool(
    "browser_evaluate",
    {
      title: "Evaluate",
      description: "在页面里执行一段 JS 并返回结果（只读用得多：取文本、取属性）。默认 ego 引擎。",
      inputSchema: {
        expression: z.string().describe("在页面上下文里求值的表达式或函数体"),
        engine: engineSchema,
      },
    },
    async ({ expression, engine }) => {
      try {
        if (engine === "edge") {
          const { session } = await edgeHost();
          return fail("edge 引擎没有 evaluate：HostSession 只暴露结构化动作。取数据请用 browser_snapshot，或改用 engine=\"ego\"。");
        }
        const out = await ego(
          `const t = await taskSpace(${lit(SPACE)});
const page = t.page("p1");
const value = await page.evaluate(() => (${expression}));
console.log(typeof value === "string" ? value : JSON.stringify(value));`,
          60_000,
        );
        return ok(out);
      } catch (error) {
        return fail(String((error as Error).message ?? error));
      }
    },
  );

  server.registerTool(
    "browser_screenshot",
    {
      title: "Screenshot",
      description: "截图并返回文件路径。默认 ego 引擎。",
      inputSchema: {
        path: z.string().optional().describe("保存路径，不传则由 ego 决定"),
        engine: engineSchema,
      },
    },
    async ({ path, engine }) => {
      try {
        if (engine === "edge") {
          const { session } = await edgeHost();
          const shot = await session.screenshot();
          const target = path || join(tmpdir(), `eztogo-edge-${Date.now()}.png`);
          writeFileSync(target, shot as Buffer);
          return ok(target);
        }
        const out = await ego(
          pageScript(
            `const shot = await page.screenshot(${path ? `{ path: ${lit(path)} }` : ""});
console.log(JSON.stringify(shot));`,
          ),
          60_000,
        );
        return ok(out);
      } catch (error) {
        const msg = String((error as Error).message ?? error);
        if (/minimi[sz]ed/i.test(msg)) {
          return fail(msg + "\n\n提示：ego 窗口最小化时无法截屏，把 ego 窗口恢复出来再试（或用 ego_page 的 snapshot 取文本）。");
        }
        return fail(msg);
      }
    },
  );

  server.registerTool(
    "browser_back",
    {
      title: "Back",
      description: "后退一页。默认 ego 引擎。",
      inputSchema: {
        engine: engineSchema,
      },
    },
    async ({ engine }) => {
      try {
        const out = await withEngine(
          engine as Engine,
          () =>
            ego(
              pageScript(
                `await page.goBack?.();
console.log("url:", await page.url());`,
              ),
              30_000,
            ),
          async () => {
            const { session } = await edgeHost();
            await session.goBack();
            return "back";
          },
        );
        return ok(out);
      } catch (error) {
        return fail(String((error as Error).message ?? error));
      }
    },
  );

  server.registerTool(
    "browser_wait",
    {
      title: "Wait",
      description: "等待一段时间或等待某个选择器出现。默认 ego 引擎。",
      inputSchema: {
        ms: z.number().int().positive().optional(),
        selector: z.string().optional(),
        engine: engineSchema,
      },
    },
    async ({ ms, selector, engine }) => {
      try {
        const body = selector
          ? `await page.waitForSelector(${lit(selector)}, { timeout: ${ms ?? 15000} });
console.log("appeared:", ${lit(selector)});`
          : `await page.waitForTimeout(${ms ?? 1000});
console.log("waited:", ${ms ?? 1000});`;
        const out = await ego(pageScript(body), (ms ?? 15000) + 15000);
        return ok(out);
      } catch (error) {
        return fail(String((error as Error).message ?? error));
      }
    },
  );
}

