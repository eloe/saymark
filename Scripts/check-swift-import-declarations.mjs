#!/usr/bin/env node
// Fail-closed lexical import checker for the isolated LiveInsertionPolicy
// target. Unlike a text regex, this skips Swift comments, string literals,
// raw/multiline strings, regex literals, and escaped identifiers. Unlike a
// parser dump, it deliberately examines inactive #if branches too.

import fs from "node:fs";
import path from "node:path";

const targets = process.argv.slice(2);

if (targets.length === 0) {
  process.stderr.write("usage: check-swift-import-declarations.mjs <swift-file-or-directory>...\n");
  process.exit(2);
}

function isIdentifierCharacter(character) {
  if (character === undefined) return false;
  const code = character.codePointAt(0);
  return code >= 0x80 || /[A-Za-z0-9_]/.test(character);
}

function lineAndColumn(source, offset) {
  const prefix = source.slice(0, offset);
  const line = prefix.split("\n").length;
  const finalNewline = prefix.lastIndexOf("\n");
  return { line, column: offset - finalNewline };
}

function skipLineComment(source, offset) {
  const newline = source.indexOf("\n", offset + 2);
  return newline === -1 ? source.length : newline + 1;
}

function skipBlockComment(source, offset) {
  let depth = 1;
  let cursor = offset + 2;
  while (cursor < source.length && depth > 0) {
    if (source.startsWith("/*", cursor)) {
      depth += 1;
      cursor += 2;
    } else if (source.startsWith("*/", cursor)) {
      depth -= 1;
      cursor += 2;
    } else {
      cursor += 1;
    }
  }
  return cursor;
}

function skipTrivia(source, offset) {
  let cursor = offset;
  while (cursor < source.length) {
    if (/\s/.test(source[cursor])) {
      cursor += 1;
    } else if (source.startsWith("//", cursor)) {
      cursor = skipLineComment(source, cursor);
    } else if (source.startsWith("/*", cursor)) {
      cursor = skipBlockComment(source, cursor);
    } else {
      break;
    }
  }
  return cursor;
}

function hashCountBeforeDelimiter(source, offset, delimiter) {
  let cursor = offset;
  while (source[cursor] === "#") cursor += 1;
  return source[cursor] === delimiter ? cursor - offset : -1;
}

function skipString(source, offset, hashCount) {
  const quoteOffset = offset + hashCount;
  const multiline = source.startsWith('"""', quoteOffset);
  let cursor = quoteOffset + (multiline ? 3 : 1);
  const terminator = multiline ? '"""' : '"';
  const rawSuffix = "#".repeat(hashCount);

  while (cursor < source.length) {
    if (source.startsWith(terminator, cursor) && source.startsWith(rawSuffix, cursor + terminator.length)) {
      return cursor + terminator.length + hashCount;
    }
    cursor += hashCount === 0 && source[cursor] === "\\" ? 2 : 1;
  }
  return source.length;
}

function couldStartRegex(previousToken) {
  if (previousToken === undefined) return true;
  return ["=", "(", "[", "{", ",", ":", ";", "?", "!", "return", "case", "=>"].includes(previousToken);
}

function skipRegex(source, offset, hashCount) {
  const slashOffset = offset + hashCount;
  let cursor = slashOffset + 1;
  let characterClass = false;
  const suffix = "#".repeat(hashCount);

  while (cursor < source.length) {
    if (source[cursor] === "\\") {
      cursor += 2;
      continue;
    }
    if (source[cursor] === "[") characterClass = true;
    if (source[cursor] === "]") characterClass = false;
    if (!characterClass && source[cursor] === "/" && source.startsWith(suffix, cursor + 1)) {
      return cursor + 1 + hashCount;
    }
    if (source[cursor] === "\n") return offset;
    cursor += 1;
  }
  return offset;
}

function importOffsets(source) {
  const offsets = [];
  let cursor = 0;
  let previousToken;

  while (cursor < source.length) {
    const character = source[cursor];
    if (/\s/.test(character)) {
      cursor += 1;
      continue;
    }
    if (source.startsWith("//", cursor)) {
      cursor = skipLineComment(source, cursor);
      continue;
    }
    if (source.startsWith("/*", cursor)) {
      cursor = skipBlockComment(source, cursor);
      continue;
    }
    if (character === "`") {
      const close = source.indexOf("`", cursor + 1);
      cursor = close === -1 ? source.length : close + 1;
      previousToken = "identifier";
      continue;
    }

    const stringHashes = character === "#" ? hashCountBeforeDelimiter(source, cursor, '"') : -1;
    if (character === '"' || stringHashes >= 0) {
      cursor = skipString(source, cursor, stringHashes >= 0 ? stringHashes : 0);
      previousToken = "literal";
      continue;
    }

    const rawRegexHashes = character === "#" ? hashCountBeforeDelimiter(source, cursor, "/") : -1;
    const regexHashes = rawRegexHashes >= 0 ? rawRegexHashes : (character === "/" ? 0 : -1);
    if (regexHashes >= 0 && couldStartRegex(previousToken)) {
      const afterRegex = skipRegex(source, cursor, regexHashes);
      if (afterRegex !== cursor) {
        cursor = afterRegex;
        previousToken = "literal";
        continue;
      }
    }

    if (/[A-Za-z_]/.test(character)) {
      const start = cursor;
      cursor += 1;
      while (isIdentifierCharacter(source[cursor])) cursor += 1;
      const token = source.slice(start, cursor);
      if (token === "import") {
        const next = skipTrivia(source, cursor);
        if (/[A-Za-z_]/.test(source[next]) || source[next]?.codePointAt(0) >= 0x80) {
          offsets.push(start);
        }
      }
      previousToken = token;
      continue;
    }

    previousToken = source.startsWith("=>", cursor) ? "=>" : character;
    cursor += previousToken.length;
  }

  return offsets;
}

function swiftFiles(target) {
  const entry = fs.statSync(target);
  if (entry.isFile()) return target.endsWith(".swift") ? [target] : [];
  return fs.readdirSync(target, { recursive: true })
    .map((relative) => path.join(target, relative))
    .filter((candidate) => candidate.endsWith(".swift") && fs.statSync(candidate).isFile());
}

let foundImport = false;
for (const target of targets) {
  for (const file of swiftFiles(target)) {
    const source = fs.readFileSync(file, "utf8");
    for (const offset of importOffsets(source)) {
      const location = lineAndColumn(source, offset);
      process.stderr.write(file + ":" + location.line + ":" + location.column + ": explicit Swift import declaration\n");
      foundImport = true;
    }
  }
}

process.exit(foundImport ? 1 : 0);
