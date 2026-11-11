/**
 * 光标旁"实时说明"的端到端检查（server → overlay 命令文件）。
 *
 * 走真实的 MCP server + 真实的叠加层进程，只把桌面桥换成 tests/mock-uia-bridge.ps1，
 * 所以不需要任何真实窗口，也不会点到用户正在用的程序。
 *
 * 断言：每个动作写进命令文件里的 caption 正是"点击「保存」/输入 5 个字/……"，
 * 而不是死板的状态文案。
 *
 * 跑法：node tests/cu-caption-e2e.mjs
 */
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StdioClientTransport } from "@modelcontextprotocol/sdk/client/stdio.js";
import { readdirSync, readFileSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = dirname(dirname(fileURLToPath(import.meta.url)));
const MOCK = join(ROOT, "tests", "mock-uia-bridge.ps1");
const SERVER = join(ROOT, "dist", "src", "server.js");

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

/** 叠加层命令文件是"最后一次写入"，所以用高频轮询把每条写过的说明都收下来。 */
function watchCaptions(sink, timers) {
  const seen = new Map();
  let lastCaption = "";
  const timer = setInterval(() => {
    let names = [];
    try {
      names = readdirSync(tmpdir()).filter((name) => /^cu-overlay-\d+\.json$/.test(name));
    } catch {
      return;
    }
    for (const name of names) {
      const path = join(tmpdir(), name);
      try {
        // 只看本次运行期间被写过的文件，别把上一次的旧命令读进来
        if (Date.now() - statSync(path).mtimeMs > 5000) continue;
        const raw = readFileSync(path, "utf8");
        if (seen.get(path) === raw) continue;
        seen.set(path, raw);
        const cmd = JSON.parse(raw);
        if (typeof cmd.caption === "string" && cmd.caption && cmd.caption !== lastCaption) {
          lastCaption = cmd.caption;
          sink.push(cmd.caption);
        }
      } catch {
        // 半个文件/被占用都正常，下一轮再来
      }
    }
  }, 20);
  timer.unref?.();
  timers.push(timer);
}

const expected = [
  "读取「MockApp」",
  "点击「保存」",
  "输入 5 个字",
  "按键 ctrl+a",
  "下滚「正文编辑区」",
  "填写「正文编辑区」",
  "拖拽「正文编辑区」→「保存」",
];

const captions = [];
const timers = [];
const transport = new StdioClientTransport({
  command: process.execPath,
  args: [SERVER],
  env: {
    ...process.env,
    EZTOGO_UIA_BRIDGE: MOCK,
    HYBRID_ACI_CU_OVERLAY: "1",
    // 假桥不实现常驻协议，直接走一次性调用，别等它超时回落
    HYBRID_ACI_CU_SERVE: "0",
  },
  stderr: "pipe",
});

const client = new Client({ name: "cu-caption-e2e", version: "0.0.1" }, { capabilities: {} });
await client.connect(transport);
watchCaptions(captions, timers);

const call = (name, args) => client.callTool({ name, arguments: args }).then((r) => r);

try {
  await call("get_app_state", { app: "MockApp" });
  await sleep(120);
  await call("click", { app: "MockApp", element_index: "2" });
  await sleep(120);
  await call("type_text", { app: "MockApp", text: "hello" });
  await sleep(120);
  await call("press_key", { app: "MockApp", key: "ctrl+a" });
  await sleep(120);
  await call("scroll", { app: "MockApp", element_index: "1", direction: "down" });
  await sleep(120);
  await call("set_value", { app: "MockApp", element_index: "1", value: "abc" });
  await sleep(120);
  await call("drag", { app: "MockApp", from_element_index: "1", to_element_index: "2" });
  await sleep(200);
} finally {
  for (const timer of timers) clearInterval(timer);
  await client.close().catch(() => {});
}

const missing = expected.filter((text) => !captions.includes(text));
console.log(
  JSON.stringify(
    {
      ok: missing.length === 0,
      expected,
      seen: captions,
      missing,
    },
    null,
    2,
  ),
);
process.exit(missing.length === 0 ? 0 : 1);
