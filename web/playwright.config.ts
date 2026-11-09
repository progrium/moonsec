import { defineConfig, devices } from "@playwright/test";

const port = Number(process.env.PORT ?? 8787);

export default defineConfig({
  testDir: "e2e",
  testMatch: "*.spec.ts",
  timeout: 60_000,
  fullyParallel: false,
  workers: 1, // one stub host, whose /state is the latest session's
  reporter: [["list"], ["json", { outputFile: "test-results/report.json" }]],
  use: { baseURL: `http://127.0.0.1:${port}`, trace: "off" },
  webServer: {
    command: `node e2e/stub-host.mjs --port ${port}`,
    url: `http://127.0.0.1:${port}/harness.html`,
    reuseExistingServer: !process.env.CI,
    stdout: "pipe",
  },
  projects: [
    {
      name: "chromium",
      use: {
        ...devices["Desktop Chrome"],
        launchOptions: { args: ["--autoplay-policy=no-user-gesture-required"] },
      },
    },
    {
      name: "firefox",
      use: {
        ...devices["Desktop Firefox"],
        launchOptions: {
          firefoxUserPrefs: { "media.autoplay.default": 0, "media.autoplay.block-webaudio": false },
        },
      },
    },
    { name: "webkit", use: { ...devices["Desktop Safari"] } },
  ],
});
