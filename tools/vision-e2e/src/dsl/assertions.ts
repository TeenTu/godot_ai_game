import type { ExpectRule, ExpectSchema } from "../perception/types";

/**
 * 语义断言 —— 用视觉模型/测试钩子返回的 JSON 状态，对照 YAML 里的 expect 字段。
 * 支持两种写法：
 *   expect: { game_visible: true }          → 值相等
 *   expect: { score: { gt: 100 } }          → 操作符对象（gt/gte/lt/lte/eq/ne）
 */

export interface AssertFailure {
  field: string;
  message: string;
}

export function assertState(
  state: Record<string, unknown>,
  expect: ExpectSchema
): AssertFailure[] {
  const failures: AssertFailure[] = [];
  for (const [field, rule] of Object.entries(expect)) {
    const err = checkField(state[field], rule);
    if (err) {
      failures.push({ field, message: `${field} ${err}` });
    }
  }
  return failures;
}

function checkField(actual: unknown, rule: ExpectRule): string | null {
  if (typeof rule === "boolean") {
    return actual === rule ? null : `期望 ${rule}，实际 ${json(actual)}`;
  }
  if (typeof rule === "number") {
    return actual === rule ? null : `期望 ${rule}，实际 ${json(actual)}`;
  }
  if (typeof rule === "string") {
    return actual === rule ? null : `期望 "${rule}"，实际 ${json(actual)}`;
  }
  if (rule === null) {
    return actual === null || actual === undefined
      ? null
      : `期望 null，实际 ${json(actual)}`;
  }
  if (typeof rule === "object") {
    return checkOps(actual, rule);
  }
  return `不支持的断言规则 ${json(rule)}`;
}

function checkOps(actual: unknown, ops: Record<string, unknown>): string | null {
  const num = Number(actual);
  const nIsNum = Number.isFinite(num);

  if ("eq" in ops) {
    return actual === ops.eq ? null : `期望 == ${json(ops.eq)}，实际 ${json(actual)}`;
  }
  if ("ne" in ops) {
    return actual !== ops.ne ? null : `期望 != ${json(ops.ne)}，实际 ${json(actual)}`;
  }
  if (!nIsNum) return `期望数值比较，但实际值不是数字：${json(actual)}`;

  if ("gt" in ops && !(num > Number(ops.gt))) return `期望 > ${ops.gt}，实际 ${num}`;
  if ("gte" in ops && !(num >= Number(ops.gte))) return `期望 >= ${ops.gte}，实际 ${num}`;
  if ("lt" in ops && !(num < Number(ops.lt))) return `期望 < ${ops.lt}，实际 ${num}`;
  if ("lte" in ops && !(num <= Number(ops.lte))) return `期望 <= ${ops.lte}，实际 ${num}`;
  return null;
}

function json(v: unknown): string {
  return JSON.stringify(v);
}
