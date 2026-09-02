import { existsSync, readFileSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { absOutDir } from "./config";
import { renderReport } from "./reporter/html";
import type { ScenarioResult } from "./dsl/types";

/**
 * CLI：把最近一次测试的 results.json 渲染成自包含 HTML 报告。
 * 用法：npm run report
 */
const here = path.dirname(fileURLToPath(import.meta.url));

const resultsFile = path.join(absOutDir(), "results.json");
const outFile = path.join(here, "../report.html");

if (!existsSync(resultsFile)) {
  console.error(`没有找到测试结果：${resultsFile}`);
  console.error("先运行 npm test，再运行 npm run report。");
  process.exit(1);
}

const results = JSON.parse(readFileSync(resultsFile, "utf8")) as ScenarioResult[];
const html = renderReport(results);
writeFileSync(outFile, html, "utf8");

const pass = results.filter((r) => r.ok).length;
console.log(`已生成报告：${outFile}`);
console.log(`通过 ${pass}/${results.length} 个场景`);
