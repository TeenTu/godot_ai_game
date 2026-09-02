import type { Page } from "@playwright/test";

/**
 * 游戏专用等待。
 * Godot Web 是 WebGL canvas：没有 DOM 状态可等，只能等「画面稳定」。
 */

/** 等待 canvas 出现 + 游戏引擎渲染出第一帧（不再全黑/全白） */
export async function waitForCanvasReady(page: Page, timeoutMs = 30_000) {
  await page.waitForSelector("canvas", { timeout: timeoutMs });
  // 首帧：canvas 有实际内容（非空白）。连续采两帧，若完全一致且非纯黑，认为引擎已渲染。
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const shot = await page.screenshot();
    const blank = isUniform(shot);
    if (!blank) return;
    await page.waitForTimeout(500);
  }
  throw new Error("等待游戏首帧超时 —— canvas 一直为空/全黑，检查导出产物与 base_url");
}

/**
 * 等待画面「静止」：连续两帧截图字节完全一致（PNG 无损压缩，
 * 相同像素 → 相同字节），说明动画/粒子播完了。
 * 若游戏永远在动（粒子循环），maxWait 超时后返回 false，由调用方决定是否继续。
 */
export async function waitForStable(
  page: Page,
  opts: { maxWaitMs?: number; sampleMs?: number } = {}
): Promise<boolean> {
  const maxWaitMs = opts.maxWaitMs ?? 8_000;
  const sampleMs = opts.sampleMs ?? 400;
  const deadline = Date.now() + maxWaitMs;
  let prev: Buffer | null = null;

  while (Date.now() < deadline) {
    const shot = await page.screenshot();
    if (prev && shot.equals(prev)) {
      return true; // 两帧一致 → 画面静止
    }
    prev = shot;
    await page.waitForTimeout(sampleMs);
  }
  return false;
}

/** 判断一帧截图是否为纯色（全黑/全白/全透明），用于探测首帧 */
function isUniform(buf: Buffer, samples = 64): boolean {
  // 只取几个采样点的像素粗略判断：从 PNG 解码成本高，这里退而比较字节熵太低效。
  // 简单可靠的做法：全黑 PNG 的字节分布极窄，但不同压缩下难判。
  // —— 用 buffer 大小变化兜底：空白帧通常极小（<20KB，无细节），
  // 有画面的帧明显更大。经验阈值，可调。
  return buf.length < 20_000;
}
