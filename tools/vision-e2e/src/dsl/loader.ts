import { readFileSync, readdirSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import YAML from "yaml";
import { config } from "../config";
import type { ExpectSchema } from "../perception/types";
import type { AssertStep, Scenario, Step, Suite } from "./types";

const here = path.dirname(fileURLToPath(import.meta.url));

/** 场景根目录：tools/vision-e2e/scenarios/ */
export function scenariosRoot(): string {
  return path.resolve(here, "../../scenarios");
}

/**
 * 把一段 YAML 里"动作列表"解析为 Step[]。
 * 兼容两种写法：
 *   - 字符串列表：["open_game", "click"]
 *   - 对象列表：[{ open_game: {seed: 42} }, { click: null }]
 *   - 混合
 */
function parseSteps(raw: unknown): Step[] {
  if (!Array.isArray(raw)) return [];
  const steps: Step[] = [];
  for (const item of raw) {
    if (typeof item === "string") {
      steps.push({ action: item });
    } else if (item && typeof item === "object") {
      const [action, params] = Object.entries(item as Record<string, unknown>)[0];
      steps.push({
        action,
        params:
          params && typeof params === "object" && !Array.isArray(params)
            ? (params as Record<string, unknown>)
            : { value: params },
      });
    } else {
      throw new Error(`无法解析的步骤项：${JSON.stringify(item)}`);
    }
  }
  return steps;
}

/** 解析 Then 段的断言步骤 */
function parseThen(raw: unknown): AssertStep[] {
  if (!Array.isArray(raw)) return [];
  const out: AssertStep[] = [];
  for (const item of raw) {
    if (typeof item === "string") {
      if (item === "wait") continue; // 无参 wait 忽略
      throw new Error(`Then 段不能使用裸动作："${item}"，请用 wait: {ms: n}`);
    }
    if (!item || typeof item !== "object") continue;
    const entry = item as Record<string, unknown>;
    if ("vision_assert" in entry) {
      const a = entry.vision_assert as Record<string, unknown>;
      out.push({
        kind: "vision",
        question: String(a.question ?? ""),
        expect: (a.expect ?? {}) as ExpectSchema,
        note: typeof a.note === "string" ? a.note : undefined,
      });
    } else if ("hook_assert" in entry) {
      const a = entry.hook_assert as Record<string, unknown>;
      out.push({
        kind: "hook",
        expect: (a.expect ?? {}) as ExpectSchema,
        note: typeof a.note === "string" ? a.note : undefined,
      });
    } else if ("wait" in entry) {
      const ms = Number(entry.wait ?? 0);
      if (Number.isFinite(ms)) out.push({ kind: "wait", ms });
    } else {
      throw new Error(`Then 段不认识 "${Object.keys(entry)[0]}"，支持 vision_assert / hook_assert / wait`);
    }
  }
  return out;
}

/** 加载单个场景文件，做基础结构校验 */
export function loadSuite(file: string): Suite {
  const text = readFileSync(file, "utf8");
  const doc = YAML.parse(text) as Partial<Suite> & { scenarios?: unknown[] };

  if (!doc.game || typeof doc.game !== "string") {
    throw new Error(`${file}: 缺少 game 字段`);
  }
  if (!Array.isArray(doc.scenarios)) {
    throw new Error(`${file}: 缺少 scenarios 列表`);
  }

  const scenarios: Scenario[] = doc.scenarios.map((sRaw) => {
    const s = sRaw as Record<string, unknown>;
    if (!s.name) throw new Error(`${file}: 场景缺少 name`);
    return {
      name: String(s.name),
      given: parseSteps(s.given),
      when: parseSteps(s.when),
      then: parseThen(s.then),
      retry: typeof s.retry === "number" ? s.retry : undefined,
    };
  });

  return {
    game: doc.game,
    base_url: doc.base_url ?? "",
    viewport: doc.viewport,
    scenarios,
  };
}

/** 加载 scenarios/ 下所有 <game>/*.yml（仅一层：<game>/<file>.yml） */
export function loadAllSuites(): Suite[] {
  const root = scenariosRoot();
  const suites: Suite[] = [];
  for (const gameDir of readdirSync(root, { withFileTypes: true })) {
    if (!gameDir.isDirectory()) continue;
    const dir = path.join(root, gameDir.name);
    for (const f of readdirSync(dir)) {
      if (!/\.ya?ml$/i.test(f)) continue;
      const suite = loadSuite(path.join(dir, f));
      suites.push({
        ...suite,
        base_url: resolveBaseUrl(suite.base_url),
      });
    }
  }
  return suites;
}

/**
 * 解析 base_url 优先级：环境变量 BASE_URL > YAML base_url。
 *  BASE_URL 是完整地址（http/https）→ 直接使用
 *  BASE_URL 是 origin（如 http://localhost:8123）→ 拼上 YAML 里的路径
 *  无 BASE_URL → 用 YAML 原值（此时 YAML 应写完整地址）
 */
function resolveBaseUrl(yamlUrl: string): string {
  const override = config.baseUrlOverride;
  if (!override) return yamlUrl;
  if (/^https?:\/\//i.test(override)) return override;
  const origin = override.replace(/\/+$/, "");
  return yamlUrl ? new URL(yamlUrl, origin + "/").href : origin + "/";
}
