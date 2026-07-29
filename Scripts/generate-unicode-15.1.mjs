#!/usr/bin/env node
// Generates the pinned Unicode 15.1.0 tables used by TranscriptCorrectionPipeline.
//
// This program deliberately has no package dependencies.  It consumes the exact
// upstream files in UnicodeData/15.1.0 and writes a deterministic Swift source
// file. See docs/unicode-15.1-evidence.md for source URLs, SHA-256 values, the
// Unicode license, and update instructions.

import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";

const root = path.resolve(import.meta.dirname, "..");
const input = path.join(root, "UnicodeData", "15.1.0");
const output = path.join(root, "SaymarkKit", "Sources", "SaymarkKit", "Unicode15_1Generated.swift");

const files = {
  unicodeData: "UnicodeData.txt",
  compositionExclusions: "CompositionExclusions.txt",
  caseFolding: "CaseFolding.txt",
  wordBreak: "WordBreakProperty.txt",
  emoji: "emoji-data.txt",
};

// Pinned Unicode 15.1 Default_Ignorable_Code_Point ranges.  The generator
// embeds these so validation never inherits host ICU's Unicode version.
const defaultIgnorableRanges = [
  [0x00AD, 0x00AD], [0x034F, 0x034F], [0x061C, 0x061C], [0x115F, 0x1160],
  [0x17B4, 0x17B5], [0x180B, 0x180F], [0x200B, 0x200F], [0x202A, 0x202E],
  [0x2060, 0x206F], [0x3164, 0x3164], [0xFE00, 0xFE0F], [0xFEFF, 0xFEFF],
  [0xFFA0, 0xFFA0], [0xFFF0, 0xFFF8], [0x1BCA0, 0x1BCA3], [0x1D173, 0x1D17A],
  [0xE0000, 0xE0FFF],
];

