#!/usr/bin/env node

"use strict";

const fs = require("fs");
const os = require("os");
const path = require("path");
const crypto = require("crypto");

const REPO_ROOT = path.resolve(__dirname, "..");
const DEFAULT_WORKSPACE_ROOT = path.resolve(REPO_ROOT, "..");
const DEFAULT_STATE_PATH = path.join(DEFAULT_WORKSPACE_ROOT, ".workq", "state.json");
const DEFAULT_LOCK_DIR = path.join(DEFAULT_WORKSPACE_ROOT, ".locks");
const DEFAULT_LEASE_MS = 2 * 60 * 60 * 1000; // 2h
const DEFAULT_STALE_TTL_MS = 2 * 60 * 60 * 1000; // 2h
const DEFAULT_STATE_LOCK_WAIT_MS = 10_000;
const DEFAULT_STATE_LOCK_STALE_MS = 30_000;
const DEFAULT_STATE_LOCK_POLL_MS = 50;

function emitJson(obj, exitCode = 0) {
  process.stdout.write(`${JSON.stringify(obj)}\n`);
  process.exit(exitCode);
}

class CliError extends Error {
  constructor(code, message, details = {}) {
    super(message);
    this.name = "CliError";
    this.code = code;
    this.details = details;
  }
}

function raise(error, message, details = {}) {
  throw new CliError(error, message, details);
}

function fail(error, message, details = {}) {
  emitJson({ ok: false, error, message, ...details }, 1);
}

