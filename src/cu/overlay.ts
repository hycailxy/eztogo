import { fileURLToPath } from "node:url";
import { spawn, type ChildProcess } from "node:child_process";
import { mkdirSync, readFileSync, writeFileSync, rmSync } from "node:fs";
import { dirname, join } from "node:path";
import { tmpdir } from "node:os";

/**
 * Codex-style on-screen feedback for computer-use actions.
 *
 * The overlay is the piece that makes an agent's work legible: a fog cursor that
 * glides to the target, a click ripple, and a highlight box around the element
 * being acted on (ComputerUseCursor / FogCursorStyle in the shipped app).
 *
 * Best-effort by contract: if the helper fails to start, actions still run.
 * Disable with HYBRID_ACI_CU_OVERLAY=0; HYBRID_ACI_CU_REDUCED_MOTION=1 skips
 * glide/ripple (useful for recordings and VMs).
 */

const ROOT = process.env.EZTOGO_ROOT || fileURLToPath(new URL("../../..", import.meta.url)).replace(/[\\/]+$/, "");

export interface Rect {
  x: number;
  y: number;
  width: number;
  height: number;
}

let child: ChildProcess | null = null;
let commandFile = "";
let seq = 0;

function enabled(): boolean {
  if (process.platform !== "win32") return false;
  if (process.env.HYBRID_ACI_CU_OVERLAY === "0") return false;
  // 服务会话（Session 0 / 无人登录的桌面）没有可以画的全屏桌面：
  // 在那里起 layered 窗口只会白占一个进程，甚至在某些会话里报错。
  if ((process.env.SESSIONNAME || "").toLowerCase() === "services") return false;
  return true;
}

function reducedMotion(): boolean {
  return process.env.HYBRID_ACI_CU_REDUCED_MOTION === "1";
}

function write(payload: Record<string, unknown>): void {
  if (!commandFile) return;
  seq += 1;
  try {
    writeFileSync(commandFile, JSON.stringify({ seq, ...payload }), "utf8");
  } catch {
    // overlay is decoration; never let it break an action
  }
}

/** 光标旁那行说明的当前内容（叠加层里的实时说明）。 */
let caption = "";

/**
 * 实时说明：把光标旁那行字改成"此刻在做什么"（点击「保存」/ 输入 12 个字 / 读取「记事本」）。
 *
 * 只在叠加层已经活着时写——纯读操作不该为了更新一行字去新起一个 WPF 进程。
 * 传空字符串则回落到状态文案（Agent 正在控制）。
 */
export function setCaption(text?: string | null): void {
  if (!enabled() || !overlayRunning()) return;
  const next = (text ?? "").trim();
  if (next === caption) return;
  caption = next;
  write({ op: "caption", caption: next });
}

/** 动作带说明：caption 跟动作写在同一条命令里（单文件通道只保留最后一次写入）。 */
function action(tool: Record<string, unknown>, text?: string): Record<string, unknown> {
  const next = (text ?? "").trim();
  if (!next) return tool;
  caption = next;
  return { ...tool, caption: next };
}

/** 这次 compute use 的会话是否已经开过场（胶囊 + 边缘光）。 */
let sessionStarted = false;

/**
 * 开始一次 compute use 会话：让胶囊出现、边缘光亮起，并写上任务名。
 * 第一次动作前自动调用，重复调用无副作用。
 */
export function beginSession(taskName?: string): void {
  if (!ensureOverlay()) return;
  if (sessionStarted) {
    if (taskName) write({ op: "title", value: taskName });
    return;
  }
  sessionStarted = true;
  // 只写一条：叠加层每帧只读最后一次写入，连写 start + title 会把 start 覆盖掉
  write({ op: "start", state: "controlling", ...(taskName ? { value: taskName } : {}) });
}

/** 改状态文案（controlling / human / paused / completed / failed）。 */
export function setSessionState(state: string): void {
  if (!ensureOverlay()) return;
  // 状态文案会顶掉光标旁的实时说明，这里同步清掉，下一次动作才能重新写上
  caption = "";
  write({ op: "hold", state });
}

/** 结束这次会话：胶囊与边缘光淡出，叠加层收起。 */
export function endSession(): void {
  if (!ensureOverlay()) return;
  sessionStarted = false;
  caption = "";
  write({ op: "end" });
}
export function overlayRunning(): boolean {
  return Boolean(child && child.exitCode === null);
}

