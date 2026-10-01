const assert = require("assert");
const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawn } = require("child_process");

const hookPath = path.resolve(__dirname, "../Scripts/PedroAgentBridgeHook.js");

function waitFor(check, timeoutMs = 3000) {
  const startedAt = Date.now();
  return new Promise((resolve, reject) => {
    const poll = () => {
      const value = check();
      if (value) return resolve(value);
      if (Date.now() - startedAt >= timeoutMs) return reject(new Error("Timed out waiting for bridge state"));
      setTimeout(poll, 20);
    };
    poll();
  });
}

function runHook(home) {
  const child = spawn(process.execPath, [hookPath, "codex", "PermissionRequest"], {
    env: { ...process.env, PEDRO_AGENT_BRIDGE_HOME: home },
    stdio: ["pipe", "pipe", "inherit"],
  });
  let stdout = "";
  child.stdout.on("data", (chunk) => { stdout += chunk; });
  child.stdin.end(JSON.stringify({
    session_id: "session-test",
    thread_id: "thread-test",
    tool_name: "Shell",
    tool_input: { command: "npm test" },
    cwd: "/tmp/project",
  }));
  return {
    child,
    output: new Promise((resolve, reject) => {
      child.on("error", reject);
      child.on("close", (code) => code === 0 ? resolve(stdout.trim()) : reject(new Error(`Hook exited ${code}`)));
    }),
  };
}

async function permissionRoundTrip(decision) {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), "pedro-agent-hook-"));
  const bridge = path.join(home, ".pedroops", "agent_bridge");
  fs.mkdirSync(bridge, { recursive: true });
  fs.writeFileSync(path.join(bridge, "heartbeat.json"), JSON.stringify({ updatedAt: Date.now() }));

  try {
    const running = runHook(home);
    const eventPath = await waitFor(() => {
      const directory = path.join(bridge, "events");
      if (!fs.existsSync(directory)) return null;
      return fs.readdirSync(directory).map((name) => path.join(directory, name))[0] || null;
    });
    const event = JSON.parse(fs.readFileSync(eventPath, "utf8"));
    const responses = path.join(bridge, "responses");
    fs.mkdirSync(responses, { recursive: true });
    fs.writeFileSync(path.join(responses, `${event.requestID}.json`), JSON.stringify({ decision }));

    const output = JSON.parse(await running.output);
    assert.equal(output.hookSpecificOutput.hookEventName, "PermissionRequest");
    assert.equal(output.hookSpecificOutput.decision.behavior, decision);
  } finally {
    fs.rmSync(home, { recursive: true, force: true });
  }
}

async function main() {
  const noHeartbeatHome = fs.mkdtempSync(path.join(os.tmpdir(), "pedro-agent-hook-no-heartbeat-"));
  try {
    const startedAt = Date.now();
    const output = await runHook(noHeartbeatHome).output;
    assert.equal(output, "{}");
    assert(Date.now() - startedAt < 2000, "Missing heartbeat should immediately preserve native approval UI");
  } finally {
    fs.rmSync(noHeartbeatHome, { recursive: true, force: true });
  }

  await permissionRoundTrip("allow");
  await permissionRoundTrip("deny");
  console.log("PedroAgentBridgeHookTests passed");
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
