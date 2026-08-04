#!/usr/bin/env node

import fs from "node:fs";
import crypto from "node:crypto";
import path from "node:path";
import process from "node:process";

const root = path.resolve(import.meta.dirname, "..");
const projectPath = path.join(root, "Project.swift");
const packagePath = path.join(root, "Tuist", "Package.swift");
const resolvedPath = path.join(root, "Tuist", "Package.resolved");
const vendorMetadataPath = path.join(root, "Vendor", "KeyboardShortcuts", "UPSTREAM.json");
const vendorManifestPath = path.join(root, "Vendor", "KeyboardShortcuts", "UPSTREAM_RUNTIME.sha256");

const projectSource = fs.readFileSync(projectPath, "utf8");
const packageSource = fs.readFileSync(packagePath, "utf8");
const resolved = JSON.parse(fs.readFileSync(resolvedPath, "utf8"));
const vendorMetadata = JSON.parse(fs.readFileSync(vendorMetadataPath, "utf8"));
const vendorManifest = new Map(
  fs
    .readFileSync(vendorManifestPath, "utf8")
    .trim()
    .split("\n")
    .map((line) => {
      const match = line.match(/^([0-9a-f]{64})  (.+)$/);
      if (!match) {
        throw new Error(`Invalid vendored upstream manifest line: ${line}`);
      }
      return [match[2], match[1]];
    })
);

function projectDependencies(source) {
  const dependencies = new Map();
  const pattern =
    /\.remote\(\s*url:\s*"([^"]+)"\s*,\s*requirement:\s*\.exact\("([^"]+)"\)\s*\)/gs;

  for (const match of source.matchAll(pattern)) {
    dependencies.set(normalizeURL(match[1]), match[2]);
  }
  return dependencies;
}

function packageDependencies(source) {
  const dependencies = new Map();
  const pattern =
    /\.package\(\s*url:\s*"([^"]+)"\s*,\s*exact:\s*"([^"]+)"\s*\)/gs;

  for (const match of source.matchAll(pattern)) {
    dependencies.set(normalizeURL(match[1]), match[2]);
  }
  return dependencies;
}

function normalizeURL(url) {
  return url.replace(/\.git$/, "").replace(/\/$/, "").toLowerCase();
}

function runtimeFiles(directory) {
  const files = [];

  function collect(current, relative = "") {
    for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
      const entryRelative = path.posix.join(relative, entry.name);
      const entryPath = path.join(current, entry.name);
      if (entry.isDirectory()) {
        collect(entryPath, entryRelative);
      } else if (entry.isFile()) {
        files.push(entryRelative);
      }
    }
  }

  collect(path.join(directory, "Sources"), "Sources");
  files.push("Package.swift", "license");
  files.sort();
  return files;
}

function fileSHA256(file) {
  return crypto.createHash("sha256").update(fs.readFileSync(file)).digest("hex");
}

const project = projectDependencies(projectSource);
const expected = new Map(project);
expected.set(normalizeURL(vendorMetadata.url), vendorMetadata.version);
const manifest = packageDependencies(packageSource);
const locked = new Map(
  resolved.pins.map((pin) => [
    normalizeURL(pin.location),
    pin.state.version ?? pin.state.revision,
  ])
);
const vendorURL = normalizeURL(vendorMetadata.url);
const vendorPin = resolved.pins.find((pin) => normalizeURL(pin.location) === vendorURL);
const vendorPath = path.join(root, vendorMetadata.localPath);

const failures = [];
for (const [url, version] of expected) {
  if (manifest.get(url) !== version) {
    failures.push(
      `Tuist/Package.swift must mirror ${url} at ${version} (found ${manifest.get(url) ?? "missing"}).`
    );
  }
  if (locked.get(url) !== version) {
    failures.push(
      `Tuist/Package.resolved must lock ${url} at ${version} (found ${locked.get(url) ?? "missing"}).`
    );
  }
}

for (const url of manifest.keys()) {
  if (!expected.has(url)) {
    failures.push(`Tuist/Package.swift contains app dependency ${url} that Project.swift does not.`);
  }
}

if (!projectSource.includes(`.local(path: "${vendorMetadata.localPath}")`)) {
  failures.push(`Project.swift must use the vendored ${vendorMetadata.name} package.`);
}

if (vendorPin?.state.revision !== vendorMetadata.revision) {
  failures.push(
    `Tuist/Package.resolved must lock ${vendorMetadata.name} at revision ${vendorMetadata.revision} ` +
      `(found ${vendorPin?.state.revision ?? "missing"}).`
  );
}

const runtimeFilesFound = runtimeFiles(vendorPath);
const patchedFiles = new Map(
  vendorMetadata.patchedFiles.map((patch) => [patch.path, patch])
);
if (runtimeFilesFound.join("\n") !== [...vendorManifest.keys()].sort().join("\n")) {
  failures.push(`${vendorMetadata.name} runtime file inventory differs from UPSTREAM_RUNTIME.sha256.`);
}
for (const file of runtimeFilesFound) {
  const upstreamSHA256 = vendorManifest.get(file);
  const patch = patchedFiles.get(file);
  const expectedSHA256 = patch?.vendoredSHA256 ?? upstreamSHA256;
  const actualSHA256 = fileSHA256(path.join(vendorPath, file));
  if (patch && patch.upstreamSHA256 !== upstreamSHA256) {
    failures.push(`${vendorMetadata.name} patch allowlist has the wrong upstream digest for ${file}.`);
  }
  if (actualSHA256 !== expectedSHA256) {
    failures.push(`${vendorMetadata.name} vendored file ${file} is not upstream or an allowlisted patch.`);
  }
}
for (const file of patchedFiles.keys()) {
  if (!vendorManifest.has(file)) {
    failures.push(`${vendorMetadata.name} patch allowlist contains unknown upstream file ${file}.`);
  }
}

if (project.size === 0) {
  failures.push("No exact remote app dependencies were found in Project.swift.");
}

if (failures.length > 0) {
  console.error(failures.join("\n"));
  process.exit(1);
}

console.log(
  `App dependency manifests agree (${project.size} remote and 1 provenance-locked vendored package).`
);
