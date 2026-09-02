import { test, expect } from "@playwright/test";
import { loadAllSuites } from "../src/dsl/loader";
import { runScenario } from "../src/dsl/runner";

/**
 * 入口：把 scenarios/<game>/*.yml 里的每个场景动态注册为一个 Playwright test。
 * 报告、过滤（-g 场景名）、单跑等 Playwright 能力全部白拿。
 */
const suites = loadAllSuites();

for (const suite of suites) {
  test.describe(`[${suite.game}]`, () => {
    for (const scenario of suite.scenarios) {
      test(scenario.name, async ({ page }) => {
        const result = await runScenario(page, suite, scenario);
        const summary = result.failures.join("\n");
        expect(result.ok, `${summary || "场景失败"}\n完整记录见 test-results/vision/`).toBe(true);
      });
    }
  });
}
