import { existsSync, readFileSync } from "node:fs";
import path from "node:path";
import { absOutDir } from "../config";
import type { ScenarioResult } from "../dsl/types";

/**
 * 自包含 HTML 报告 —— 截图以 base64 内嵌，单个文件可归档、可分享。
 * 运行：npm run report（读取 test-results/vision/results.json，输出 report.html）
 */

export function renderReport(results: ScenarioResult[]): string {
  const rows = results
    .map((r, i) => renderScenario(r, i))
    .join("\n");
  const passed = results.filter((r) => r.ok).length;
  const total = results.length;

  return `<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Vision E2E 报告</title>
<style>
  body { margin: 0; padding: 24px; font-family: system-ui, sans-serif; background: #f5f6f8; color: #222; }
  h1 { font-size: 20px; margin: 0 0 4px; }
  .summary { color: #667; margin-bottom: 20px; font-size: 13px; }
  .scenario { background: #fff; border: 1px solid #e3e6ea; border-radius: 12px; padding: 16px 18px; margin-bottom: 16px; }
  .scenario.pass { border-left: 4px solid #3b9a3b; }
  .scenario.fail { border-left: 4px solid #d64545; }
  .head { display: flex; align-items: center; gap: 10px; margin-bottom: 10px; }
  .head .badge { font-size: 12px; padding: 2px 10px; border-radius: 999px; color: #fff; }
  .pass .badge { background: #3b9a3b; }
  .fail .badge { background: #d64545; }
  .head .time { color: #99a; font-size: 12px; margin-left: auto; }
  .step { font-size: 13px; padding: 5px 8px; border-radius: 6px; margin: 3px 0; }
  .step.ok { background: #f0f8f0; }
  .step.bad { background: #fdf0f0; color: #a33; }
  .step .label { font-weight: 600; }
  .step .detail { color: #667; margin-top: 2px; white-space: pre-wrap; }
  .evidence { display: flex; flex-wrap: wrap; gap: 10px; margin-top: 8px; }
  .evidence figure { margin: 0; }
  .evidence img { max-width: 320px; border: 1px solid #e3e6ea; border-radius: 8px; display: block; }
  .evidence figcaption { font-size: 11px; color: #99a; margin-top: 4px; }
  code { background: #f1f2f4; padding: 1px 5px; border-radius: 4px; font-size: 12px; }
</style>
</head>
<body>
<h1>Vision E2E 测试报告</h1>
<p class="summary">通过 ${passed} / ${total} 个场景 · 生成于 ${new Date().toLocaleString()}</p>
${rows}
</body>
</html>`;
}

function renderScenario(r: ScenarioResult, i: number): string {
  const cls = r.ok ? "pass" : "fail";
  const steps = r.steps.map(renderStep).join("\n");
  const fails = r.failures
    .map((f) => `<div class="detail">- ${escapeHtml(f)}</div>`)
    .join("");

  return `<section class="scenario ${cls}">
  <div class="head">
    <span class="badge">${r.ok ? "PASS" : "FAIL"}</span>
    <strong>${escapeHtml(r.game)} · ${escapeHtml(r.scenario)}</strong>
    <span class="time">${r.durationMs}ms</span>
  </div>
  ${fails}
  ${steps}
</section>`;
}

function renderStep(s: ScenarioResult["steps"][number], idx: number): string {
  const cls = s.ok ? "ok" : "bad";
  const detail = s.detail ? `<div class="detail">${escapeHtml(s.detail)}</div>` : "";
  const evidence = s.evidence
    ? `<div class="evidence">${renderEvidence(s.evidence)}</div>`
    : "";
  const attempts = s.attempts && s.attempts > 1 ? `（重试 ${s.attempts - 1} 次）` : "";
  return `<div class="step ${cls}">
  <span class="label">${idx + 1}. ${escapeHtml(s.name)}</span>${attempts}
  ${detail}${evidence}
</div>`;
}

function renderEvidence(relPath: string): string {
  const abs = path.join(absOutDir(), relPath);
  if (!existsSync(abs)) return "";
  const b64 = readFileSync(abs).toString("base64");
  return `<figure><img src="data:image/png;base64,${b64}" alt="截图证据"><figcaption>${escapeHtml(relPath)}</figcaption></figure>`;
}

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}
