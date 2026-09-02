import type { ExpectSchema, PerceptionProvider, PerceptionResult } from "./types";

/**
 * Mock 视觉 —— 不调任何 API，按 schema 生成可通过的答案。
 * 用途：验证套件链路（打开游戏 → 截图 → 感知 → 断言）本身没坏，
 * 而不依赖外部服务与 key。
 *
 * 断言是否通过由 assertion 层判断；mock 只是"假装看到"字段并填 true/0。
 * 注意：mock 下所有视觉断言都会通过，只适合链路自检，不是真实测试。
 */
export class MockVisionProvider implements PerceptionProvider {
  readonly model = "mock";

  async query(
    _image: Buffer,
    _question: string,
    schema: ExpectSchema
  ): Promise<PerceptionResult> {
    const state: Record<string, unknown> = {};
    for (const [k, rule] of Object.entries(schema)) {
      if (typeof rule === "boolean") state[k] = true;
      else if (typeof rule === "number") state[k] = 0;
      else if (typeof rule === "string") state[k] = "";
      else if (rule === null) state[k] = null;
      else if (typeof rule === "object") {
        // 操作符对象：默认给一个不触发断言的中间值（0）
        state[k] = 0;
      }
    }
    return { raw: JSON.stringify(state), state, model: this.model };
  }
}
