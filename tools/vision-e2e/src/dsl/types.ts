import type { ExpectSchema } from "../perception/types";

/** 一个 YAML 场景文件（suite） */
export interface Suite {
  /** 游戏名，用于分组与报告 */
  game: string;
  /** 被测地址（可被环境变量 BASE_URL 覆盖） */
  base_url: string;
  /** 可选视口 */
  viewport?: { width: number; height: number };
  /** 场景列表 */
  scenarios: Scenario[];
}

export interface Scenario {
  name: string;
  /** 前置步骤（Given） */
  given: Step[];
  /** 触发步骤（When） */
  when: Step[];
  /** 断言步骤（Then） */
  then: AssertStep[];
  /** 可选：视觉断言失败重试次数（覆盖全局 VISION_RETRY） */
  retry?: number;
}

/** 普通执行步骤 */
export interface Step {
  /** 动作名：open_game / reload / wait / wait_for_stable / move_mouse / click / click_at / press / drop_fruit / set_seed ... */
  action: string;
  /** 动作参数（见 runner.ts 的动作表） */
  params?: Record<string, unknown>;
  /** 步骤说明（仅报告用） */
  note?: string;
}

/** 断言步骤：二选一 */
export type AssertStep =
  | { kind: "vision"; question: string; expect: ExpectSchema; note?: string }
  | { kind: "hook"; expect: ExpectSchema; note?: string }
  | { kind: "wait"; ms: number };

/* ---------- 执行结果 ---------- */

export interface StepResult {
  name: string;
  ok: boolean;
  /** 失败原因 */
  detail?: string;
  /** 该步骤关联的截图证据（相对 outDir 的路径） */
  evidence?: string;
  /** 视觉模型的原始回答（仅 vision 断言） */
  raw?: string;
  /** 断言时的实际状态 */
  state?: Record<string, unknown>;
  /** 尝试次数（>1 表示重试过） */
  attempts?: number;
}

export interface ScenarioResult {
  game: string;
  scenario: string;
  ok: boolean;
  steps: StepResult[];
  /** 各断言失败摘要，便于报告定位 */
  failures: string[];
  durationMs: number;
}
