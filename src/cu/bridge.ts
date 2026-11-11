import { spawn, type ChildProcessWithoutNullStreams } from "node:child_process";

/**
 * 常驻桥客户端。
 *
 * 官方 Codex 的 Computer Use 是一个常驻 Service：UIA/AX 上下文只初始化一次，
 * 之后每次动作走 socket，延迟几毫秒，而且焦点不会因为进程退出而漂走。
 *
 * 这里用 `desktop-uia.ps1 -Action serve` 复刻同样的形态：一个 PowerShell 进程常驻，
 * stdin/stdout 走换行分隔的 JSON。启动失败或中途崩溃就自动回落成一次性调用。
 */

export interface BridgeOptions {
  script: string;
  /** 单次请求超时（毫秒）。 */
  timeoutMs?: number;
  /** 设为 false 时强制走一次性模式。 */
  serve?: boolean;
}

/**
 * spawn 失败（找不到 powershell.exe / 被 EDR 拦 / 不是 Windows）必须变成一次"调用失败"，
 * 绝不能漏成 uncaughtException 把整个 MCP 进程带走——那会让客户端看到 "server exited"。
 */
function spawnFailure(error: unknown, action: string): Error {
  const err = error as NodeJS.ErrnoException | undefined;
  const code = err?.code;
  if (code === "ENOENT") {
    return new Error(
      process.platform === "win32"
        ? `电脑操控需要 Windows PowerShell（powershell.exe），但在 PATH 里找不到它（action=${action}）。请确认 powershell.exe 可用，或用 EZTOGO_POWERSHELL 指定绝对路径。`
        : `电脑操控只能在 Windows 上运行：当前平台是 ${process.platform}，没有 powershell.exe（action=${action}）。浏览器工具不受影响。`,
    );
  }
  if (code === "EACCES" || code === "EPERM") {
    return new Error(`桌面桥无法执行 powershell.exe（${code}，action=${action}）：很可能被安全软件拦住了，请把 powershell.exe 和本包加入白名单。`);
  }
  return new Error(`桌面桥启动失败（action=${action}）：${err?.message ?? String(error)}`);
}

interface Pending {
  resolve: (value: any) => void;
  reject: (error: Error) => void;
  timer: NodeJS.Timeout;
}

export class Bridge {
  private readonly script: string;
  private readonly timeoutMs: number;
  private readonly serveEnabled: boolean;
  private child: ChildProcessWithoutNullStreams | null = null;
  private pending = new Map<string, Pending>();
  private seq = 0;
  private stdoutBuffer = "";
  private readyPromise: Promise<void> | null = null;
  private serveFailures = 0;
  /** 单次 serve 调用超过这个时长就判定该宿主的 UIA 在常驻进程里退化（UWP 常见），整局回落一次性。 */
  private readonly slowThresholdMs: number;
  private readonly serveTimeoutMs: number;
  /** 便于自检：记录走的是常驻还是回退。 */
  public mode: "serve" | "oneshot" = "oneshot";
  public calls = 0;
  public totalMs = 0;
  /** 常驻桥 spawn 失败的原始错误（用于给出可读提示，而不是反复重试）。 */
  private lastSpawnError: Error | null = null;

  constructor(options: BridgeOptions) {
    this.script = options.script;
    this.timeoutMs = options.timeoutMs ?? Number(process.env.HYBRID_ACI_CU_TIMEOUT_MS ?? 120000);
    this.serveEnabled = options.serve ?? process.env.HYBRID_ACI_CU_SERVE !== "0";
    this.slowThresholdMs = Number(process.env.HYBRID_ACI_CU_SLOW_MS ?? 1200);
    this.serveTimeoutMs = Number(process.env.HYBRID_ACI_CU_SERVE_TIMEOUT_MS ?? 3000);
  }

  async call(action: string, args: Record<string, unknown> = {}): Promise<any> {
    // 非 Windows 直接给出可读结论，不去 spawn 两次再报 ENOENT
    if (process.platform !== "win32") {
      throw new Error(`电脑操控只能在 Windows 上运行：当前平台是 ${process.platform}（action=${action}）。浏览器工具不受影响。`);
    }
    const started = Date.now();
    try {
      if (this.serveEnabled && this.serveFailures < 2) {
        try {
          const serveStart = Date.now();
          const result = await this.callServe(action, args);
          const elapsed = Date.now() - serveStart;
          // 前 3 次属于冷启动/预热（首次 UIA 连接建立），不参与退化判定。
          if (this.calls >= 3 && elapsed > this.slowThresholdMs) {
            process.stderr.write(`[computer-use] 常驻桥单次 ${elapsed}ms 超过 ${this.slowThresholdMs}ms（${action}），本会话回落一次性模式\n`);
            this.serveFailures = 2;
            this.killChild();
            return await this.callOneShot(action, args);
          }
          this.mode = "serve";
          return result;
        } catch (error) {
          // 超时本身就是"常驻进程里 UIA 退化"的确证（UWP 这种），直接永久回退，不再重试。
          const timedOut = String((error as Error).message).includes("bridge timeout");
          this.serveFailures = timedOut ? 2 : this.serveFailures + 1;
          if (this.serveFailures >= 2) {
            process.stderr.write(`[computer-use] 常驻桥不可用，回落到一次性模式: ${String((error as Error).message ?? error)}\n`);
            this.killChild();
          }
        }
      }
      this.mode = "oneshot";
      return await this.callOneShot(action, args);
    } finally {
      this.calls += 1;
      this.totalMs += Date.now() - started;
    }
  }

