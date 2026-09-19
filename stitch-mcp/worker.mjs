import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

import { StitchToolClient } from "@google/stitch-sdk";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const jobFile = process.argv[2];

if (!jobFile) process.exit(2);

function readJob() {
  return JSON.parse(fs.readFileSync(jobFile, "utf8"));
}

function writeJob(job) {
  const temp = `${jobFile}.tmp`;
  fs.writeFileSync(temp, JSON.stringify(job, null, 2), { encoding: "utf8", mode: 0o600 });
  fs.renameSync(temp, jobFile);
}

function updateJob(patch) {
  writeJob({ ...readJob(), ...patch, updatedAt: new Date().toISOString() });
}

const apiKey = process.env.STITCH_API_KEY?.trim();
if (!apiKey) {
  updateJob({
    status: "failed",
    failedAt: new Date().toISOString(),
    error: { name: "ConfigurationError", message: "STITCH_API_KEY is required" },
  });
  process.exit(1);
}

let stitch;
try {
  const job = readJob();
  updateJob({ status: "running", startedAt: new Date().toISOString(), workerPid: process.pid });

  stitch = new StitchToolClient({ apiKey, timeout: 300000 });
  const result = await stitch.callTool("generate_screen_from_text", {
    projectId: job.input.projectId,
    prompt: job.input.prompt,
    deviceType: job.input.deviceType,
    modelId: job.input.modelId,
  });

  updateJob({
    status: "completed",
    completedAt: new Date().toISOString(),
    result,
    error: null,
  });
} catch (error) {
  try {
    updateJob({
      status: "failed",
      failedAt: new Date().toISOString(),
      error: {
        name: error?.name ?? "Error",
        message: error?.message ?? String(error),
      },
    });
  } catch {
    // If the job file is unavailable there is nowhere safe to persist the error.
  }
  process.exitCode = 1;
} finally {
  try {
    await stitch?.close();
  } catch {
    // Best-effort cleanup.
  }
}