/** Start the helper once. Safe to call before every action. */
export function ensureOverlay(): boolean {
  if (!enabled()) return false;
  if (overlayRunning()) return true;
  commandFile = join(tmpdir(), `cu-overlay-${process.pid}.json`);
  try {
    mkdirSync(dirname(commandFile), { recursive: true });
    writeFileSync(commandFile, JSON.stringify({ seq: 0, op: "hide" }), "utf8");
  } catch {
    return false;
  }
  const script = join(ROOT, "desktop", "overlay", "codex-cursor.ps1");
  const args = [
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    script,
    "-CommandFile",
    commandFile,
    "-ParentPid",
    String(process.pid),
    "-IdleTimeoutMs",
    "180000",
    ...(reducedMotion() ? ["-ReducedMotion"] : []),
  ];
  try {
    child = spawn("powershell.exe", args, { stdio: "ignore", windowsHide: true });
    child.on("exit", () => {
      child = null;
      // 新进程的说明文字会回到默认文案，去重缓存要跟着清掉
      caption = "";
    });
    child.on("error", () => {
      child = null;
    });
  } catch {
    child = null;
    return false;
  }
  return true;
}

/** Glide the fog cursor to a screen point. */
export function showPoint(x: number, y: number, app?: string, text?: string): void {
  beginSession(app ? `compute use · ${app}` : "compute use");
  if (!ensureOverlay()) return;
  write(action({ op: "point", x: Math.round(x), y: Math.round(y), ...(app ? { app } : {}) }, text));
}

/** Highlight a rect, glide the cursor to its centre and fire the click ripple. */
export function showAct(
  rect: Rect | null | undefined,
  fallback?: { x: number; y: number },
  app?: string,
  state?: string,
  text?: string,
): void {
  beginSession(app ? `compute use · ${app}` : "compute use");
  if (!ensureOverlay()) return;
  if (rect && rect.width > 0 && rect.height > 0) {
    write(
      action(
        {
          op: "act",
          x: Math.round(rect.x),
          y: Math.round(rect.y),
          w: Math.round(rect.width),
          h: Math.round(rect.height),
          ...(app ? { app } : {}),
        },
        text,
      ),
    );
    return;
  }
  if (fallback) showPoint(fallback.x, fallback.y, app, text);
}

/** Highlight without a click (used for the element a keystroke goes to). */
export function showFrame(rect: Rect | null | undefined, holdMs = 600, app?: string, text?: string): void {
  beginSession(app ? `compute use · ${app}` : "compute use");
  if (!ensureOverlay()) return;
  if (!rect) return;
  write(
    action(
      {
        op: "frame",
        x: Math.round(rect.x),
        y: Math.round(rect.y),
        w: Math.round(rect.width),
        h: Math.round(rect.height),
        holdMs,
        ...(app ? { app } : {}),
      },
      text,
    ),
  );
}

/** 拖拽：源矩形高亮，光标沿路径滑到目标点（区别于"瞬移 + 点击"）。 */
export function showDrag(
  rect: Rect | null | undefined,
  to: { x: number; y: number } | null | undefined,
  app?: string,
  text?: string,
): void {
  if (!ensureOverlay()) return;
  beginSession(app ? `compute use · ${app}` : "compute use");
  if (!to) return;
  write(
    action(
      {
        op: "drag",
        x: rect ? Math.round(rect.x) : 0,
        y: rect ? Math.round(rect.y) : 0,
        w: rect ? Math.round(rect.width) : 0,
        h: rect ? Math.round(rect.height) : 0,
        toX: Math.round(to.x),
        toY: Math.round(to.y),
        ...(app ? { app } : {}),
      },
      text,
    ),
  );
}

/** 人点了胶囊上的「接管/终止任务」后，叠加层会把动作写在这里。 */
export function readControl(): string | null {
  if (!commandFile) return null;
  try {
    const text = readFileSync(`${commandFile}.control`, "utf8").trim();
    return text || null;
  } catch {
    return null;
  }
}

/** 服务端处理完一次接管/终止之后清掉，避免反复触发。 */
export function clearControl(): void {
  if (!commandFile) return;
  try {
    rmSync(`${commandFile}.control`, { force: true });
  } catch {
    // ignore
  }
}

export function hideOverlay(): void {
  if (!overlayRunning()) return;
  write({ op: "hide" });
}

export function stopOverlaySync(): void {
  try {
    if (!commandFile) return;
    seq += 1;
    writeFileSync(commandFile, JSON.stringify({ seq, op: "quit" }), "utf8");
  } catch {
    // exiting anyway
  }
  try {
    if (commandFile) rmSync(commandFile, { force: true });
  } catch {
    // ignore
  }
}