  /** 跳过常驻桥，直接一次性调用（UWP 这类在常驻进程里会退化的宿主）。 */
  direct(action: string, args: Record<string, unknown> = {}): Promise<any> {
    return this.callOneShot(action, args);
  }

  stats(): { mode: string; calls: number; avgMs: number } {
    return { mode: this.mode, calls: this.calls, avgMs: this.calls ? Number((this.totalMs / this.calls).toFixed(1)) : 0 };
  }

  dispose(): void {
    this.killChild();
  }

  private ensureChild(): ChildProcessWithoutNullStreams {
    if (this.child && !this.child.killed) return this.child;
    const shell = process.env.EZTOGO_POWERSHELL || "powershell.exe";
    const child = spawn(
      shell,
      ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", this.script, "-Action", "serve"],
      { windowsHide: true },
    );
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk: string) => this.onStdout(chunk));
    child.stderr.on("data", (chunk: string) => {
      if (!chunk.includes("ready")) process.stderr.write(chunk);
    });
    // 没有这个 listener 时，spawn 失败会抛 uncaughtException 直接杀掉 MCP 进程
    child.on("error", (error) => {
      this.child = null;
      this.readyPromise = null;
      this.serveFailures = 2;
      this.lastSpawnError = spawnFailure(error, "serve");
      for (const [, pending] of this.pending) {
        clearTimeout(pending.timer);
        pending.reject(this.lastSpawnError);
      }
      this.pending.clear();
    });
    child.on("exit", () => {
      this.child = null;
      this.readyPromise = null;
      for (const [, pending] of this.pending) {
        clearTimeout(pending.timer);
        pending.reject(new Error("bridge process exited"));
      }
      this.pending.clear();
    });
    this.child = child;
    this.readyPromise = new Promise<void>((resolve) => {
      const onReady = (chunk: string) => {
        if (chunk.includes("ready")) {
          child.stderr.off("data", onReady);
          resolve();
        }
      };
      child.stderr.on("data", onReady);
      setTimeout(resolve, 1500);
    });
    return child;
  }

  private onStdout(chunk: string): void {
    this.stdoutBuffer += chunk;
    let index = this.stdoutBuffer.indexOf("\n");
    while (index >= 0) {
      const line = this.stdoutBuffer.slice(0, index).trim();
      this.stdoutBuffer = this.stdoutBuffer.slice(index + 1);
      index = this.stdoutBuffer.indexOf("\n");
      if (!line) continue;
      let parsed: any;
      try {
        parsed = JSON.parse(line);
      } catch {
        continue;
      }
      const id = String(parsed.id ?? "");
      const pending = this.pending.get(id);
      if (!pending) continue;
      this.pending.delete(id);
      clearTimeout(pending.timer);
      if (parsed.ok === false) pending.reject(new Error(parsed.error || "bridge error"));
      else pending.resolve(parsed.data ?? parsed);
    }
  }

  private async callServe(action: string, args: Record<string, unknown>): Promise<any> {
    const child = this.ensureChild();
    if (this.readyPromise) await this.readyPromise;
    if (this.lastSpawnError) throw this.lastSpawnError;
    if (!this.child || child.killed || !child.stdin.writable) throw spawnFailure(this.lastSpawnError ?? new Error("child gone"), action);
    const id = `${process.pid}-${++this.seq}`;
    const payload = JSON.stringify({ id, action, args: { strictName: true, ...args } });
    return new Promise<any>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`bridge timeout after ${this.serveTimeoutMs}ms (action=${action})`));
      }, Math.min(this.serveTimeoutMs, this.timeoutMs));
      this.pending.set(id, { resolve, reject, timer });
      try {
        child.stdin.write(`${payload}\n`);
      } catch (error) {
        clearTimeout(timer);
        this.pending.delete(id);
        reject(spawnFailure(error, action));
      }
    });
  }

  private callOneShot(action: string, args: Record<string, unknown>): Promise<any> {
    const payload = Buffer.from(JSON.stringify({ strictName: true, ...args }), "utf8").toString("base64");
    const shell = process.env.EZTOGO_POWERSHELL || "powershell.exe";
    return new Promise((resolve, reject) => {
      let child: ReturnType<typeof spawn>;
      try {
        child = spawn(
          shell,
          ["-NoProfile", "-ExecutionPolicy", "Bypass", "-File", this.script, "-Action", action, "-ArgsBase64", payload],
          { windowsHide: true },
        );
      } catch (error) {
        return reject(spawnFailure(error, action));
      }
      let out = "";
      let err = "";
      child.stdout?.on("data", (chunk) => (out += chunk.toString("utf8")));
      child.stderr?.on("data", (chunk) => (err += chunk.toString("utf8")));
      child.on("error", (error) => reject(spawnFailure(error, action)));
      child.on("close", () => {
        const text = out.trim();
        if (!text) return reject(new Error(err.trim() || `bridge ${action} produced no output`));
        try {
          const parsed = JSON.parse(text);
          if (parsed && parsed.ok === false) return reject(new Error(parsed.error || "bridge error"));
          resolve(parsed?.data ?? parsed);
        } catch {
          reject(new Error(`bridge ${action} returned non-JSON: ${text.slice(0, 300)}`));
        }
      });
    });
  }

  private killChild(): void {
    this.lastSpawnError = null;
    if (!this.child) return;
    try {
      this.child.stdin.end();
      this.child.kill();
    } catch {
      // ignore
    }
    this.child = null;
    this.readyPromise = null;
  }
}
