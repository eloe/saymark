#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";

const [lockfilePath = "Tuist/Package.resolved", outputPath] = process.argv.slice(2);

if (!outputPath) {
  console.error(
    "usage: generate-dependency-snapshot.mjs Tuist/Package.resolved output.json"
  );
  process.exit(2);
}

const requiredEnvironment = [
  "GITHUB_SHA",
  "GITHUB_REF",
  "GITHUB_RUN_ID",
  "GITHUB_REPOSITORY",
];
for (const name of requiredEnvironment) {
  if (!process.env[name]) {
    console.error(`Missing required environment variable: ${name}`);
    process.exit(2);
  }
}

const lockfile = JSON.parse(fs.readFileSync(lockfilePath, "utf8"));
if (!Array.isArray(lockfile.pins) || lockfile.pins.length === 0) {
  throw new Error(`${lockfilePath} contains no resolved package pins`);
}

function swiftPackageURL(pin) {
  const version = pin.state?.version;
  if (!version) {
    throw new Error(`${pin.identity} must resolve to a version for Dependabot matching`);
  }

  const source = new URL(pin.location);
  const components = source.pathname
    .replace(/^\/|\/$/g, "")
    .replace(/\.git$/i, "")
    .split("/");
  if (components.length < 2) {
    throw new Error(`${pin.identity} has an unsupported source URL: ${pin.location}`);
  }

  const name = components.pop();
  const namespace = `${source.hostname}/${components.join("/")}`;
  return `pkg:swift/${namespace}/${name}@${version}`;
}

const resolved = Object.fromEntries(
  lockfile.pins
    .map((pin) => [
      pin.identity,
      {
        package_url: swiftPackageURL(pin),
        relationship: "direct",
        scope: "runtime",
      },
    ])
    .sort(([left], [right]) => left.localeCompare(right))
);

const serverURL = process.env.GITHUB_SERVER_URL ?? "https://github.com";
const runURL = `${serverURL}/${process.env.GITHUB_REPOSITORY}/actions/runs/${process.env.GITHUB_RUN_ID}`;
const snapshot = {
  version: 0,
  sha: process.env.GITHUB_SHA,
  ref: process.env.GITHUB_REF,
  job: {
    correlator: `${process.env.GITHUB_WORKFLOW ?? "Dependency graph"}_${
      process.env.GITHUB_JOB ?? "submit-tuist-dependencies"
    }`,
    id: process.env.GITHUB_RUN_ID,
    html_url: runURL,
  },
  detector: {
    name: "saymark-swift-lockfile",
    version: "1.0.0",
    url: `${serverURL}/${process.env.GITHUB_REPOSITORY}`,
  },
  scanned: new Date().toISOString(),
  manifests: {
    [lockfilePath]: {
      name: path.basename(lockfilePath),
      file: { source_location: lockfilePath },
      resolved,
    },
  },
};

fs.writeFileSync(outputPath, `${JSON.stringify(snapshot, null, 2)}\n`);
console.log(
  `Generated dependency snapshot for ${Object.keys(resolved).length} resolved Swift packages.`
);
