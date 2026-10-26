import {defineConfig} from "@playwright/test";

if (!process.env.SELECTO_PERL_STACK_POSTGRES_URL) {
  throw new Error("SELECTO_PERL_STACK_POSTGRES_URL must name the owned stack fixture database");
}
const port = Number(process.env.SELECTO_PERL_STACK_HTTP_PORT ?? 4187);
if (!Number.isInteger(port) || port < 1024 || port > 65535) throw new Error("Invalid stack HTTP port");

export default defineConfig({
  testDir: "t/browser-stack",
  workers: 1,
  timeout: 30_000,
  reporter: "list",
  use: {baseURL: `http://127.0.0.1:${port}`, headless: true, trace: "retain-on-failure"},
  webServer: {
    command: `script/with-local-sibling "$(mise which perl)" -Ilib examples/canonical-stack.pl daemon -l http://127.0.0.1:${port}`,
    url: `http://127.0.0.1:${port}/up`,
    reuseExistingServer: false,
    env: {...process.env, MOJO_LOG_LEVEL: "error"},
  },
});
