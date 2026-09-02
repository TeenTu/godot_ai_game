import { defineConfig } from "@playwright/test";
import "dotenv/config";

export default defineConfig({
  testDir: "./specs",
  timeout: 90_000,
  /* 同一时间只跑一个场景，避免多个浏览器截图互相干扰 */
  workers: 1,
  fullyParallel: false,
  retries: 0, // 重试由 DSL runner 内部按场景控制（视觉断言会重试 N 次）
  reporter: [
    ["list"],
    ["html", { open: "never", outputFolder: "playwright-report" }],
  ],
  use: {
    viewport: { width: 1280, height: 720 },
    screenshot: "only-on-failure",
  },
});