function source(name) { return fs.readFileSync(path.join(input, files[name]), "utf8"); }
function lines(name) { return source(name).split(/\r?\n/); }
function sha(name) { return crypto.createHash("sha256").update(source(name)).digest("hex"); }
function hex(v) { return `0x${v.toString(16).toUpperCase()}`; }
function swiftArray(values, width = 12) {
  if (values.length === 0) return "[]";
  const chunks = [];
  for (let i = 0; i < values.length; i += width) chunks.push(`        ${values.slice(i, i + width).join(", ")}`);
  return `[\n${chunks.join(",\n")}\n    ]`;
}
function parseRangeProperty(line) {
  const body = line.replace(/#.*/, "").trim();
  if (!body) return null;
  const [range, property] = body.split(";").map(x => x.trim());
  const [first, last = first] = range.split("..");
  return [parseInt(first, 16), parseInt(last, 16), property];
}

// UnicodeData decomposition data. The compatibility tag is retained so the
// future NFC-only path cannot accidentally use NFKC mappings.
const decompositions = [];
const ccc = [];
const assigned = [];
let assignedRangeStart = null;
for (const line of lines("unicodeData")) {
  if (!line) continue;
  const fields = line.split(";");
  const scalar = parseInt(fields[0], 16);
  if (fields[1].endsWith(", First>")) assignedRangeStart = scalar;
  else if (fields[1].endsWith(", Last>") && assignedRangeStart !== null) {
    assigned.push([assignedRangeStart, scalar]); assignedRangeStart = null;
  } else { assigned.push([scalar, scalar]); }
  const combining = Number(fields[3]);
  if (combining) ccc.push([scalar, combining]);
  if (!fields[5]) continue;
  const parts = fields[5].split(" ");
  const compatibility = parts[0].startsWith("<");
  const mapping = (compatibility ? parts.slice(1) : parts).map(v => parseInt(v, 16));
  decompositions.push([scalar, compatibility, mapping]);
}
assigned.sort((a, b) => a[0] - b[0]);
const assignedRanges = [];
for (const [first, last] of assigned) {
  const previous = assignedRanges[assignedRanges.length - 1];
  if (previous && first <= previous[1] + 1) previous[1] = Math.max(previous[1], last);
  else assignedRanges.push([first, last]);
}
decompositions.sort((a, b) => a[0] - b[0]);
ccc.sort((a, b) => a[0] - b[0]);

const compositionExclusions = new Set();
for (const line of lines("compositionExclusions")) {
  const parsed = parseRangeProperty(line);
  if (!parsed) continue;
  for (let scalar = parsed[0]; scalar <= parsed[1]; scalar++) compositionExclusions.add(scalar);
}
const compositions = decompositions
  .filter(([scalar, compatibility, mapping]) => !compatibility && mapping.length === 2 && !compositionExclusions.has(scalar))
  .map(([scalar, _, mapping]) => [mapping[0], mapping[1], scalar])
  .sort((a, b) => a[0] - b[0] || a[1] - b[1]);

// Default full case folding: F overrides C where present. Turkic T mappings are
// intentionally excluded, per Unicode default caseless matching.
const folds = new Map();
for (const line of lines("caseFolding")) {
  const body = line.replace(/#.*/, "").trim();
  if (!body) continue;
  const [scalarHex, status, mappingHex] = body.split(";").map(x => x.trim());
  if (status !== "C" && status !== "F") continue;
  const scalar = parseInt(scalarHex, 16);
  const mapping = mappingHex.split(" ").map(v => parseInt(v, 16));
  if (status === "F" || !folds.has(scalar)) folds.set(scalar, mapping);
}
const foldEntries = [...folds.entries()].sort((a, b) => a[0] - b[0]);

const wordBreakNames = [
  "Other", "CR", "LF", "Newline", "Extend", "ZWJ", "Regional_Indicator",
  "Format", "Katakana", "Hebrew_Letter", "ALetter", "Single_Quote",
  "Double_Quote", "MidNumLet", "MidLetter", "MidNum", "Numeric",
  "ExtendNumLet", "WSegSpace", "Extended_Pictographic",
];
const propertyCode = new Map(wordBreakNames.map((name, index) => [name, index]));
const wordRanges = [];
for (const line of lines("wordBreak")) {
  const parsed = parseRangeProperty(line);
  if (!parsed) continue;
  const [first, last, property] = parsed;
  if (!propertyCode.has(property)) throw new Error(`Unexpected Word_Break property: ${property}`);
  wordRanges.push([first, last, propertyCode.get(property)]);
}
for (const line of lines("emoji")) {
  const parsed = parseRangeProperty(line);
  if (!parsed || parsed[2] !== "Extended_Pictographic") continue;
  wordRanges.push([parsed[0], parsed[1], propertyCode.get("Extended_Pictographic")]);
}
wordRanges.sort((a, b) => a[0] - b[0] || a[1] - b[1] || a[2] - b[2]);

function indexedMappings(entries, includeCompatibility = true) {
  const keys = [], offsets = [0], values = [], flags = [];
  for (const entry of entries) {
    const [key, compatibility, mapping] = entry;
    keys.push(key); flags.push(compatibility ? 1 : 0); values.push(...mapping); offsets.push(values.length);
  }
  return { keys, offsets, values, flags };
}
const decomp = indexedMappings(decompositions);
const fold = indexedMappings(foldEntries.map(([key, mapping]) => [key, false, mapping]));

const header = `// This file is generated by Scripts/generate-unicode-15.1.mjs. DO NOT EDIT.\n// Unicode version: 15.1.0\n// Inputs: ${Object.entries(files).map(([key, value]) => `${value} sha256=${sha(key)}`).join("; ")}\n\n`;
const swift = `${header}internal enum Unicode15_1Generated {\n    static let version = "15.1.0"\n\n    static let decompositionKeys: [UInt32] = ${swiftArray(decomp.keys.map(hex))}\n    static let decompositionOffsets: [UInt32] = ${swiftArray(decomp.offsets.map(String))}\n    static let decompositionValues: [UInt32] = ${swiftArray(decomp.values.map(hex))}\n    static let decompositionIsCompatibility: [UInt8] = ${swiftArray(decomp.flags.map(String))}\n\n    static let combiningClassKeys: [UInt32] = ${swiftArray(ccc.map(([scalar]) => hex(scalar)))}\n    static let combiningClassValues: [UInt32] = ${swiftArray(ccc.map(([, value]) => String(value)))}\n\n    // Triples: canonical starter, combining scalar, composed scalar.\n    static let compositionTriples: [UInt32] = ${swiftArray(compositions.flatMap(([a, b, c]) => [hex(a), hex(b), hex(c)]), 9)}\n\n    static let caseFoldKeys: [UInt32] = ${swiftArray(fold.keys.map(hex))}\n    static let caseFoldOffsets: [UInt32] = ${swiftArray(fold.offsets.map(String))}\n    static let caseFoldValues: [UInt32] = ${swiftArray(fold.values.map(hex))}\n\n    // Triples: inclusive lower scalar, inclusive upper scalar, Word_Break code.\n    static let wordBreakRanges: [UInt32] = ${swiftArray(wordRanges.flatMap(([a, b, c]) => [hex(a), hex(b), String(c)]), 9)}\n}\n`;
const generated = swift.replace(
  '    static let version = "15.1.0"\n\n',
  `    static let version = "15.1.0"\n\n    // Inclusive ranges generated from UnicodeData.txt.\n    static let assignedRanges: [UInt32] = ${swiftArray(assignedRanges.flatMap(([a, b]) => [hex(a), hex(b)]))}\n    static let defaultIgnorableRanges: [UInt32] = ${swiftArray(defaultIgnorableRanges.flatMap(([a, b]) => [hex(a), hex(b)]))}\n\n`
);
fs.writeFileSync(output, generated);
console.log(JSON.stringify({ output, bytes: Buffer.byteLength(swift), decompositions: decompositions.length, folds: foldEntries.length, wordBreakRanges: wordRanges.length }, null, 2));
