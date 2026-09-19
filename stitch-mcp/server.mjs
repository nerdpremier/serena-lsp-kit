import fs from "node:fs";
import path from "node:path";
import { spawn } from "node:child_process";
import { randomUUID } from "node:crypto";
import { fileURLToPath } from "node:url";

import { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import { StitchToolClient } from "@google/stitch-sdk";
import { z } from "zod";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const workerFile = path.join(__dirname, "worker.mjs");
const jobsDir = path.join(__dirname, "jobs");

function argumentValue(name) {
  const index = process.argv.indexOf(name);
  return index >= 0 ? process.argv[index + 1] : undefined;
}

const workspaceRoot = path.resolve(argumentValue("--workspace") || process.cwd());
fs.mkdirSync(jobsDir, { recursive: true, mode: 0o700 });

const apiKey = process.env.STITCH_API_KEY?.trim();
if (!apiKey) throw new Error("STITCH_API_KEY is required");

function textResult(value) {
  return {
    content: [{ type: "text", text: typeof value === "string" ? value : JSON.stringify(value, null, 2) }],
  };
}

function jobPath(jobId) {
  if (!/^[0-9a-f-]{36}$/i.test(jobId)) throw new Error("Invalid job_id");
  return path.join(jobsDir, `${jobId}.json`);
}

function readJob(jobId) {
  const file = jobPath(jobId);
  if (!fs.existsSync(file)) throw new Error(`Job not found: ${jobId}`);
  return JSON.parse(fs.readFileSync(file, "utf8"));
}

function writeJob(job) {
  fs.writeFileSync(jobPath(job.id), JSON.stringify(job, null, 2), { encoding: "utf8", mode: 0o600 });
}

function slugify(value) {
  return String(value || "stitch-screen")
    .trim()
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "") || "stitch-screen";
}

function safeOutputDir(relativeDir) {
  if (path.isAbsolute(relativeDir)) throw new Error("output_dir must be relative to the project workspace");
  const target = path.resolve(workspaceRoot, relativeDir);
  const prefix = `${workspaceRoot}${path.sep}`;
  if (target !== workspaceRoot && !target.startsWith(prefix)) {
    throw new Error("output_dir must stay inside the project workspace");
  }
  return target;
}

function collectObjects(value, output = []) {
  if (Array.isArray(value)) {
    for (const item of value) collectObjects(item, output);
    return output;
  }
  if (value && typeof value === "object") {
    output.push(value);
    for (const item of Object.values(value)) collectObjects(item, output);
  }
  return output;
}

function stringValues(object) {
  return Object.values(object)
    .filter((value) => typeof value === "string")
    .map((value) => value.trim());
}

function findByExactText(root, text) {
  const wanted = String(text).trim().toLowerCase();
  return collectObjects(root).find((object) =>
    stringValues(object).some((value) => value.toLowerCase() === wanted),
  );
}

function extractResourceId(object, resource, fallbackPattern) {
  if (!object || typeof object !== "object") return null;
  for (const [key, value] of Object.entries(object)) {
    if (typeof value !== "string") continue;
    const resourceMatch = value.match(new RegExp(`${resource}/([^/]+)`, "i"));
    if (resourceMatch) return resourceMatch[1];
    if (fallbackPattern.test(key) && /^[a-z0-9_-]+$/i.test(value)) return value;
  }
  return null;
}

