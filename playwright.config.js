import {defineConfig} from "@playwright/test";

export default defineConfig({
  testDir: "t/browser",
  fullyParallel: true,
  // Sandboxes share their host CPUs; do not launch dozens of Chromium workers.
  workers: process.env.PLAYWRIGHT_WORKERS ? Number(process.env.PLAYWRIGHT_WORKERS) : 4,
  reporter: "line",
  use: {browserName: "chromium", headless: true},
});
