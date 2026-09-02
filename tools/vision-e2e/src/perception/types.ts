/**
 * 感知层统一类型 ——「眼睛」的抽象。
 * 任何视觉模型只要实现 PerceptionProvider，就能接入套件。
 */

/** 视觉断言的期望字段（来自 YAML 的 expect: 部分） */
export type ExpectRule =
  | boolean
  | number
  | string
  | null
  | { gt?: number; gte?: number; lt?: number; lte?: number; eq?: unknown; ne?: unknown };

export type ExpectSchema = Record<string, ExpectRule>;

/** 视觉模型对一张截图的回答（解析后的 JSON 对象） */
export type VisionState = Record<string, unknown>;

export interface PerceptionResult {
  /** 原始文本（模型输出） */
  raw: string;
  /** 解析出的 JSON 对象 */
  state: VisionState;
  /** 模型名 */
  model: string;
}

export interface PerceptionProvider {
  /**
   * 看一张截图，回答一个问题，返回结构化 JSON。
   * @param image       PNG 截图 Buffer
   * @param question    自由文本问题（来自 YAML）
   * @param schema      期望的 JSON 字段结构（来自 expect:），用于约束模型输出
   */
  query(image: Buffer, question: string, schema: ExpectSchema): Promise<PerceptionResult>;
}

/** 由 expect 字段生成「输出模板」，让模型只回答我们关心的字段 */
export function buildOutputTemplate(schema: ExpectSchema): string {
  const lines = Object.entries(schema).map(([k, rule]) => {
    const t = ruleTypeHint(rule);
    return `  "${k}": ${t}`;
  });
  return `{\n${lines.join(",\n")}\n}`;
}

function ruleTypeHint(rule: ExpectRule): string {
  if (typeof rule === "boolean") return "true 或 false";
  if (typeof rule === "number") return "数字";
  if (typeof rule === "string") return "字符串";
  if (rule === null) return "null";
  if (typeof rule === "object") {
    // 操作符对象：{gt:0} → 数字；{eq:...} → 按值类型
    if ("eq" in rule) return typeof rule.eq === "number" ? "数字" : "值";
    if ("ne" in rule) return typeof rule.ne === "number" ? "数字" : "值";
    return "数字";
  }
  return "值";
}
