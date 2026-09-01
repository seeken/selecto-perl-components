import {existsSync} from "node:fs";
import {dirname, resolve} from "node:path";
import {spawnSync} from "node:child_process";
import {fileURLToPath} from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const explicitRoot = process.env.SELECTO_LIVE_SELECTO_WEB;
const packageRoots = [
  explicitRoot ? resolve(explicitRoot, "packages/web-assets") : null,
  resolve(repoRoot, "..", "selecto-api-console", "packages/web-assets"),
  resolve(repoRoot, "node_modules", "@selecto", "web-assets")
].filter(Boolean);

const packageRoot = packageRoots.find((candidate) =>
  existsSync(resolve(candidate, "bin/selecto-web-assets.mjs"))
);
if (!packageRoot) {
  throw new Error(
    "Cannot find @selecto/web-assets. Set SELECTO_LIVE_SELECTO_WEB, keep the sibling selecto-api-console checkout, or install @selecto/web-assets from npm."
  );
}

if (existsSync(resolve(packageRoot, "src"))) {
  const build = spawnSync(
    process.execPath,
    [resolve(packageRoot, "scripts/build.mjs")],
    {cwd: packageRoot, stdio: "inherit"}
  );
  if (build.status !== 0) process.exit(build.status ?? 1);
}

const sync = spawnSync(
  process.execPath,
  [resolve(packageRoot, "bin/selecto-web-assets.mjs"), ...process.argv.slice(2)],
  {cwd: repoRoot, stdio: "inherit"}
);
process.exit(sync.status ?? 1);