function collectUrls(value, output = []) {
  if (typeof value === "string") {
    if (/^https?:\/\//i.test(value)) output.push(value);
  } else if (Array.isArray(value)) {
    for (const item of value) collectUrls(item, output);
  } else if (value && typeof value === "object") {
    for (const item of Object.values(value)) collectUrls(item, output);
  }
  return output;
}

function allowedArtifactHost(hostname) {
  const host = hostname.toLowerCase();
  return host === "googleusercontent.com" ||
    host.endsWith(".googleusercontent.com") ||
    host === "usercontent.google.com" ||
    host.endsWith(".usercontent.google.com");
}

async function saveArtifact(url, outputDir, imageIndex) {
  const parsed = new URL(url);
  if (!allowedArtifactHost(parsed.hostname)) {
    return { skipped: true, source_url: url, reason: `host not allowed: ${parsed.hostname}` };
  }

  const response = await fetch(url, { redirect: "follow" });
  if (!response.ok) throw new Error(`Artifact download failed: HTTP ${response.status}`);

  const bytes = Buffer.from(await response.arrayBuffer());
  if (bytes.length > 20 * 1024 * 1024) throw new Error(`Artifact too large: ${bytes.length} bytes`);

  const contentType = (response.headers.get("content-type") || "").toLowerCase();
  const prefix = bytes.subarray(0, Math.min(bytes.length, 256)).toString("utf8").trimStart().toLowerCase();
  const html = contentType.includes("text/html") || prefix.startsWith("<!doctype html") || prefix.startsWith("<html");
  let filename;
  if (html) filename = "screen.html";
  else if (contentType.includes("image/png")) filename = `screenshot${imageIndex ? `-${imageIndex + 1}` : ""}.png`;
  else if (contentType.includes("image/jpeg")) filename = `screenshot${imageIndex ? `-${imageIndex + 1}` : ""}.jpg`;
  else if (contentType.includes("image/webp")) filename = `screenshot${imageIndex ? `-${imageIndex + 1}` : ""}.webp`;
  else return { skipped: true, source_url: url, reason: `unsupported content-type: ${contentType || "unknown"}` };

  const file = path.join(outputDir, filename);
  fs.writeFileSync(file, bytes, { mode: 0o600 });
  return {
    skipped: false,
    relative_path: path.relative(workspaceRoot, file),
    bytes: bytes.length,
    content_type: contentType,
    source_url: url,
  };
}

const stitch = new StitchToolClient({ apiKey, timeout: 90000 });
const server = new McpServer(
  { name: "serena-lsp-kit-stitch", version: "1.0.0" },
  { capabilities: { tools: {} } },
);

server.registerTool(
  "stitch_create_project",
  {
    title: "Create Stitch project",
    description: "Create a Google Stitch project for a UI design iteration.",
    inputSchema: { title: z.string().min(1) },
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: true },
  },
  async ({ title }) => textResult(await stitch.callTool("create_project", { title })),
);

server.registerTool(
  "stitch_list_projects",
  {
    title: "List Stitch projects",
    description: "List Google Stitch projects owned by the configured API-key account.",
    inputSchema: {},
    annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: true },
  },
  async () => textResult(await stitch.callTool("list_projects", { filter: "view=owned" })),
);

server.registerTool(
  "stitch_start_generate",
  {
    title: "Start Stitch design generation",
    description: "Start an asynchronous Stitch screen generation and return a job_id immediately.",
    inputSchema: {
      projectId: z.string().min(1),
      prompt: z.string().min(1),
      deviceType: z.enum(["DESKTOP", "MOBILE", "TABLET", "AGNOSTIC"]).default("DESKTOP"),
      modelId: z.enum(["GEMINI_3_FLASH", "GEMINI_3_1_PRO"]).default("GEMINI_3_FLASH"),
    },
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: true },
  },
  async ({ projectId, prompt, deviceType, modelId }) => {
    const id = randomUUID();
    const now = new Date().toISOString();
    writeJob({
      id,
      type: "generate_screen_from_text",
      status: "queued",
      createdAt: now,
      updatedAt: now,
      input: { projectId, prompt, deviceType, modelId },
      result: null,
      error: null,
    });

    const child = spawn(process.execPath, [workerFile, jobPath(id)], {
      cwd: __dirname,
      detached: true,
      stdio: "ignore",
      windowsHide: true,
    });
    child.unref();

    return textResult({
      job_id: id,
      status: "queued",
      next: "Poll stitch_job_status, then call stitch_job_result after completion.",
    });
  },
);

server.registerTool(
  "stitch_job_status",
  {
    title: "Check Stitch generation status",
    description: "Return queued, running, completed, or failed for a Stitch generation job.",
    inputSchema: { job_id: z.string().uuid() },
    annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  },
  async ({ job_id }) => {
    const job = readJob(job_id);
    return textResult({
      job_id: job.id,
      status: job.status,
      createdAt: job.createdAt,
      startedAt: job.startedAt ?? null,
      completedAt: job.completedAt ?? null,
      failedAt: job.failedAt ?? null,
      error: job.error ?? null,
      has_result: job.result != null,
    });
  },
);

server.registerTool(
  "stitch_job_result",
  {
    title: "Get Stitch generation result",
    description: "Return the completed generation result, or the current status while it is still running.",
    inputSchema: { job_id: z.string().uuid() },
    annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  },
  async ({ job_id }) => {
    const job = readJob(job_id);
    if (job.status !== "completed") {
      return textResult({ job_id: job.id, status: job.status, error: job.error ?? null });
    }
    return textResult({ job_id: job.id, status: job.status, result: job.result });
  },
);

