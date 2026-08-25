import { defineConfig } from "@playwright/test";

const browserName = process.env.NOTIFY_E2E_BROWSER || "chromium";
const device = process.env.NOTIFY_E2E_DEVICE || "desktop";
if (!new Set(["chromium", "firefox", "webkit"]).has(browserName)) {
  throw new Error(`Unsupported NOTIFY_E2E_BROWSER: ${browserName}`);
}
if (!new Set(["desktop", "mobile"]).has(device)) {
  throw new Error(`Unsupported NOTIFY_E2E_DEVICE: ${device}`);
}

export default defineConfig({
  testDir: ".",
  testMatch: "notify.spec.mjs",
  fullyParallel: false,
  workers: 1,
  timeout: 180_000,
  expect: { timeout: 15_000 },
  outputDir: "test-results",
  reporter: [["line"]],
  projects: [
    {
      name: `${browserName}-${device}`,
      use: {
        browserName,
        launchOptions: browserName === "chromium"
          ? { args: ["--ignore-certificate-errors"] }
          : undefined,
        viewport: device === "mobile"
          ? { width: 390, height: 844 }
          : { width: 1280, height: 900 },
      },
    },
  ],
  use: {
    baseURL: process.env.NOTIFY_E2E_BASE_URL || "https://localhost:18443",
    ignoreHTTPSErrors: true,
    locale: "en-US",
    serviceWorkers: "allow",
    trace: "retain-on-failure",
    screenshot: "only-on-failure",
    video: "retain-on-failure"
  }
});
