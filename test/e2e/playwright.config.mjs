import { defineConfig } from "@playwright/test";

export default defineConfig({
  testDir: ".",
  testMatch: "notify.spec.mjs",
  fullyParallel: false,
  workers: 1,
  timeout: 180_000,
  expect: { timeout: 15_000 },
  outputDir: "test-results",
  reporter: [["line"]],
  use: {
    baseURL: process.env.NOTIFY_E2E_BASE_URL || "http://localhost:18082",
    browserName: "chromium",
    locale: "en-US",
    serviceWorkers: "allow",
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
    video: "retain-on-failure"
  }
});
