import {defineConfig} from "@playwright/test";

export default defineConfig({
  testDir: "t/browser",
  fullyParallel: true,
  reporter: "line",
  use: {browserName: "chromium", headless: true},
});
