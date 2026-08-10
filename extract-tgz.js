#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");
const zlib = require("zlib");

const [archivePath, destinationPath] = process.argv.slice(2);
if (!archivePath || !destinationPath) {
  console.error("Usage: node extract-tgz.js <archive.tgz> <destination>");
  process.exit(2);
}

function readText(buffer, start, length) {
  const end = buffer.indexOf(0, start);
  const actualEnd = end === -1 || end > start + length ? start + length : end;
  return buffer.toString("utf8", start, actualEnd).trim();
}

function readOctal(buffer, start, length) {
  const value = readText(buffer, start, length).replace(/\0/g, "").trim();
  return value ? Number.parseInt(value, 8) : 0;
}

function safeTarget(root, archiveName) {
  const normalized = archiveName.replace(/\\/g, "/");
  const parts = normalized.split("/").filter(Boolean);

  // npm archives always have a top-level "package" directory.
  if (parts[0] === "package") parts.shift();
  if (parts.length === 0) return null;
  if (parts.some((part) => part === "." || part === ".." || part.includes(":"))) {
    throw new Error(`Unsafe archive path: ${archiveName}`);
  }

  const target = path.resolve(root, ...parts);
  const resolvedRoot = path.resolve(root);
  if (target !== resolvedRoot && !target.startsWith(resolvedRoot + path.sep)) {
    throw new Error(`Archive path escapes destination: ${archiveName}`);
  }
  return target;
}

const destination = path.resolve(destinationPath);
fs.mkdirSync(destination, { recursive: true });

const tar = zlib.gunzipSync(fs.readFileSync(archivePath));
let offset = 0;
let extractedFiles = 0;

while (offset + 512 <= tar.length) {
  const header = tar.subarray(offset, offset + 512);
  if (header.every((byte) => byte === 0)) break;

  const name = readText(header, 0, 100);
  const prefix = readText(header, 345, 155);
  const archiveName = prefix ? `${prefix}/${name}` : name;
  const size = readOctal(header, 124, 12);
  const type = String.fromCharCode(header[156] || 48);
  const dataStart = offset + 512;
  const dataEnd = dataStart + size;

  if (dataEnd > tar.length) throw new Error(`Truncated archive entry: ${archiveName}`);

  const target = safeTarget(destination, archiveName);
  if (target) {
    if (type === "5") {
      fs.mkdirSync(target, { recursive: true });
    } else if (type === "0" || type === "\0") {
      fs.mkdirSync(path.dirname(target), { recursive: true });
      fs.writeFileSync(target, tar.subarray(dataStart, dataEnd));
      extractedFiles++;
    }
  }

  offset = dataStart + Math.ceil(size / 512) * 512;
}

if (extractedFiles === 0) throw new Error("Archive contained no regular files.");
console.log(`Extracted ${extractedFiles} files to ${destination}`);

