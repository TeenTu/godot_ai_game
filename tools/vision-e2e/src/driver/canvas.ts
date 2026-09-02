import type { Page } from "@playwright/test";

/**
 * Canvas 坐标操作 —— 所有坐标都用「百分比」而非像素，
 * 这样不受 canvas 实际尺寸/分辨率影响，Godot 的屏幕缩放也不会破坏坐标。
 */

export interface Point {
  /** 相对 canvas 宽度的百分比 0-100 */
  x: number;
  /** 相对 canvas 高度的百分比 0-100 */
  y: number;
}

/** 找到 Godot 的 canvas 元素并返回它的页面坐标盒子 */
export async function canvasBox(page: Page) {
  const box = await page
    .locator("canvas")
    .first()
    .boundingBox();
  if (!box) {
    throw new Error("找不到 canvas 元素 —— 游戏可能还没加载出来（等 waitForCanvasReady）");
  }
  return box;
}

/** 把百分比坐标换算成页面绝对坐标（相对 canvas 左上角） */
export async function toPagePoint(page: Page, p: Point) {
  const box = await canvasBox(page);
  return {
    x: box.x + (p.x / 100) * box.width,
    y: box.y + (p.y / 100) * box.height,
  };
}

/** 在 canvas 上移动鼠标到百分比坐标 */
export async function moveMouse(page: Page, p: Point) {
  const pt = await toPagePoint(page, p);
  await page.mouse.move(pt.x, pt.y);
}

/** 在 canvas 上点击百分比坐标（先移动再按下，模拟真人操作） */
export async function clickAt(page: Page, p: Point) {
  await moveMouse(page, p);
  await page.mouse.down();
  await page.waitForTimeout(60);
  await page.mouse.up();
}

/** 在 canvas 上拖拽（用于需要拖拽瞄准的游戏） */
export async function drag(page: Page, from: Point, to: Point, steps = 12) {
  const a = await toPagePoint(page, from);
  const b = await toPagePoint(page, to);
  await page.mouse.move(a.x, a.y);
  await page.mouse.down();
  await page.mouse.move(b.x, b.y, { steps });
  await page.waitForTimeout(60);
  await page.mouse.up();
}
