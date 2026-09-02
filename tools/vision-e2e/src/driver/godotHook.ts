import type { Page } from "@playwright/test";

/**
 * Godot 测试钩子（灰盒通道）。
 *
 * 游戏侧约定（可选，但强烈建议）：
 *   URL 带 ?test=1 时，游戏挂载 window.__gameState，形如：
 *     { score: 120, fruit_count: 5, game_over: false, level: 3, ... }
 *   以及 window.__gameTest = { setSeed(n), ... } 之类的测试控制接口。
 *
 * 没有钩子时这些函数静默返回 null，测试仍可跑（纯视觉模式），
 * 只是精确数值断言不可用。
 */

export interface GameState {
  [key: string]: unknown;
}

export async function getGameState(page: Page): Promise<GameState | null> {
  return page.evaluate(() => {
    const g = (window as unknown as { __gameState?: Record<string, unknown> }).__gameState;
    return g ?? null;
  });
}

/** 调用测试控制接口（如 setSeed），无钩子时返回 false */
export async function callTestApi(
  page: Page,
  method: string,
  ...args: unknown[]
): Promise<boolean> {
  const ok = await page.evaluate(
    ([m, a]) => {
      const t = (window as unknown as { __gameTest?: Record<string, (...x: unknown[]) => unknown> }).__gameTest;
      if (!t || typeof t[m] !== "function") return false;
      t[m](...a);
      return true;
    },
    [method, args] as const
  );
  return ok;
}