function sleepMs(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

function toNumber(value, fallback) {
  if (value === undefined || value === null || value === "") return fallback;
  const n = Number(value);
  return Number.isFinite(n) ? n : fallback;
}

function nowIso(ms = Date.now()) {
  return new Date(ms).toISOString();
}

function stampLocal(ms = Date.now()) {
  const d = new Date(ms);
  const yyyy = String(d.getFullYear());
  const mm = String(d.getMonth() + 1).padStart(2, "0");
  const dd = String(d.getDate()).padStart(2, "0");
  const hh = String(d.getHours()).padStart(2, "0");
  const min = String(d.getMinutes()).padStart(2, "0");
  return `${yyyy}${mm}${dd}-${hh}${min}`;
}

function parseArgs(argv) {
  const out = { _: [] };
  for (let i = 0; i < argv.length; i += 1) {
    const token = argv[i];
    if (!token.startsWith("--")) {
      out._.push(token);
      continue;
    }

    const body = token.slice(2);
    if (!body) continue;

    const eq = body.indexOf("=");
    if (eq >= 0) {
      const k = body.slice(0, eq);
      const v = body.slice(eq + 1);
      out[k] = v;
      continue;
    }

    const k = body;
    const next = argv[i + 1];
    if (next !== undefined && !next.startsWith("--")) {
      out[k] = next;
      i += 1;
    } else {
      out[k] = true;
    }
  }
  return out;
}

function resolveStatePath(args) {
  const p = args.state || process.env.WORKQ_STATE || DEFAULT_STATE_PATH;
  return path.resolve(p);
}

function resolveLockDir(args) {
  const p = args["lock-dir"] || process.env.WORKQ_LOCK_DIR || DEFAULT_LOCK_DIR;
  return path.resolve(p);
}

function ensureDir(dirPath) {
  fs.mkdirSync(dirPath, { recursive: true });
}

function defaultState(nowMs = Date.now()) {
  return {
    version: 1,
    createdAtMs: nowMs,
    updatedAtMs: nowMs,
    backlog: {
      file: null,
      syncedAtMs: null,
      syncedAt: null,
      items: [],
    },
    claims: {},
  };
}

function loadState(statePath) {
  if (!fs.existsSync(statePath)) return defaultState();

  const raw = fs.readFileSync(statePath, "utf8");
  let parsed;
  try {
    parsed = JSON.parse(raw);
  } catch (err) {
    raise("E_STATE_PARSE", `State file is not valid JSON: ${statePath}`, { statePath });
  }

  if (!parsed || typeof parsed !== "object") {
    raise("E_STATE_SHAPE", `State file has invalid shape: ${statePath}`, { statePath });
  }

  if (!parsed.backlog || typeof parsed.backlog !== "object") {
    parsed.backlog = { file: null, syncedAtMs: null, syncedAt: null, items: [] };
  }
  if (!Array.isArray(parsed.backlog.items)) parsed.backlog.items = [];
  if (!parsed.claims || typeof parsed.claims !== "object" || Array.isArray(parsed.claims)) {
    parsed.claims = {};
  }
  if (typeof parsed.version !== "number") parsed.version = 1;
  if (typeof parsed.createdAtMs !== "number") parsed.createdAtMs = Date.now();
  if (typeof parsed.updatedAtMs !== "number") parsed.updatedAtMs = Date.now();

  return parsed;
}

function writeJsonAtomic(filePath, obj) {
  ensureDir(path.dirname(filePath));
  const tmpPath = `${filePath}.tmp.${process.pid}.${crypto.randomUUID()}`;
  const text = `${JSON.stringify(obj, null, 2)}\n`;
  fs.writeFileSync(tmpPath, text, { encoding: "utf8", mode: 0o644 });
  fs.renameSync(tmpPath, filePath);
}

function withStateLock(statePath, args, fn) {
  const waitMs = toNumber(args["state-lock-wait-ms"], DEFAULT_STATE_LOCK_WAIT_MS);
  const staleMs = toNumber(args["state-lock-stale-ms"], DEFAULT_STATE_LOCK_STALE_MS);
  const pollMs = toNumber(args["state-lock-poll-ms"], DEFAULT_STATE_LOCK_POLL_MS);

  const lockPath = `${statePath}.mutex`;
  ensureDir(path.dirname(statePath));

  const started = Date.now();
  while (true) {
    try {
      const fd = fs.openSync(lockPath, "wx", 0o644);
      const payload = {
        pid: process.pid,
        host: os.hostname(),
        createdAtMs: Date.now(),
        createdAt: nowIso(),
      };
      fs.writeFileSync(fd, `${JSON.stringify(payload)}\n`, "utf8");
      fs.closeSync(fd);
      break;
    } catch (err) {
      if (err && err.code !== "EEXIST") throw err;

      try {
        const st = fs.statSync(lockPath);
        if (Date.now() - st.mtimeMs > staleMs) {
          fs.unlinkSync(lockPath);
          continue;
        }
      } catch (stErr) {
        if (stErr && stErr.code === "ENOENT") continue;
      }

      if (Date.now() - started > waitMs) {
        raise("E_STATE_LOCK_TIMEOUT", `Timed out acquiring state lock: ${lockPath}`, {
          statePath,
          lockPath,
          waitMs,
        });
      }
      sleepMs(pollMs);
    }
  }

  try {
    return fn();
  } finally {
    try {
      fs.unlinkSync(lockPath);
    } catch (_err) {
      // ignore
    }
  }
}

function parseBacklog(backlogFile) {
  const text = fs.readFileSync(backlogFile, "utf8");
  const lines = text.split(/\r?\n/);

  let currentStart = -1;
  let doneStart = lines.length;

  for (let i = 0; i < lines.length; i += 1) {
    const t = lines[i].trim();
    if (currentStart < 0 && /^##\s+Current items\s*$/i.test(t)) {
      currentStart = i + 1;
      continue;
    }
    if (currentStart >= 0 && /^##\s+Done\s*$/i.test(t)) {
      doneStart = i;
      break;
    }
  }

  if (currentStart < 0) {
    raise("E_BACKLOG_SECTION", "Could not find '## Current items' section", { backlogFile });
  }

  const items = [];
  for (let i = currentStart; i < doneStart; i += 1) {
    const raw = lines[i];
    if (!raw || !raw.trim()) continue;

    const line = raw.trim();
    const m = line.match(/^([0-9]+[a-z0-9]*)\.\s+(.*)$/i);
    if (!m) continue;

    const itemId = m[1];
    const queueTagMatch = line.match(/\[([a-z]+)\]/i);
    const queueTag = queueTagMatch ? queueTagMatch[1].toLowerCase() : null;
    const noAutoStart = /\*\*no-auto-start\*\*/i.test(line);
    const blockedBy = /\bblocked-by\s*:/i.test(line);
    const noAutoMerge = /\*\*no-auto-merge\*\*/i.test(line);

    const skipReasons = [];
    if (queueTag !== "zsc") skipReasons.push("not_zsc");
    if (noAutoStart) skipReasons.push("no_auto_start");
    if (blockedBy) skipReasons.push("blocked_by");

    items.push({
      itemId,
      queueTag,
      workLine: line,
      lineNumber: i + 1,
      noAutoStart,
      noAutoMerge,
      blockedBy,
      eligible: skipReasons.length === 0,
      skipReasons,
    });
  }

  return {
    backlogFile: path.resolve(backlogFile),
    scannedAtMs: Date.now(),
    scannedAt: nowIso(),
    items,
  };
}

function stateClaimIsTerminal(claim) {
  if (!claim) return false;
  const status = (claim.status || "").toLowerCase();
  return status === "done" || status === "complete" || status === "completed" || status === "pr_opened";
}

function claimIsStale(claim, nowMs, ttlMsOverride) {
  if (!claim) return false;
  if (stateClaimIsTerminal(claim)) return false;
  const heartbeatAtMs = claim.heartbeatAtMs || claim.claimedAtMs;
  if (!heartbeatAtMs) return false;
  const ttlMs = ttlMsOverride || toNumber(claim.leaseMs, DEFAULT_STALE_TTL_MS);
  return nowMs - heartbeatAtMs > ttlMs;
}

function lockPathFor(lockDir, itemId) {
  return path.join(lockDir, `workitem-${itemId}.lock`);
}

function readJsonIfExists(filePath) {
  if (!fs.existsSync(filePath)) return null;
  const raw = fs.readFileSync(filePath, "utf8");
  try {
    return JSON.parse(raw);
  } catch (_err) {
    return null;
  }
}

function writeLockAtomic(lockPath, payload, allowOverwrite) {
  ensureDir(path.dirname(lockPath));
  const text = `${JSON.stringify(payload, null, 2)}\n`;

  if (!allowOverwrite) {
    const fd = fs.openSync(lockPath, "wx", 0o644);
    fs.writeFileSync(fd, text, "utf8");
    fs.closeSync(fd);
    return;
  }

  const tmpPath = `${lockPath}.tmp.${process.pid}.${crypto.randomUUID()}`;
  fs.writeFileSync(tmpPath, text, { encoding: "utf8", mode: 0o644 });
  fs.renameSync(tmpPath, lockPath);
}

function gatherLocks(lockDir) {
  if (!fs.existsSync(lockDir)) return [];
  const entries = fs.readdirSync(lockDir, { withFileTypes: true });
  const locks = [];
  for (const ent of entries) {
    if (!ent.isFile()) continue;
    if (!/^workitem-[^.]+\.lock$/.test(ent.name)) continue;
    const itemId = ent.name.replace(/^workitem-/, "").replace(/\.lock$/, "");
    const full = path.join(lockDir, ent.name);
    const st = fs.statSync(full);
    locks.push({
      itemId,
      lockPath: full,
      mtimeMs: st.mtimeMs,
      mtime: nowIso(st.mtimeMs),
      ageMs: Date.now() - st.mtimeMs,
      data: readJsonIfExists(full),
    });
  }
  locks.sort((a, b) => a.itemId.localeCompare(b.itemId));
  return locks;
}

function doSyncBacklog(args) {
  const backlogFile = args.file;
  if (!backlogFile) {
    fail("E_USAGE", "sync-backlog requires --file <WORK_ITEMS_GLOBAL.md>");
  }

  const statePath = resolveStatePath(args);
  const parsed = parseBacklog(path.resolve(backlogFile));

  const result = withStateLock(statePath, args, () => {
    const state = loadState(statePath);
    const nowMs = Date.now();

    state.backlog = {
      file: parsed.backlogFile,
      syncedAtMs: nowMs,
      syncedAt: nowIso(nowMs),
      items: parsed.items,
    };
    state.updatedAtMs = nowMs;

    writeJsonAtomic(statePath, state);

    const skipped = {
      not_zsc: 0,
      no_auto_start: 0,
      blocked_by: 0,
    };
    for (const it of parsed.items) {
      for (const reason of it.skipReasons) {
        if (Object.prototype.hasOwnProperty.call(skipped, reason)) {
          skipped[reason] += 1;
        }
      }
    }

    return {
      ok: true,
      command: "sync-backlog",
      statePath,
      backlogFile: parsed.backlogFile,
      totalItems: parsed.items.length,
      eligibleCount: parsed.items.filter((i) => i.eligible).length,
      skipped,
      syncedAtMs: nowMs,
      syncedAt: nowIso(nowMs),
    };
  });

  emitJson(result);
}

function buildLabel(queue, itemId, args) {
  if (args.label) return String(args.label);
  const prefix = queue === "zsc" ? "zsc-work" : `${queue}-work`;
  return `${prefix}-${itemId}-AUTO-${stampLocal()}`;
}

function doClaim(args) {
  const statePath = resolveStatePath(args);
  const lockDir = resolveLockDir(args);
  const queue = String(args.queue || "zsc").toLowerCase();
  const leaseMs = toNumber(args["lease-ms"], DEFAULT_LEASE_MS);
  const sessionKey = String(args.session || `workq-${process.pid}-${Date.now()}`);

  const result = withStateLock(statePath, args, () => {
    const state = loadState(statePath);
    const nowMs = Date.now();

    if (!state.backlog || !Array.isArray(state.backlog.items) || state.backlog.items.length === 0) {
      raise("E_BACKLOG_EMPTY", "No backlog items in state; run sync-backlog first", { statePath });
    }

    let skippedLocked = 0;
    let skippedClaimed = 0;
    let skippedIneligible = 0;

    for (const item of state.backlog.items) {
      if (item.queueTag !== queue || !item.eligible) {
        skippedIneligible += 1;
        continue;
      }

      const existingClaim = state.claims[item.itemId];
      if (existingClaim && !stateClaimIsTerminal(existingClaim)) {
        skippedClaimed += 1;
        continue;
      }

      const lockPath = lockPathFor(lockDir, item.itemId);
      if (fs.existsSync(lockPath)) {
        skippedLocked += 1;
        continue;
      }

      const label = buildLabel(queue, item.itemId, args);
      const lockPayload = {
        ts: nowIso(nowMs),
        itemId: item.itemId,
        label,
        workLine: item.workLine,
        queue,
        status: "claimed",
        sessionKey,
        claimedAt: nowIso(nowMs),
        heartbeatAt: nowIso(nowMs),
        leaseMs,
      };

      try {
        writeLockAtomic(lockPath, lockPayload, false);
      } catch (err) {
        if (err && err.code === "EEXIST") {
          skippedLocked += 1;
          continue;
        }
        throw err;
      }

      state.claims[item.itemId] = {
        itemId: item.itemId,
        queue,
        label,
        workLine: item.workLine,
        sessionKey,
        status: "claimed",
        leaseMs,
        lockPath,
        claimedAtMs: nowMs,
        heartbeatAtMs: nowMs,
        createdAtMs: nowMs,
        updatedAtMs: nowMs,
      };
      state.updatedAtMs = nowMs;
      writeJsonAtomic(statePath, state);

      return {
        ok: true,
        command: "claim",
        claimed: true,
        statePath,
        lockDir,
        item: {
          itemId: item.itemId,
          label,
          workLine: item.workLine,
          queue,
          sessionKey,
          leaseMs,
          claimedAtMs: nowMs,
          claimedAt: nowIso(nowMs),
          lockPath,
        },
      };
    }

    return {
      ok: true,
      command: "claim",
      claimed: false,
      reason: "no_eligible_items",
      statePath,
      lockDir,
      skipped: {
        ineligible: skippedIneligible,
        claimed: skippedClaimed,
        locked: skippedLocked,
      },
    };
  });

  emitJson(result);
}

function doHeartbeat(args) {
  const itemId = args.item;
  const sessionKey = args.session;
  if (!itemId || !sessionKey) {
    fail("E_USAGE", "heartbeat requires --item <id> --session <sessionKey>");
  }

  const statePath = resolveStatePath(args);
  const lockDir = resolveLockDir(args);
  const leaseMsOverride = toNumber(args["lease-ms"], undefined);

  const result = withStateLock(statePath, args, () => {
    const state = loadState(statePath);
    const claim = state.claims[itemId];
    if (!claim) {
      raise("E_NOT_FOUND", `No claim found for item ${itemId}`, { itemId, statePath });
    }

    if (String(claim.sessionKey) !== String(sessionKey)) {
      raise("E_SESSION_MISMATCH", `Session key mismatch for item ${itemId}`, {
        itemId,
        expectedSession: claim.sessionKey,
        gotSession: sessionKey,
      });
    }

    const nowMs = Date.now();
    claim.heartbeatAtMs = nowMs;
    claim.updatedAtMs = nowMs;
    if (leaseMsOverride !== undefined) {
      claim.leaseMs = leaseMsOverride;
    }
    if (!claim.status) claim.status = "claimed";

    state.updatedAtMs = nowMs;
    writeJsonAtomic(statePath, state);

    const lockPath = claim.lockPath || lockPathFor(lockDir, itemId);
    let lockExists = fs.existsSync(lockPath);
    if (lockExists) {
      const current = readJsonIfExists(lockPath) || {};
      const merged = {
        ...current,
        itemId,
        label: claim.label || current.label,
        workLine: claim.workLine || current.workLine,
        status: claim.status,
        sessionKey: claim.sessionKey,
        heartbeatAt: nowIso(nowMs),
        leaseMs: claim.leaseMs,
      };
      writeLockAtomic(lockPath, merged, true);
    }

    const ttlMs = toNumber(claim.leaseMs, DEFAULT_STALE_TTL_MS);
    const ageMs = nowMs - (claim.claimedAtMs || nowMs);

    return {
      ok: true,
      command: "heartbeat",
      statePath,
      itemId,
      sessionKey,
      leaseMs: ttlMs,
      ageMs,
      stale: false,
      lockPath,
      lockExists,
      heartbeatAtMs: nowMs,
      heartbeatAt: nowIso(nowMs),
    };
  });

  emitJson(result);
}

function doComplete(args) {
  const itemId = args.item;
  if (!itemId) fail("E_USAGE", "complete requires --item <id>");

  const statePath = resolveStatePath(args);
  const lockDir = resolveLockDir(args);

  const branch = args.branch ? String(args.branch) : undefined;
  const prNumber = args.pr !== undefined ? Number(args.pr) : undefined;
  const prUrl = args.url ? String(args.url) : undefined;
  const sessionKey = args.session ? String(args.session) : undefined;

  const computedStatus = String(
    args.status || (branch || prUrl || Number.isFinite(prNumber) ? "pr_opened" : "done"),
  );

  if (args.pr !== undefined && !Number.isFinite(prNumber)) {
    fail("E_USAGE", "--pr must be a number", { got: args.pr });
  }

  const result = withStateLock(statePath, args, () => {
    const state = loadState(statePath);
    const nowMs = Date.now();

    const fromBacklog = (state.backlog.items || []).find((it) => it.itemId === itemId);
    const claim = state.claims[itemId] || {
      itemId,
      queue: fromBacklog?.queueTag || "zsc",
      label: args.label || buildLabel("zsc", itemId, args),
      workLine: fromBacklog?.workLine || null,
      sessionKey: sessionKey || null,
      claimedAtMs: nowMs,
      heartbeatAtMs: nowMs,
      createdAtMs: nowMs,
      lockPath: lockPathFor(lockDir, itemId),
    };

    if (sessionKey && claim.sessionKey && claim.sessionKey !== sessionKey) {
      raise("E_SESSION_MISMATCH", `Session key mismatch for item ${itemId}`, {
        itemId,
        expectedSession: claim.sessionKey,
        gotSession: sessionKey,
      });
    }

    claim.status = computedStatus;
    claim.updatedAtMs = nowMs;
    claim.completedAtMs = nowMs;
    if (sessionKey) claim.sessionKey = sessionKey;
    if (branch) claim.branch = branch;
    if (Number.isFinite(prNumber)) claim.prNumber = prNumber;
    if (prUrl) claim.prUrl = prUrl;

    state.claims[itemId] = claim;
    state.updatedAtMs = nowMs;
    writeJsonAtomic(statePath, state);

    const lockPath = claim.lockPath || lockPathFor(lockDir, itemId);
    const currentLock = readJsonIfExists(lockPath) || {};
    const lockPayload = {
      ...currentLock,
      ts: nowIso(nowMs),
      itemId,
      label: claim.label,
      workLine: claim.workLine || currentLock.workLine,
      status: computedStatus,
      sessionKey: claim.sessionKey || currentLock.sessionKey,
      branch: branch !== undefined ? branch : currentLock.branch,
      prNumber: Number.isFinite(prNumber) ? prNumber : currentLock.prNumber,
      prUrl: prUrl !== undefined ? prUrl : currentLock.prUrl,
      completedAt: nowIso(nowMs),
    };
    writeLockAtomic(lockPath, lockPayload, true);

    return {
      ok: true,
      command: "complete",
      statePath,
      lockPath,
      itemId,
      status: computedStatus,
      branch: claim.branch || null,
      prNumber: claim.prNumber || null,
      prUrl: claim.prUrl || null,
      completedAtMs: nowMs,
      completedAt: nowIso(nowMs),
    };
  });

  emitJson(result);
}

function doStatus(args) {
  const statePath = resolveStatePath(args);
  const lockDir = resolveLockDir(args);
  const staleOnly = Boolean(args.stale);
  const ttlOverride = toNumber(args["ttl-ms"], undefined);

  const state = loadState(statePath);
  const nowMs = Date.now();

  const claims = Object.values(state.claims || {})
    .map((claim) => {
      const ttlMs = ttlOverride || toNumber(claim.leaseMs, DEFAULT_STALE_TTL_MS);
      const heartbeatAtMs = claim.heartbeatAtMs || claim.claimedAtMs || null;
      const ageMs = claim.claimedAtMs ? nowMs - claim.claimedAtMs : null;
      const stale = claimIsStale(claim, nowMs, ttlOverride);
      const lockPath = claim.lockPath || lockPathFor(lockDir, claim.itemId);
      const lockExists = fs.existsSync(lockPath);

      return {
        itemId: claim.itemId,
        status: claim.status || null,
        queue: claim.queue || null,
        label: claim.label || null,
        sessionKey: claim.sessionKey || null,
        claimedAtMs: claim.claimedAtMs || null,
        heartbeatAtMs,
        leaseMs: ttlMs,
        ageMs,
        stale,
        lockPath,
        lockExists,
        branch: claim.branch || null,
        prNumber: claim.prNumber || null,
        prUrl: claim.prUrl || null,
      };
    })
    .sort((a, b) => String(a.itemId).localeCompare(String(b.itemId)));

  const lockRecords = gatherLocks(lockDir).map((lock) => {
    const itemClaim = state.claims[lock.itemId];
    const ttlMs = ttlOverride || toNumber(itemClaim?.leaseMs, DEFAULT_STALE_TTL_MS);
    const stale = lock.ageMs > ttlMs && (!itemClaim || !stateClaimIsTerminal(itemClaim));
    return {
      itemId: lock.itemId,
      lockPath: lock.lockPath,
      ageMs: lock.ageMs,
      mtimeMs: lock.mtimeMs,
      stale,
      status: lock.data?.status || null,
      label: lock.data?.label || null,
      sessionKey: lock.data?.sessionKey || null,
      prNumber: lock.data?.prNumber || null,
      prUrl: lock.data?.prUrl || null,
    };
  });

  const staleClaims = claims.filter((c) => c.stale);
  const staleLocks = lockRecords.filter((l) => l.stale);

  const output = {
    ok: true,
    command: "status",
    statePath,
    lockDir,
    nowMs,
    now: nowIso(nowMs),
    totals: {
      claims: claims.length,
      staleClaims: staleClaims.length,
      locks: lockRecords.length,
      staleLocks: staleLocks.length,
    },
    claims: staleOnly ? staleClaims : claims,
    locks: staleOnly ? staleLocks : lockRecords,
  };

  emitJson(output);
}

function helpObject() {
  return {
    ok: true,
    command: "help",
    usage: [
      "node scripts/workq.js <command> [options]",
      "",
      "Commands:",
      "  sync-backlog --file <WORK_ITEMS_GLOBAL.md> [--state <state.json>] [--lock-dir <dir>]",
      "  claim --state <state.json> [--queue zsc] [--session <sessionKey>] [--lease-ms <ms>] [--lock-dir <dir>]",
      "  heartbeat --state <state.json> --item <id> --session <sessionKey> [--lease-ms <ms>] [--lock-dir <dir>]",
      "  complete --state <state.json> --item <id> [--status <done|pr_opened>] [--branch <name>] [--pr <number>] [--url <prUrl>] [--session <sessionKey>] [--lock-dir <dir>]",
      "  status --state <state.json> [--stale] [--ttl-ms <ms>] [--lock-dir <dir>]",
      "  list --state <state.json> [--stale] [--ttl-ms <ms>] [--lock-dir <dir>]",
      "  help",
      "",
      "Notes:",
      "  - Output is strict JSON on stdout for all commands.",
      "  - Default state: ../.workq/state.json (relative to repo root).",
      "  - Default lock dir: ../.locks (workspace shared lock interop).",
    ],
  };
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  const command = args._[0] || (args.help || args.h ? "help" : null);

  if (!command) {
    fail("E_USAGE", "Missing command", { help: helpObject().usage });
  }

  if (command === "help" || command === "--help" || command === "-h") {
    emitJson(helpObject());
  }

  switch (command) {
    case "sync-backlog":
      doSyncBacklog(args);
      break;
    case "claim":
      doClaim(args);
      break;
    case "heartbeat":
      doHeartbeat(args);
      break;
    case "complete":
      doComplete(args);
      break;
    case "status":
    case "list":
      doStatus(args);
      break;
    default:
      fail("E_USAGE", `Unknown command: ${command}`, { help: helpObject().usage });
  }
}

try {
  main();
} catch (err) {
  if (err instanceof CliError) {
    fail(err.code || "E_RUNTIME", err.message || "Unhandled error", err.details || {});
  }
  fail("E_RUNTIME", err && err.message ? err.message : "Unhandled error", {
    stack: err && err.stack ? String(err.stack).split("\n") : undefined,
  });
}
