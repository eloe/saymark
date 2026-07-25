#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import process from "node:process";

const root = path.resolve(import.meta.dirname, "..");
const projectPath = path.join(root, "Project.swift");
const packagePath = path.join(root, "Tuist", "Package.swift");
const resolvedPath = path.join(root, "Tuist", "Package.resolved");

const projectSource = fs.readFileSync(projectPath, "utf8");
const packageSource = fs.readFileSync(packagePath, "utf8");
const resolved = JSON.parse(fs.readFileSync(resolvedPath, "utf8"));

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

const project = projectDependencies(projectSource);
const manifest = packageDependencies(packageSource);
const locked = new Map(
  resolved.pins.map((pin) => [
    normalizeURL(pin.location),
    pin.state.version ?? pin.state.revision,
  ])
);

const failures = [];
for (const [url, version] of project) {
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
  if (!project.has(url)) {
    failures.push(`Tuist/Package.swift contains app dependency ${url} that Project.swift does not.`);
  }
}

if (project.size === 0) {
  failures.push("No exact remote app dependencies were found in Project.swift.");
}

if (failures.length > 0) {
  console.error(failures.join("\n"));
  process.exit(1);
}

console.log(`App dependency manifests agree (${project.size} exact packages).`);
