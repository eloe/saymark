#!/usr/bin/env node

import { createHash } from "node:crypto";
import { execFileSync } from "node:child_process";
import {
  mkdirSync,
  readFileSync,
  renameSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { basename, dirname, extname, isAbsolute, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repositoryRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const defaults = {
  manifest: join(repositoryRoot, "Benchmarks/Corpus/saymark-english-v1.json"),
  output: join(repositoryRoot, "Benchmarks/Corpus/local"),
};

function parseArguments(arguments_) {
  const options = { ...defaults };
  for (let index = 0; index < arguments_.length; index += 1) {
    const argument = arguments_[index];
    if (argument === "--manifest" || argument === "--output") {
      const value = arguments_[index + 1];
      if (!value) throw new Error(`${argument} requires a value`);
      options[argument.slice(2)] = isAbsolute(value)
        ? value
        : resolve(repositoryRoot, value);
      index += 1;
    } else {
      throw new Error(`Unknown argument: ${argument}`);
    }
  }
  return options;
}

function run(executable, arguments_, options = {}) {
  execFileSync(executable, arguments_, {
    encoding: "utf8",
    stdio: options.capture ? ["ignore", "pipe", "pipe"] : "inherit",
  });
}

function sha256(buffer) {
  return createHash("sha256").update(buffer).digest("hex");
}

async function fetchJSON(url) {
  const response = await fetchWithRetry(url);
  return response.json();
}

async function fetchBytes(url) {
  const response = await fetchWithRetry(url);
  return Buffer.from(await response.arrayBuffer());
}

async function fetchWithRetry(url, attempts = 4) {
  let lastError;
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    try {
      const response = await fetch(url, {
        headers: { "user-agent": "saymark-public-corpus-preparer/1" },
      });
      if (response.ok) return response;
      const retryable = response.status === 429 || response.status >= 500;
      lastError = new Error(`HTTP ${response.status} fetching ${url}`);
      if (!retryable) throw lastError;
    } catch (error) {
      lastError = error;
    }
    if (attempt < attempts) {
      await new Promise((resolvePromise) => {
        setTimeout(resolvePromise, 250 * 2 ** (attempt - 1));
      });
    }
  }
  throw lastError;
}

function ffprobeDuration(path) {
  return Number(
    execFileSync(
      "ffprobe",
      [
        "-v",
        "error",
        "-show_entries",
        "format=duration",
        "-of",
        "default=noprint_wrappers=1:nokey=1",
        path,
      ],
      { encoding: "utf8" }
    ).trim()
  );
}

function normalizeAudio(input, output, preparation) {
  run("ffmpeg", [
    "-y",
    "-nostdin",
    "-hide_banner",
    "-loglevel",
    "error",
    "-i",
    input,
    "-map_metadata",
    "-1",
    "-ac",
    String(preparation.channels),
    "-ar",
    String(preparation.sampleRateHz),
    "-c:a",
    preparation.encoding,
    "-bitexact",
    output,
  ]);
}

function addDeterministicNoise(input, output, preparation, duration) {
  const noise = preparation.noise;
  run("ffmpeg", [
    "-y",
    "-nostdin",
    "-hide_banner",
    "-loglevel",
    "error",
    "-i",
    input,
    "-f",
    "lavfi",
    "-i",
    `anoisesrc=color=${noise.color}:amplitude=${noise.amplitude}:sample_rate=${preparation.sampleRateHz}:duration=${duration}:seed=${noise.seed}`,
    "-filter_complex",
    "[0:a][1:a]amix=inputs=2:duration=first:normalize=0,alimiter=limit=0.98",
    "-map_metadata",
    "-1",
    "-ac",
    String(preparation.channels),
    "-ar",
    String(preparation.sampleRateHz),
    "-c:a",
    preparation.encoding,
    "-bitexact",
    output,
  ]);
}

function quoteConcatPath(path) {
  return path.replaceAll("'", "'\\''");
}

function buildLongCase(caseDefinition, sourcesByID, normalizedByID, output, preparation, working) {
  const silenceDuration = preparation.interClipSilenceSeconds;
  const target = caseDefinition.targetDurationSeconds;
  const selected = [];
  let occupied = 0;
  let cursor = 0;
  const firstCycle = caseDefinition.sourceIds;
  const repeatCycle = caseDefinition.repeatSourceIds ?? firstCycle;

  while (true) {
    const sourceID = cursor < firstCycle.length
      ? firstCycle[cursor]
      : repeatCycle[(cursor - firstCycle.length) % repeatCycle.length];
    const source = sourcesByID.get(sourceID);
    const addition = source.durationSeconds + (selected.length === 0 ? 0 : silenceDuration);
    if (occupied + addition > target) break;
    selected.push(sourceID);
    occupied += addition;
    cursor += 1;
  }
  if (selected.length === 0) {
    throw new Error(`${caseDefinition.id}: no source fits target duration`);
  }

  const silencePath = join(working, "silence.wav");
  if (!normalizedByID.has("__silence__")) {
    run("ffmpeg", [
      "-y",
      "-nostdin",
      "-hide_banner",
      "-loglevel",
      "error",
      "-f",
      "lavfi",
      "-i",
      `anullsrc=r=${preparation.sampleRateHz}:cl=mono`,
      "-t",
      String(silenceDuration),
      "-c:a",
      preparation.encoding,
      "-bitexact",
      silencePath,
    ]);
    normalizedByID.set("__silence__", silencePath);
  }

  const listPath = join(working, `${caseDefinition.id}.concat.txt`);
  const list = [];
  selected.forEach((sourceID, index) => {
    if (index > 0) list.push(`file '${quoteConcatPath(silencePath)}'`);
    list.push(`file '${quoteConcatPath(normalizedByID.get(sourceID))}'`);
  });
  writeFileSync(listPath, `${list.join("\n")}\n`);

  run("ffmpeg", [
    "-y",
    "-nostdin",
    "-hide_banner",
    "-loglevel",
    "error",
    "-f",
    "concat",
    "-safe",
    "0",
    "-i",
    listPath,
    "-af",
    "apad",
    "-t",
    String(target),
    "-map_metadata",
    "-1",
    "-ac",
    String(preparation.channels),
    "-ar",
    String(preparation.sampleRateHz),
    "-c:a",
    preparation.encoding,
    "-bitexact",
    output,
  ]);

  return {
    sourceIds: selected,
    transcript: selected.map((sourceID) => sourcesByID.get(sourceID).transcript).join(" "),
  };
}

async function main() {
  const options = parseArguments(process.argv.slice(2));
  const finalOutput = options.output;
  const stagingOutput = `${finalOutput}.preparing-${process.pid}`;
  options.output = stagingOutput;
  rmSync(stagingOutput, { recursive: true, force: true });

  try {
  const manifestBytes = readFileSync(options.manifest);
  const manifest = JSON.parse(manifestBytes.toString("utf8"));
  const dataset = manifest.dataset;
  const preparation = manifest.preparation;
  const datasetID = encodeURIComponent(dataset.repository);
  const revisionURL =
    `https://huggingface.co/api/datasets/${dataset.repository}/revision/${dataset.revision}`;
  const revision = await fetchJSON(revisionURL);
  if (revision.sha !== dataset.revision) {
    throw new Error(`Dataset revision mismatch: expected ${dataset.revision}, got ${revision.sha}`);
  }

  const rawDirectory = join(options.output, ".working/raw");
  const normalizedDirectory = join(options.output, ".working/normalized");
  const audioDirectory = join(options.output, "audio");
  mkdirSync(rawDirectory, { recursive: true });
  mkdirSync(normalizedDirectory, { recursive: true });
  mkdirSync(audioDirectory, { recursive: true });

  const sourcesByID = new Map();
  const normalizedByID = new Map();
  for (const source of manifest.sources) {
    const rowsURL =
      `https://datasets-server.huggingface.co/rows?dataset=${datasetID}` +
      `&config=${encodeURIComponent(source.config)}&split=${encodeURIComponent(source.split)}` +
      `&offset=${source.offset}&length=1`;
    const payload = await fetchJSON(rowsURL);
    const record = payload.rows?.[0];
    if (!record || record.row_idx !== source.offset) {
      throw new Error(`${source.id}: missing pinned source row`);
    }
    if (
      record.row.id !== source.rowID ||
      record.row.speaker_id !== source.speakerID ||
      basename(record.row.file) !== source.path ||
      record.row.text !== source.transcript
    ) {
      throw new Error(`${source.id}: dataset ID, speaker, path, or transcript changed`);
    }
    const audioURL = record.row.audio?.[0]?.src;
    if (!audioURL || !audioURL.includes(`/${dataset.revision}/`)) {
      throw new Error(`${source.id}: audio URL is not pinned to ${dataset.revision}`);
    }

    const bytes = await fetchBytes(audioURL);
    const actualHash = sha256(bytes);
    if (actualHash !== source.sha256) {
      throw new Error(`${source.id}: SHA-256 mismatch; expected ${source.sha256}, got ${actualHash}`);
    }
    const rawPath = join(rawDirectory, `${source.id}${extname(source.path)}`);
    const normalizedPath = join(normalizedDirectory, `${source.id}.wav`);
    writeFileSync(rawPath, bytes);
    normalizeAudio(rawPath, normalizedPath, preparation);
    const actualDuration = ffprobeDuration(rawPath);
    if (Math.abs(actualDuration - source.durationSeconds) > 0.02) {
      throw new Error(
        `${source.id}: duration mismatch; expected ${source.durationSeconds}, got ${actualDuration}`
      );
    }
    sourcesByID.set(source.id, source);
    normalizedByID.set(source.id, normalizedPath);
    process.stdout.write(`verified ${source.id}\n`);
  }

  const preparedCases = [];
  for (const caseDefinition of manifest.cases) {
    const output = join(audioDirectory, `${caseDefinition.id}.wav`);
    let sourceIDs = caseDefinition.sourceIds;
    let transcript = sourceIDs.map((id) => sourcesByID.get(id)?.transcript).join(" ");
    const referencedSourceIDs = [
      ...sourceIDs,
      ...(caseDefinition.repeatSourceIds ?? []),
    ];
    if (referencedSourceIDs.some((id) => !sourcesByID.has(id))) {
      throw new Error(`${caseDefinition.id}: unknown source ID`);
    }

    if (caseDefinition.targetDurationSeconds) {
      const built = buildLongCase(
        caseDefinition,
        sourcesByID,
        normalizedByID,
        output,
        preparation,
        join(options.output, ".working")
      );
      sourceIDs = built.sourceIds;
      transcript = built.transcript;
    } else if (caseDefinition.noise) {
      const input = normalizedByID.get(sourceIDs[0]);
      addDeterministicNoise(input, output, preparation, ffprobeDuration(input));
    } else {
      normalizeAudio(normalizedByID.get(sourceIDs[0]), output, preparation);
    }

    const durationSeconds = ffprobeDuration(output);
    if (
      caseDefinition.targetDurationSeconds &&
      Math.abs(durationSeconds - caseDefinition.targetDurationSeconds) > 0.02
    ) {
      throw new Error(
        `${caseDefinition.id}: generated duration ${durationSeconds} does not match ` +
        `${caseDefinition.targetDurationSeconds}`
      );
    }
    const bytes = readFileSync(output);
    preparedCases.push({
      id: caseDefinition.id,
      scenario: caseDefinition.scenario,
      locale: caseDefinition.locale,
      audioPath: `audio/${caseDefinition.id}.wav`,
      sourceIds: sourceIDs,
      transcript,
      durationSeconds,
      sha256: sha256(bytes),
    });
    process.stdout.write(`prepared ${caseDefinition.id}\n`);
  }

  const preparedManifest = {
    schemaVersion: 1,
    corpusID: manifest.id,
    sourceManifest: options.manifest.slice(repositoryRoot.length + 1),
    sourceManifestSHA256: sha256(manifestBytes),
    dataset,
    preparation,
    acceptance: manifest.acceptance,
    generatedAt: new Date().toISOString(),
    cases: preparedCases,
  };
  writeFileSync(
    join(options.output, "corpus.json"),
    `${JSON.stringify(preparedManifest, null, 2)}\n`
  );
  rmSync(join(options.output, ".working"), { recursive: true, force: true });
  rmSync(finalOutput, { recursive: true, force: true });
  renameSync(stagingOutput, finalOutput);
  process.stdout.write(`ready ${preparedCases.length} cases in ${finalOutput}\n`);
  } catch (error) {
    rmSync(stagingOutput, { recursive: true, force: true });
    throw error;
  }
}

main().catch((error) => {
  process.stderr.write(`prepare-benchmark-corpus: ${error.message}\n`);
  process.exitCode = 1;
});
