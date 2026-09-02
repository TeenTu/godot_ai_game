import { mkdirSync, writeFileSync, existsSync, readFileSync } from "node:fs";
import path from "node:path";
import type { Page } from "@playwright/test";
import { config, absOutDir } from "../config";
import { clickAt, moveMouse } from "../driver/canvas";
import { waitForCanvasReady, waitForStable } from "../driver/wait";
import { callTestApi, getGameState } from "../driver/godotHook";
import { getProvider } from "../perception";
import type { ExpectSchema, PerceptionResult } from "../perception/types";
import { assertState } from "./assertions";
import type { Scenario, ScenarioResult, Step, StepResult, Suite } from "./types";

/* ---------- 输出 ---------- */

function sanitize(s: string): string {
  return s.replace(/[^\w\u4e00-\u9fa5-]/g, "_").slice(0, 60);
}

function sceneOutDir(game: string, scenario: string): string {
  const dir = path.join(absOutDir(), "evidence", sanitize(game), sanitize(scenario));
  mkdirSync(dir, { recursive: true });
  return dir;
}

function saveScreenshot(page: Page, dir: string, idx: number, name: string): Promise<string> {
  return page
    .screenshot({ fullPage: false })
    .then((buf) => {
      const file = path.join(dir, `${String(idx).padStart(2, "0")}-${name}.png`);
      writeFileSync(file, buf);
      return file;
    })
    .catch(() => "");
}

/* ---------- 动作表（Given / When） ---------- */

async function execStep(page: Page, step: Step, dir: string, idx: number): Promise<StepResult> {
  const { action, params } = step;
  const p = params ?? {};
  const name = step.note || action;
  const res: StepResult = { name, ok: true };

  try {
    switch (action) {
      case "open_game": {
        const url = buildUrl(page, p);
        await page.goto(url, { waitUntil: "load", timeout: 60_000 });
        await waitForCanvasReady(page);
        break;
      }
      case "reload":
        await page.reload({ waitUntil: "load" });
        await waitForCanvasReady(page);
        break;
      case "wait": {
        const ms = num(p, "ms", 1000);
        await page.waitForTimeout(ms);
        break;
      }
      case "wait_for_stable": {
        const ms = num(p, "ms", 1500);
        const stable = await waitForStable(page, { maxWaitMs: ms });
        if (!stable) res.detail = `画面 ${ms}ms 内未完全静止（可能持续有动画），已继续执行`;
        break;
      }
      case "move_mouse": {
        const pt = point(p);
        await moveMouse(page, pt);
        break;
      }
      case "click": {
        // 默认点 canvas 中心（大多数游戏的操作热区）
        await clickAt(page, point(p, { x: 50, y: 50 }));
        break;
      }
      case "click_at": {
        await clickAt(page, point(p));
        break;
      }
      case "drop_fruit": {
        // suika 组合动作：移动到落点并点击放下
        const pt = point(p, { x: 50, y: 15 });
        await clickAt(page, pt);
        break;
      }
      case "press": {
        const key = String(p.key ?? p.value ?? "Space");
        await page.keyboard.press(key);
        break;
      }
      case "set_seed": {
        const seed = Number(p.value ?? p.seed);
        const ok = await callTestApi(page, "setSeed", seed);
        if (!ok) res.detail = `游戏未暴露 __gameTest.setSeed（没开 ?test=1 钩子），随机种子未固定`;
        break;
      }
      default:
        throw new Error(`未知动作 "${action}"（支持：open_game/reload/wait/wait_for_stable/move_mouse/click/click_at/drop_fruit/press/set_seed）`);
    }
  } catch (e) {
    res.ok = false;
    res.detail = e instanceof Error ? e.message : String(e);
  }
  return res;
}

/* ---------- 断言（Then） ---------- */

async function execVisionAssert(
  page: Page,
  question: string,
  expect: ExpectSchema,
  retry: number,
  dir: string,
  idx: number
): Promise<StepResult> {
  const res: StepResult = { name: `视觉断言：${question}`, ok: false, attempts: 0 };
  const provider = getProvider();
  let lastState: Record<string, unknown> = {};
  let lastFailures: string[] = [];

  for (let attempt = 0; attempt <= retry; attempt++) {
    const shot = await saveScreenshot(page, dir, idx, `vision-a${attempt}`);
    if (shot) res.evidence = path.relative(absOutDir(), shot);

    let p: PerceptionResult;
    try {
      p = await provider.query(shot ? readFileSync(shot) : Buffer.alloc(0), question, expect);
    } catch (e) {
      res.detail = `视觉模型调用失败：${e instanceof Error ? e.message : e}`;
      res.attempts = attempt + 1;
      if (attempt < retry) await page.waitForTimeout(600);
      continue;
    }
    res.raw = p.raw;
    res.state = p.state;
    res.attempts = attempt + 1;
    lastState = p.state;
    lastFailures = assertState(p.state, expect);
    if (lastFailures.length === 0) {
      res.ok = true;
      return res;
    }
    if (attempt < retry) await page.waitForTimeout(600);
  }
  res.detail = `视觉断言失败：${lastFailures.map((f) => f.message).join("；")}`;
  res.state = lastState;
  return res;
}

