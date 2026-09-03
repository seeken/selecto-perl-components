#!/usr/bin/env node

import {createHash} from "node:crypto";
import {readFile, writeFile} from "node:fs/promises";
import path from "node:path";
import process from "node:process";

const root = path.resolve(import.meta.dirname, "..");
const sourceRoot = path.join(root, "src", "browser");
const output = path.join(root, "public", "selecto-components", "selecto-components.js");
const publicRoot = path.dirname(output);
const manifestOutput = path.join(publicRoot, "manifest.json");
const perlManifestOutput = path.join(root, "lib", "Selecto", "Components", "AssetManifest.pm");
const modules = [
  "shared.js",
  "shell.js",
  "charts.js",
  "row-dialog.js",
  "grid.js",
  "lifecycle.js",
  "picker.js",
  "filters.js",
  "actions.js",
  "lookups.js",
  "action-results.js",
];

async function build() {
  const parts = await Promise.all(modules.map((name) => readFile(path.join(sourceRoot, name), "utf8")));
  const body = parts.map((part, index) => `  // Source: ${modules[index]}\n${part.trimEnd()}`).join("\n\n");
  const bundle = `(function () {\n  "use strict";\n\n${body}\n})();\n`;
  if (process.argv.includes("--check")) {
    const current = await readFile(output, "utf8").catch(() => "");
    if (current !== bundle) {
      process.stderr.write("Browser bundle is stale; run `npm run build`.\n");
      process.exitCode = 1;
    }
    return bundle;
  }
  await writeFile(output, bundle);
  return bundle;
}

async function assetManifest(bundle) {
  const packageMetadata = JSON.parse(await readFile(path.join(root, "package.json"), "utf8"));
  const assetNames = [
    "selecto-components.css",
    "selecto-components.js",
    "htmx.min.js",
    "hx-ws.min.js",
    "chart.umd.min.js",
  ];
  const assets = {};
  for (const name of assetNames) {
    const content = name === "selecto-components.js"
      ? Buffer.from(bundle)
      : await readFile(path.join(publicRoot, name));
    assets[name] = createHash("sha256").update(content).digest("hex");
  }
  const digest = createHash("sha256")
    .update(JSON.stringify(assets))
    .digest("hex")
    .slice(0, 12);
  return {
    package: packageMetadata.name,
    version: packageMetadata.version,
    revision: `${packageMetadata.version}-${digest}`,
    assets,
  };
}

function perlManifest(manifest) {
  return `package Selecto::Components::AssetManifest;\n\n` +
    `use strict;\nuse warnings;\nuse Exporter qw(import);\n\n` +
    `our @EXPORT_OK = qw(asset_revision);\n` +
    `my $ASSET_REVISION = '${manifest.revision}';\n\n` +
    `sub asset_revision { return $ASSET_REVISION; }\n\n1;\n`;
}

async function writeOrCheck(file, expected, label) {
  if (!process.argv.includes("--check")) {
    await writeFile(file, expected);
    return;
  }
  const current = await readFile(file, "utf8").catch(() => "");
  if (current !== expected) {
    process.stderr.write(`${label} is stale; run \`npm run build\`.\n`);
    process.exitCode = 1;
  }
}

const bundle = await build();
const manifest = await assetManifest(bundle);
await writeOrCheck(manifestOutput, JSON.stringify(manifest, null, 2) + "\n", "Asset manifest");
await writeOrCheck(perlManifestOutput, perlManifest(manifest), "Perl asset manifest");
process.stdout.write(`selecto-components.js ${manifest.revision}\n`);
