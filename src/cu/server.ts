import { fileURLToPath } from "node:url";
import { Bridge } from "./bridge.js";
import { existsSync, mkdirSync, readFileSync, readdirSync, rmSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { z } from "zod";
import { beginSession, clearControl, endSession, ensureOverlay, readControl, setCaption, setSessionState, showAct, showDrag, showPoint, showFrame, stopOverlaySync } from "./overlay.js";

/**
 * Codex Computer Use 的 Windows 对等实现。
 *
 * 逆向到的官方 macOS 契约（9 个 tool，见 research/codex-cu/）：
 *   list_apps / get_app_state / click / perform_secondary_action /
 *   scroll / set_value / press_key / type_text / drag
 * 响应是纯文本：`App=<bundle> (pid N)` + 带序号的可访问性树。
 *
 * 这里保持同样 9 个 tool 与同样的文本形态，底层换成 Windows UIA：
 * 走 hybrid-aci 的 desktop-uia.ps1 桥（tree / invoke / set_value / type_text /
 * send_key / scroll_element / drag_paths / screenshot）。
 */

const BRIDGE = process.env.EZTOGO_UIA_BRIDGE
  || fileURLToPath(new URL("../../../desktop/desktop-uia.ps1", import.meta.url));

interface TreeNode {
  path: string;
  name?: string;
  controlType?: string;
  className?: string;
  automationId?: string;
  value?: string;
  enabled?: boolean;
  offscreen?: boolean;
  rect?: { x: number; y: number; width: number; height: number };
  patterns?: Record<string, boolean>;
  selected?: boolean;
  expandState?: string;
}

interface AppSession {
  app: string;
  handle?: number;
  nodes: TreeNode[];
  capturedAt: number;
}

const sessions = new Map<string, AppSession>();
/** UWP/XAML 岛屿这类宿主在常驻桥里会退化到数十秒，记住后直接走一次性调用。 */
const directApps = new Set<string>();
const windowClassCache = new Map<string, { className: string; at: number }>();

/** 用 list_windows 反查窗口类名（5 秒缓存）；ApplicationFrameWindow / CoreWindow 判为 UWP。 */
async function isUwpApp(app: string): Promise<boolean> {
  const key = app.toLowerCase();
  if (directApps.has(key)) return true;
  const cached = windowClassCache.get(key);
  if (cached && Date.now() - cached.at < 60000) {
    return /ApplicationFrameWindow|CoreWindow|Windows\.UI\.Core/i.test(cached.className);
  }
  try {
    const data = await runBridge("list_windows", {});
    const match = (data.windows || []).find(
      (w: any) => String(w.name || "").toLowerCase() === key || String(w.processName || "").toLowerCase() === key,
    );
    if (match?.className) {
      windowClassCache.set(key, { className: match.className, at: Date.now() });
      const uwp = /ApplicationFrameWindow|CoreWindow|Windows\.UI\.Core/i.test(match.className);
      if (uwp) directApps.add(key);
      return uwp;
    }
  } catch {
    // 查不到就按非常驻处理
  }
  return false;
}

interface UsageEntry {
  lastUsed: string;
  uses: number;
}

const USAGE_DIR = join(process.env.USERPROFILE ?? tmpdir(), ".dsh", "computer-use");
const USAGE_FILE = join(USAGE_DIR, "usage.json");

function readUsage(): Record<string, UsageEntry> {
  try {
    return JSON.parse(readFileSync(USAGE_FILE, "utf8"));
  } catch {
    return {};
  }
}

function writeUsage(data: Record<string, UsageEntry>): void {
  try {
    mkdirSync(USAGE_DIR, { recursive: true });
    writeFileSync(USAGE_FILE, JSON.stringify(data, null, 2), "utf8");
  } catch {
    // best effort
  }
}

/** 官方每行带 `last-used=YYYY-MM-DD, uses=N`；这里按进程名累计，持久化到 usage.json。 */
function bumpUsage(appKey: string): UsageEntry {
  const data = readUsage();
  const key = appKey.toLowerCase();
  const today = new Date().toISOString().slice(0, 10);
  const entry = data[key] ?? { lastUsed: today, uses: 0 };
  entry.lastUsed = today;
  entry.uses += 1;
  data[key] = entry;
  writeUsage(data);
  return entry;
}

const bridge = new Bridge({ script: BRIDGE });
/** 截图走独立桥：tree 与 screenshot 并行，动作 tool 少等一个串行往返。 */
const shotBridge = new Bridge({ script: BRIDGE });

function runBridge(action: string, args: Record<string, unknown> = {}): Promise<any> {
  return bridge.call(action, args);
}
function roleOf(node: TreeNode): string {
  const raw = node.controlType || "";
  return raw.replace("ControlType.", "").toLowerCase();
}

/** 光标旁那行实时说明里的目标名：优先元素名，其次角色名；过长截断，别让说明框拉成一条。 */
function elementLabel(node?: TreeNode): string {
  if (!node) return "";
  const name = String(node.name || "").replace(/\s+/g, " ").trim();
  if (name.length > 12) return `${name.slice(0, 12)}…`;
  if (name) return name;
  return roleOf(node);
}

function nodeFor(app: string, elementIndex: number | string): TreeNode | undefined {
  const session = sessions.get(app.toLowerCase());
  return session?.nodes[Number(elementIndex)];
}

/** 实时说明（"点击「保存」"）：每个动作把它写在光标旁边，替代死板的状态文案。 */
function caption(verb: string, node?: TreeNode, fallback?: string): string {
  const label = elementLabel(node) || String(fallback || "").trim();
  return label ? `${verb}「${label}」` : verb;
}

/** 把 UIA 树渲染成 Codex 那种带序号的纯文本。 */
function secondaryActions(node: TreeNode): string[] {
  const patterns = node.patterns || {};
  const actions: string[] = [];
  if (patterns.invokable) actions.push("Press");
  if (patterns.toggleable) actions.push("Toggle");
  if (patterns.selectable) actions.push("Select");
  if (patterns.expandable) {
    const expanded = (node.expandState || "").toLowerCase().includes("expanded");
    actions.push(expanded ? "Collapse" : "Expand");
    actions.push("ShowMenu");
  }
  const role = roleOf(node);
  if (role === "window" || role === "pane") actions.push("Raise");
  return actions;
}

function attributes(node: TreeNode): string[] {
  const patterns = node.patterns || {};
  const traits: string[] = [];
  if (patterns.selectable) traits.push(node.selected ? "selected" : "selectable");
  if (patterns.expandable) {
    const state = (node.expandState || "").toLowerCase();
    if (state.includes("expanded")) traits.push("expanded");
    else if (state.includes("collapsed")) traits.push("collapsed");
  }
  if (patterns.valueSettable) traits.push("value-settable");
  if (node.offscreen) traits.push("offscreen");
  if (node.enabled === false) traits.push("disabled");
  return traits;
}

/** 把 UIA 树渲染成 Codex 那种带序号的纯文本。 */
function renderTree(app: string, pid: number | string, nodes: TreeNode[], truncated: boolean): string {
  const lines: string[] = [];
  lines.push(`App=${app} (pid ${pid})`);
  const rootNode = nodes[0];
  if (rootNode?.name) lines.push(`Window: "${rootNode.name}", App: ${app}.`);
  for (let index = 0; index < nodes.length; index += 1) {
    const node = nodes[index];
    const depth = node.path === "" ? 0 : node.path.split("/").length;
    const indent = "    ".repeat(depth);
    const traits = attributes(node);
    const actions = secondaryActions(node);
    const parts: string[] = [`${indent}${index} ${roleOf(node)}`];
    if (traits.length) parts.push(`(${traits.join(", ")})`);
    if (node.name) parts.push(node.name);
    if (node.className) parts.push(`[${node.className}]`);
    const tail: string[] = [];
    if (node.automationId) tail.push(`ID: ${node.automationId}`);
    if (node.value) tail.push(`Value: ${node.value}`);
    if (actions.length) tail.push(`Secondary Actions: ${actions.join(", ")}`);
    const head = parts.join(" ").replace(/ {2,}/g, " ");
    lines.push(tail.length ? `${head}, ${tail.join(", ")}` : head);
  }
  if (truncated) lines.push("… tree truncated (raise max_nodes for more)");
  return lines.join("\n");
}
/** Codex 每次动作后会追加 "The focused UI element is N <role>."；这里按快照索引反查。 */
function focusedLine(app: string, focused: any): string | null {
  if (!focused) return null;
  const session = sessions.get(app.toLowerCase());
  if (!session) return null;
  const index = session.nodes.findIndex((node) => {
    if (focused.automationId && node.automationId === focused.automationId && node.controlType === focused.controlType) {
      return true;
    }
    return Boolean(focused.name) && node.name === focused.name && node.controlType === focused.controlType;
  });
  if (index < 0) return null;
  return `The focused UI element is ${index} ${roleOf(session.nodes[index])}.`;
}
/** 截图目录会随着每次状态快照长下去（一天上百张、几十 MB），所以每次截图顺手清一次：
 *  只留最近 {@link SHOT_KEEP} 张、且不超过 {@link SHOT_MAX_AGE_MS}。清理失败不影响截图。 */
const SHOT_KEEP = 200;
const SHOT_MAX_AGE_MS = 2 * 60 * 60 * 1000;
function pruneShots(dir: string): void {
  try {
    const entries = readdirSync(dir)
      .filter((name) => name.endsWith(".jpg"))
      .map((name) => {
        const path = join(dir, name);
        try {
          return { path, at: statSync(path).mtimeMs };
        } catch {
          return null;
        }
      })
      .filter((entry): entry is { path: string; at: number } => entry !== null)
      .sort((left, right) => right.at - left.at);
    const cutoff = Date.now() - SHOT_MAX_AGE_MS;
    for (const [index, entry] of entries.entries()) {
      if (index < SHOT_KEEP && entry.at >= cutoff) continue;
      try {
        rmSync(entry.path, { force: true });
      } catch {}
    }
  } catch {}
}

/** get_app_state 附带一张窗口截图（官方行为：每次状态快照都带图）。 */
async function captureImage(app: string): Promise<{ data: string; mimeType: string } | null> {
  try {
    const dir = join(tmpdir(), "computer-use-shots");
    mkdirSync(dir, { recursive: true });
    const file = join(dir, `${app.replace(/[^a-z0-9_-]/gi, "_")}-${Date.now()}.jpg`);
    const args = {
      name: app,
      path: file,
      imageFormat: "jpeg",
      maxLongEdge: 1024,
      returnBase64: false,
      skipGrid: true,
    };
    // UWP 在常驻桥里连截图都会卡到 30s（UIA 连接被 provider 拖住），同样走一次性。
    if (await isUwpApp(app)) await shotBridge.direct("screenshot", args);
    else await shotBridge.call("screenshot", args);
    const bytes = readFileSync(file);
    pruneShots(dir);
    return { data: bytes.toString("base64"), mimeType: "image/jpeg" };
  } catch {
    return null;
  }
}
function sessionFor(app: string): AppSession {
  const session = sessions.get(app.toLowerCase());
  if (!session) throw new Error(`No snapshot for "${app}". Call cu_get_app_state first.`);
  return session;
}

function pathFor(app: string, elementIndex: number): string {
  const session = sessionFor(app);
  const node = session.nodes[elementIndex];
  if (!node) {
    throw new Error(`element_index ${elementIndex} is out of range (0..${session.nodes.length - 1})`);
  }
  return node.path;
}

/** Codex 用 "super+a" 这种 macOS 写法；这里翻译成 Windows 的 SendKeys 风格。 */
/** Codex 用 "super+a" 这种 macOS 写法；这里翻译成 Windows 的 SendKeys 风格。 */
function translateKey(key: string): string {
  return key
    .replace(/\bsuper\b/gi, "ctrl")
    .replace(/\bcmd\b/gi, "ctrl")
    .replace(/\bmeta\b/gi, "ctrl")
    .replace(/\boption\b/gi, "alt")
    .replace(/\breturn\b/gi, "enter")
    .replace(/\bescape\b/gi, "esc")
    .replace(/\bdelete\b/gi, "del");
}

/**
 * 人在胶囊上点了「接管」或「终止任务」之后，动作要停下来。
 * 对应 ego 的语义：接管 = 人接手控制；终止任务 = 这次任务结束。
 */
function controlGate(): { blocked: string | null } {
  const action = readControl();
  if (!action) return { blocked: null };
  if (action === "takeover") {
    setSessionState("human");
    return { blocked: "已被人接管：点胶囊上的「交还给 Agent」再继续。" };
  }
  if (action === "abort") {
    // 人点了「强制结束」：胶囊与边缘光淡出，这次 compute use 到此结束
    setSessionState("completed");
    endSession();
    return { blocked: "任务已被终止：重新发起任务后再操作。" };
  }
  if (action === "resume") {
    clearControl();
    setSessionState("controlling");
  }
  return { blocked: null };
}

/** 元素在屏幕上的矩形（overlay 用），没有就返回 null。 */
function rectFor(app: string, elementIndex: number | string): { x: number; y: number; width: number; height: number } | null {
  const session = sessions.get(app.toLowerCase());
  if (!session) return null;
  const node = session.nodes[Number(elementIndex)];
  if (!node?.rect || node.rect.width <= 0 || node.rect.height <= 0) return null;
  return node.rect;
}


async function snapshot(app: string, maxDepth = 6, maxNodes = 400): Promise<string> {
  const uwp = await isUwpApp(app);
  // tree_cached 的 CacheRequest 在 UWP 上拿不到 Cached 属性（角色名全空），改用普通遍历。
  const action = "tree";
  const args = { name: app, maxDepth, maxNodes };
  const data = uwp ? await bridge.direct(action, args) : await runBridge(action, args);
  const nodes: TreeNode[] = data.nodes || [];
  let pid: number | string = data.window?.pid ?? data.pid ?? "?";
  if (pid === "?") {
    try {
      const windows = await runBridge("list_windows", {});
      const match = (windows.windows || []).find((w: any) => w.handle === data.window?.handle);
      if (match?.pid) pid = match.pid;
    } catch {
      // 保留 "?"
    }
  }
  sessions.set(app.toLowerCase(), {
    app,
    handle: data.window?.handle,
    nodes,
    capturedAt: Date.now(),
  });
  bumpUsage(app);
  return renderTree(app, pid, nodes, Boolean(data.truncated));
}

export function mountCu(server: McpServer): void {

/** 官方每次动作都附一张截图；这里统一把 state + image 打成 content。 */
async function finish(app: string, prefix?: string, maxDepth = 6, maxNodes = 400): Promise<any> {
  // 动作做完、界面开始重读：光标旁那行字立刻跟着换成"读取中"
  setCaption(`读取「${app}」`);
  // 官方每次动作都附状态 + 截图；两者互不依赖，走并行（两次独立桥调用）。
  const [state, image] = await Promise.all([snapshot(app, maxDepth, maxNodes), captureImage(app)]);
  return buildStateContent(state, prefix, image);
}

function buildStateContent(state: string, prefix: string | undefined, image: { data: string; mimeType: string } | null): any {
  const content: any[] = [{ type: "text", text: prefix ? `${prefix}\n${state}` : state }];
  if (image) content.push({ type: "image", data: image.data, mimeType: image.mimeType });
  return { content };
}

function text(value: string) {
  return { content: [{ type: "text" as const, text: value }] };
}

function fail(message: string) {
  return { isError: true as const, content: [{ type: "text" as const, text: message }] };
}

server.registerTool(
  "list_apps",
  {
    title: "List apps",
    description:
      "Every top-level window the agent can drive, one per line: `Name — process (pid N) [running]`. Same shape as Codex's list_apps.",
    inputSchema: {},
    annotations: { readOnlyHint: true },
  },
  async () => {
    setCaption("列出窗口");
    const data = await runBridge("list_windows", {});
    const usage = readUsage();
    const rows: string[] = (data.windows || []).map((w: any) => {
      const key = String(w.processName || "?").toLowerCase();
      const entry = usage[key];
      const meta = ["running", entry ? `last-used=${entry.lastUsed}` : "", entry ? `uses=${entry.uses}` : ""]
        .filter(Boolean)
        .join(", ");
      return `${w.name || "(untitled)"} — ${w.processName || "?"} (pid ${w.pid}) [${meta}]`;
    });
    // 官方还会列出"以前用过、现在没开"的 app（只有 last-used 与 uses）。
    const openKeys = new Set((data.windows || []).map((w: any) => String(w.processName || "?").toLowerCase()));
    for (const [key, entry] of Object.entries(usage)) {
      if (openKeys.has(key)) continue;
      rows.push(`${key} — ${key} [last-used=${entry.lastUsed}, uses=${entry.uses}]`);
    }
    return text(rows.join("\n"));
  },
);

server.registerTool(
  "get_app_state",
  {
    title: "App state",
    description:
      "Snapshot one app: `App=<name> (pid N)` followed by its accessibility tree, each node prefixed with the index you pass to click / set_value / scroll / drag.",
    inputSchema: {
      app: z.string().min(1).describe("Window title substring, process name, or handle"),
      max_depth: z.number().int().min(1).max(20).optional(),
      max_nodes: z.number().int().min(10).max(2000).optional(),
    },
    annotations: { readOnlyHint: true },
  },
  async ({ app, max_depth, max_nodes }) => {
    try {
      return await finish(app, undefined, max_depth ?? 6, max_nodes ?? 400);
    } catch (error) {
      return fail(String((error as Error).message ?? error));
    }
  },
);

server.registerTool(
  "click",
  {
    title: "Click element",
    description: "Click the element at element_index from the last get_app_state of this app.",
    inputSchema: {
      app: z.string().min(1),
      element_index: z.string().describe("Element index from the last get_app_state, as a string"),
    },
    annotations: { readOnlyHint: false },
  },
  async ({ app, element_index }) => {
    try {
      const path = pathFor(app, Number(element_index));
      // Codex 的策略：先尝试元素自带的 AXPress（UIA 里对应 Invoke/Toggle/Select），
      // 没有对应 pattern 时退回到"把指针移到元素中心再点"。
      try {
        showAct(rectFor(app, element_index), undefined, app, undefined, caption("点击", nodeFor(app, element_index), app));
        const gate = controlGate();         if (gate.blocked) return fail(gate.blocked);
        await runBridge("invoke", { name: app, path });
      } catch {
        await runBridge("click", { name: app, path });
      }
      return finish(app);
    } catch (error) {
      return fail(String((error as Error).message ?? error));
    }
  },
);

server.registerTool(
  "perform_secondary_action",
  {
    title: "Secondary action",
    description:
      "Run a named secondary action on an element (Raise / Expand / Collapse / Press / Select). Maps onto the UIA patterns the element actually supports.",
    inputSchema: {
      app: z.string().min(1),
      element_index: z.string().describe("Element index from the last get_app_state, as a string"),
      action: z.string().min(1),
    },
    annotations: { readOnlyHint: false },
  },
  async ({ app, element_index, action }) => {
    try {
      const path = pathFor(app, Number(element_index));
        showAct(rectFor(app, element_index), undefined, app, undefined, `执行 ${action}「${elementLabel(nodeFor(app, element_index)) || app}」`);
      const gate = controlGate();       if (gate.blocked) return fail(gate.blocked);
      const result = await runBridge("secondary_action", { name: app, path, action });
        const [state, image] = await Promise.all([snapshot(app), captureImage(app)]);
        const focused = focusedLine(app, result?.focused);
        return buildStateContent(`${state}${focused ? `\n${focused}` : ""}`, `Performed ${result?.performed ?? action} on ${element_index}.`, image);
    } catch (error) {
      return fail(String((error as Error).message ?? error));
    }
  },
);

server.registerTool(
  "scroll",
  {
    title: "Scroll element",
    description: "Scroll the element (or its scrollable ancestor) by pages in a direction.",
    inputSchema: {
      app: z.string().min(1),
      element_index: z.string().describe("Element index from the last get_app_state, as a string"),
      direction: z.enum(["up", "down", "left", "right"]),
      pages: z.number().int().min(1).max(20).optional(),
    },
    annotations: { readOnlyHint: false },
  },
  async ({ app, element_index, direction, pages }) => {
    try {
      const path = pathFor(app, Number(element_index));
        showFrame(rectFor(app, element_index), 500, app, `${direction === "up" ? "上滚" : direction === "down" ? "下滚" : direction === "left" ? "左滚" : "右滚"}「${elementLabel(nodeFor(app, element_index)) || app}」`);
      const gate = controlGate();       if (gate.blocked) return fail(gate.blocked);
      await runBridge("scroll_element", { name: app, path, direction, pages: pages ?? 1 });
      return finish(app);
    } catch (error) {
      return fail(String((error as Error).message ?? error));
    }
  },
);

server.registerTool(
  "set_value",
  {
    title: "Set value",
    description: "Set the value of a text field / slider / combo box at element_index (ValuePattern).",
    inputSchema: {
      app: z.string().min(1),
      element_index: z.string().describe("Element index from the last get_app_state, as a string"),
      value: z.string(),
    },
    annotations: { readOnlyHint: false },
  },
  async ({ app, element_index, value }) => {
    try {
      const path = pathFor(app, Number(element_index));
        showAct(rectFor(app, element_index), undefined, app, undefined, `填写「${elementLabel(nodeFor(app, element_index)) || app}」`);
      const gate = controlGate();       if (gate.blocked) return fail(gate.blocked);
      await runBridge("set_value", { name: app, path, value });
      return finish(app);
    } catch (error) {
      return fail(String((error as Error).message ?? error));
    }
  },
);

server.registerTool(
  "press_key",
  {
    title: "Press key",
    description: 'Send a key combination to the app, e.g. "ctrl+a" (macOS "super+a" is accepted and mapped).',
    inputSchema: {
      app: z.string().min(1),
      key: z.string().min(1),
    },
    annotations: { readOnlyHint: false },
  },
  async ({ app, key }) => {
    try {
      showFrame(rectFor(app, 0) ?? null, 400, app, `按键 ${key}`);
      const gate = controlGate();       if (gate.blocked) return fail(gate.blocked);
      await runBridge("send_key", { name: app, key: translateKey(key) });
      return finish(app);
    } catch (error) {
      return fail(String((error as Error).message ?? error));
    }
  },
);

server.registerTool(
  "type_text",
  {
    title: "Type text",
    description: "Type text into the app's focused element.",
    inputSchema: {
      app: z.string().min(1),
      text: z.string(),
    },
    annotations: { readOnlyHint: false },
  },
  async ({ app, text: value }) => {
    try {
      showFrame(rectFor(app, 0) ?? null, 500, app, `输入 ${[...value].length} 个字`);
      const gate = controlGate();       if (gate.blocked) return fail(gate.blocked);
      await runBridge("send_text", { name: app, text: value });
      return finish(app);
    } catch (error) {
      return fail(String((error as Error).message ?? error));
    }
  },
);

server.registerTool(
  "drag",
  {
    title: "Drag",
    description: "Drag from one element to another (element centres).",
    inputSchema: {
      app: z.string().min(1),
      from_element_index: z.string().describe("Element index from the last get_app_state, as a string"),
      to_element_index: z.string().describe("Element index from the last get_app_state, as a string"),
    },
    annotations: { readOnlyHint: false },
  },
  async ({ app, from_element_index, to_element_index }) => {
    try {
      const fromPath = pathFor(app, Number(from_element_index));
      const toPath = pathFor(app, Number(to_element_index));
      const fromRect = rectFor(app, from_element_index);
      const toRect = rectFor(app, to_element_index);
      showDrag(
        fromRect,
        toRect ? { x: toRect.x + toRect.width / 2, y: toRect.y + toRect.height / 2 } : null,
        app,
        `拖拽「${elementLabel(nodeFor(app, from_element_index)) || app}」→「${elementLabel(nodeFor(app, to_element_index)) || app}」`,
      );
      const gate = controlGate();       if (gate.blocked) return fail(gate.blocked);
      await runBridge("drag_paths", { name: app, fromPath, toPath });
      return finish(app);
    } catch (error) {
      return fail(String((error as Error).message ?? error));
    }
  },
);

// 退出时把叠加层进程收掉，别留孤儿窗口
process.on("exit", () => {
  try {
    stopOverlaySync();
  } catch {
    // exiting anyway
  }
});

}