async function execHookAssert(page: Page, expect: ExpectSchema): Promise<StepResult> {
  const res: StepResult = { name: "数值断言（__gameState）", ok: false };
  // 轮询等待钩子挂载：线上地址 wasm 下载慢，一次性读取会在游戏未就绪时误报。
  let state: Record<string, unknown> | null = null;
  for (let waited = 0; waited <= 10000; waited += 500) {
    state = await getGameState(page);
    if (state) break;
    await page.waitForTimeout(500);
  }
  if (!state) {
    res.detail =
      "游戏未暴露 window.__gameState —— 需要游戏加测试钩子（URL 带 ?test=1）。当前只能跑纯视觉断言。（已轮询等待 10s）";
    return res;
  }
  res.state = state;
  const failures = assertState(state, expect);
  if (failures.length === 0) {
    res.ok = true;
  } else {
    res.detail = `数值断言失败：${failures.map((f) => f.message).join("；")}`;
  }
  return res;
}

/* ---------- 场景执行 ---------- */

export async function runScenario(
  page: Page,
  suite: Suite,
  scenario: Scenario,
  opts?: { baseUrl?: string }
): Promise<ScenarioResult> {
  const start = Date.now();
  const baseUrl = opts?.baseUrl ?? suite.base_url;
  const dir = sceneOutDir(suite.game, scenario.name);
  const retry = scenario.retry ?? config.visionRetry;
  const steps: StepResult[] = [];
  const failures: string[] = [];
  let ok = true;

  // 把 base_url 挂到 page 上，供 open_game 使用
  (page as Page & { __baseUrl?: string }).__baseUrl = baseUrl;

  const allSteps: Step[] = [...scenario.given, ...scenario.when];
  let idx = 0;
  for (const step of allSteps) {
    const r = await execStep(page, step, dir, idx++);
    steps.push(r);
    if (!r.ok) {
      ok = false;
      failures.push(`${r.name}: ${r.detail}`);
      break; // 前置步骤失败，中断场景
    }
  }

  if (ok) {
    for (const a of scenario.then) {
      let r: StepResult;
      if (a.kind === "vision") {
        r = await execVisionAssert(page, a.question, a.expect, retry, dir, idx++);
      } else if (a.kind === "hook") {
        r = await execHookAssert(page, a.expect);
      } else {
        await page.waitForTimeout(a.ms);
        r = { name: `等待 ${a.ms}ms`, ok: true };
      }
      steps.push(r);
      if (!r.ok) {
        ok = false;
        failures.push(r.detail ?? r.name);
      }
    }
  }

  const result: ScenarioResult = {
    game: suite.game,
    scenario: scenario.name,
    ok,
    steps,
    failures,
    durationMs: Date.now() - start,
  };

  appendResult(result);
  return result;
}

/* ---------- 结果归档 ---------- */

const resultsFile = () => path.join(absOutDir(), "results.json");

function appendResult(result: ScenarioResult) {
  mkdirSync(absOutDir(), { recursive: true });
  const prev = existsSync(resultsFile())
    ? (JSON.parse(readFileSync(resultsFile(), "utf8")) as ScenarioResult[])
    : [];
  writeFileSync(resultsFile(), JSON.stringify([...prev, result], null, 2));
}

/* ---------- 工具 ---------- */

function num(p: Record<string, unknown>, key: string, fallback: number): number {
  const v = p[key] ?? p.value;
  const n = Number(v);
  return Number.isFinite(n) ? n : fallback;
}

/** 解析 (x, y)，支持 {x, y} 或 {value: [x, y]}，缺省用 fallback */
function point(p: Record<string, unknown>, fallback = { x: 50, y: 50 }) {
  if (Array.isArray(p.value) && p.value.length >= 2) {
    return { x: Number(p.value[0]), y: Number(p.value[1]) };
  }
  const x = p.x !== undefined ? Number(p.x) : fallback.x;
  const y = p.y !== undefined ? Number(p.y) : fallback.y;
  return { x, y };
}

/** 组装 URL：base + query params */
function buildUrl(page: Page, p: Record<string, unknown>): string {
  const base = (page as Page & { __baseUrl?: string }).__baseUrl ?? "";
  const query = (p.params ?? {}) as Record<string, unknown>;
  const keys = Object.keys(query);
  if (keys.length === 0) return base;
  const url = new URL(base);
  for (const k of keys) url.searchParams.set(k, String(query[k]));
  return url.toString();
}
