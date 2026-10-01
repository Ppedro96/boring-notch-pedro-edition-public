#!/opt/homebrew/bin/node

const crypto = require("crypto");
const fs = require("fs");
const os = require("os");
const path = require("path");

const provider = process.argv[2] === "claude" ? "claude" : "codex";
const eventName = process.argv[3] || "Notification";
const bridgeHome = process.env.PEDRO_AGENT_BRIDGE_HOME || os.homedir();
const bridgeDirectory = path.join(bridgeHome, ".pedroops", "agent_bridge");
const eventsDirectory = path.join(bridgeDirectory, "events");
const responsesDirectory = path.join(bridgeDirectory, "responses");
const heartbeatPath = path.join(bridgeDirectory, "heartbeat.json");

function readPayload() {
  try {
    const input = fs.readFileSync(0, "utf8").trim();
    return input ? JSON.parse(input) : {};
  } catch (_error) {
    return {};
  }
}

function firstString(...values) {
  return values.find((value) => typeof value === "string" && value.trim())?.trim() || null;
}

function terminalBundleIdentifier() {
  if (provider === "codex" && !process.env.TERM_PROGRAM) return "com.openai.codex";
  const terminal = process.env.TERM_PROGRAM || "";
  const mappings = {
    Apple_Terminal: "com.apple.Terminal",
    iTerm_app: "com.googlecode.iterm2",
    iTerm2: "com.googlecode.iterm2",
    vscode: "com.microsoft.VSCode",
    WarpTerminal: "dev.warp.Warp-Stable",
    ghostty: "com.mitchellh.ghostty",
  };
  return mappings[terminal] || null;
}

function eventKind(payload) {
  if (eventName === "PermissionRequest") return "permissionRequest";
  if (eventName === "SessionStart" || eventName === "UserPromptSubmit") return "working";
  if (eventName === "Stop" || eventName === "SessionEnd") return "completed";
  const notificationType = firstString(payload.notification_type, payload.notificationType, payload.type);
  if (notificationType === "elicitation_dialog") return "question";
  if (notificationType === "permission_prompt") return "notification";
  return "notification";
}

function promptText(payload) {
  const toolInput = payload.tool_input || payload.toolInput || {};
  return firstString(
    payload.message,
    payload.prompt,
    payload.reason,
    toolInput.command,
    toolInput.description,
    toolInput.file_path,
    toolInput.path,
    JSON.stringify(toolInput) === "{}" ? null : JSON.stringify(toolInput)
  )?.slice(0, 1200) || null;
}

function writeJSONAtomic(targetPath, object) {
  fs.mkdirSync(path.dirname(targetPath), { recursive: true });
  const temporaryPath = `${targetPath}.${process.pid}.${crypto.randomUUID()}.tmp`;
  fs.writeFileSync(temporaryPath, JSON.stringify(object));
  fs.renameSync(temporaryPath, targetPath);
}

function hasFreshHeartbeat(now) {
  try {
    const heartbeat = JSON.parse(fs.readFileSync(heartbeatPath, "utf8"));
    return Number.isFinite(heartbeat.updatedAt) && now - heartbeat.updatedAt <= 8000;
  } catch (_error) {
    return false;
  }
}

function sleep(milliseconds) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, milliseconds);
}

function decisionOutput(decision) {
  const decisionObject = {
    behavior: decision === "allow" ? "allow" : "deny",
  };
  if (decision !== "allow") decisionObject.message = "Negado no Boring Notch";
  return {
    hookSpecificOutput: {
      hookEventName: "PermissionRequest",
      decision: decisionObject,
    },
  };
}

const payload = readPayload();
const now = Date.now();
const requestID = crypto.randomUUID();
const sessionID = firstString(
  payload.session_id,
  payload.sessionId,
  payload.thread_id,
  payload.threadId,
  payload.conversation_id,
  payload.conversationId
) || `unknown-${process.pid}`;
const threadID = firstString(payload.thread_id, payload.threadId, payload.session_id, payload.sessionId);
const kind = eventKind(payload);
const event = {
  eventID: crypto.randomUUID(),
  provider,
  kind,
  sessionID,
  threadID,
  requestID: kind === "permissionRequest" ? requestID : null,
  title: firstString(payload.tool_name, payload.toolName, payload.title, eventName),
  prompt: promptText(payload),
  cwd: firstString(payload.cwd, process.cwd()),
  model: firstString(payload.model),
  terminalBundleIdentifier: terminalBundleIdentifier(),
  createdAt: now,
  expiresAt: kind === "permissionRequest" ? now + 120000 : null,
};

try {
  const eventPath = path.join(eventsDirectory, `${now}-${event.eventID}.json`);
  writeJSONAtomic(eventPath, event);
} catch (_error) {
  if (kind === "permissionRequest") process.stdout.write("{}\n");
  process.exit(0);
}

if (kind !== "permissionRequest") process.exit(0);
if (!hasFreshHeartbeat(now)) {
  process.stdout.write("{}\n");
  process.exit(0);
}

const responsePath = path.join(responsesDirectory, `${requestID}.json`);
const deadline = now + 120000;
while (Date.now() < deadline) {
  try {
    const response = JSON.parse(fs.readFileSync(responsePath, "utf8"));
    if (response.decision === "allow" || response.decision === "deny") {
      fs.unlinkSync(responsePath);
      const resolvedAt = Date.now();
      writeJSONAtomic(
        path.join(eventsDirectory, `${resolvedAt}-${crypto.randomUUID()}.json`),
        {
          ...event,
          eventID: crypto.randomUUID(),
          kind: "permissionResolved",
          createdAt: resolvedAt,
          expiresAt: null,
        }
      );
      process.stdout.write(`${JSON.stringify(decisionOutput(response.decision))}\n`);
      process.exit(0);
    }
  } catch (_error) {
    // The response file is expected to be absent while the user decides.
  }
  sleep(200);
}

process.stdout.write("{}\n");