server.registerTool(
  "stitch_list_jobs",
  {
    title: "List recent Stitch jobs",
    description: "List recent design-generation jobs created by this connector.",
    inputSchema: { limit: z.number().int().min(1).max(20).default(10) },
    annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: false },
  },
  async ({ limit }) => {
    const jobs = fs.readdirSync(jobsDir)
      .filter((name) => name.endsWith(".json"))
      .map((name) => JSON.parse(fs.readFileSync(path.join(jobsDir, name), "utf8")))
      .sort((a, b) => String(b.createdAt).localeCompare(String(a.createdAt)))
      .slice(0, limit)
      .map((job) => ({ id: job.id, status: job.status, createdAt: job.createdAt, projectId: job.input?.projectId }));
    return textResult(jobs);
  },
);

server.registerTool(
  "stitch_list_screens",
  {
    title: "List Stitch screens",
    description: "List generated screens and artifact metadata in a Stitch project.",
    inputSchema: { projectId: z.string().min(1) },
    annotations: { readOnlyHint: true, destructiveHint: false, idempotentHint: true, openWorldHint: true },
  },
  async ({ projectId }) => textResult(await stitch.callTool("list_screens", { projectId })),
);

server.registerTool(
  "stitch_pull_screen_artifacts",
  {
    title: "Pull Stitch screen artifacts into the project",
    description: "Find a Stitch screen by project/screen title and save supported HTML or screenshot artifacts inside the project workspace.",
    inputSchema: {
      project_title: z.string().min(1),
      screen_title: z.string().min(1).optional(),
      output_dir: z.string().min(1).optional(),
    },
    annotations: { readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: true },
  },
  async ({ project_title, screen_title, output_dir }) => {
    const projects = await stitch.callTool("list_projects", { filter: "view=owned" });
    const project = findByExactText(projects, project_title);
    if (!project) throw new Error(`Project not found by exact title: ${project_title}`);
    const projectId = extractResourceId(project, "projects", /^(project_?id|id)$/i);
    if (!projectId) throw new Error(`Could not determine project ID for: ${project_title}`);

    const screens = await stitch.callTool("list_screens", { projectId });
    const wantedScreen = screen_title || project_title;
    let screen = findByExactText(screens, wantedScreen);
    if (!screen && !screen_title) {
      const candidates = collectObjects(screens).filter((object) => extractResourceId(object, "screens", /^(screen_?id|id)$/i));
      if (candidates.length === 1) screen = candidates[0];
    }
    if (!screen) throw new Error(`Screen not found by exact title: ${wantedScreen}`);

    const screenId = extractResourceId(screen, "screens", /^(screen_?id|id)$/i);
    if (!screenId) throw new Error(`Could not determine screen ID for: ${wantedScreen}`);

    const urls = [...new Set(collectUrls(screen))];
    if (!urls.length) throw new Error("No downloadable artifact URLs found on the selected screen");

    const outputDir = safeOutputDir(output_dir || path.join("stitch-output", slugify(project_title)));
    fs.mkdirSync(outputDir, { recursive: true, mode: 0o700 });

    const downloads = [];
    let imageIndex = 0;
    for (const url of urls) {
      const result = await saveArtifact(url, outputDir, imageIndex);
      if (!result.skipped && result.content_type.startsWith("image/")) imageIndex += 1;
      downloads.push(result);
    }

    const saved = downloads.filter((item) => !item.skipped);
    if (!saved.length) throw new Error("No supported HTML or image artifacts were saved");

    return textResult({
      project_title,
      project_id: projectId,
      screen_title: wantedScreen,
      screen_id: screenId,
      output_dir: path.relative(workspaceRoot, outputDir),
      saved_files: saved,
      skipped: downloads.filter((item) => item.skipped),
    });
  },
);

async function shutdown() {
  try { await stitch.close(); } catch {}
  try { await server.close(); } catch {}
}

process.stdout.on("error", (error) => {
  if (error?.code === "EPIPE") process.exit(0);
  throw error;
});
process.on("SIGINT", async () => { await shutdown(); process.exit(0); });
process.on("SIGTERM", async () => { await shutdown(); process.exit(0); });

await server.connect(new StdioServerTransport());
console.error(`[serena-lsp-kit-stitch] MCP server running for workspace ${workspaceRoot}`);
