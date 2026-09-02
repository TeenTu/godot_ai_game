import { test, expect } from "@playwright/test";

// 用真实 TouchEvent 注入(不依赖 emulate_touch_from_mouse)，
// 验证修复后：
//  1) 玩家仍能通过摇杆移动(x 增加)；
//  2) DYNAMIC 摇杆底座不再飞出屏幕(joy_bx/joy_by 应落在 0..1 且留有合理边距)；
//  3) 摇杆帽中心也在屏内。
// 屏幕分区(design_m2_danmaku)：SKILL_ZONE_X=0.65 —— 归一 x>0.65 的右区触摸
// 全部路由给技能手势，摇杆 exclude_right_x=0.65 本就不响应右区触摸。
// 因此摇杆拖动起手必须在左侧摇杆区(x<0.65)。
// __gameState 由 main.gd _test_hook_get_state 发布(每 0.1s)。

async function getState(page: import("@playwright/test").Page): Promise<Record<string, unknown>> {
  return (await page.evaluate(
    () => (window as unknown as { __gameState?: Record<string, unknown> }).__gameState ?? null
  )) as Record<string, unknown>;
}

test("boom touch: player moves & joystick base stays on screen", async ({ browser }) => {
  const ctx = await browser.newContext({
    viewport: { width: 720, height: 1280 },
    hasTouch: true,
    isMobile: true,
  });
  const page = await ctx.newPage();
  page.on("console", (m) => console.log("[page]", m.type(), m.text()));

  await page.goto("http://localhost:8126/?test=1", { waitUntil: "load", timeout: 60_000 });
  for (let i = 0; i < 40; i++) {
    if (await getState(page)) break;
    await page.waitForTimeout(500);
  }
  await page.waitForTimeout(800);

  const before = await getState(page);
  console.log("BEFORE:", JSON.stringify(before));

  // 派发真实触摸事件到 canvas；坐标为 page 像素(画布满幅 720x1280)。
  const dispatch = (type: string, x: number, y: number, id: number) => {
    return page.evaluate(({ t, x, y, id }) => {
      const target = document.querySelector("canvas") as HTMLElement;
      const rect = target.getBoundingClientRect();
      const clientX = rect.left + x;
      const clientY = rect.top + y;
      const touch = new Touch({
        identifier: id, target, clientX, clientY, pageX: clientX, pageY: clientY,
        screenX: clientX, screenY: clientY, radiusX: 5, radiusY: 5, rotationAngle: 0, force: 1,
      });
      const ev = new TouchEvent(t, {
        cancelable: true, bubbles: true,
        touches: t === "touchend" ? [] : [touch],
        targetTouches: t === "touchend" ? [] : [touch],
        changedTouches: [touch],
      });
      target.dispatchEvent(ev);
    }, { t: type, x, y, id });
  };

  const toPx = (p: { x: number; y: number }) => ({ x: (p.x / 100) * 720, y: (p.y / 100) * 1280 });
  // 起手点必须在左区(x<0.65)；从左中(远离摇杆休息位)按下并往右上拖，
  // 仍能暴露"底座飞出/跟手错位"。终点也保持在左区。
  const d = toPx({ x: 25, y: 65 });
  const t = toPx({ x: 52, y: 40 });
  console.log("DOWN at px", d, " MOVE to px", t);

  await dispatch("touchstart", d.x, d.y, 1);
  await page.waitForTimeout(250);
  await page.screenshot({ path: "test-results/_boom_touch_1_down.png" });

  // 分若干步拖到目标点
  for (let i = 1; i <= 20; i++) {
    const x = d.x + ((t.x - d.x) * i) / 20;
    const y = d.y + ((t.y - d.y) * i) / 20;
    await dispatch("touchmove", x, y, 1);
    await page.waitForTimeout(25);
  }
  await page.waitForTimeout(250);
  const drag = await getState(page);
  console.log("DRAG:", JSON.stringify(drag));
  await page.screenshot({ path: "test-results/_boom_touch_2_drag.png" });

  await dispatch("touchend", t.x, t.y, 1);
  await page.waitForTimeout(400);
  const after = await getState(page);
  console.log("AFTER:", JSON.stringify(after));
  await page.screenshot({ path: "test-results/_boom_touch_3_release.png" });

  const n = (k: string) => Number((drag as Record<string, unknown>)[k] ?? 0);

  // 1) 玩家确实移动
  const xBefore = Number((before as Record<string, unknown>)?.x ?? 0);
  const xDrag = n("x");
  expect(xDrag - xBefore, "拖动后玩家 x 应变(移动生效)").not.toBeCloseTo(0, 2);

  // 2) 底座中心不飞出屏：0 < frac < 1(留 2% 边距，且不应跑到 <0 或 >1 这种"飞出")
  expect(n("joy_pressed"), "拖动中 joy_pressed 应为 true").toBe(1);
  expect(n("joy_bx"), "底座 center.x 归一应在 (0,1)").toBeGreaterThan(0.0);
  expect(n("joy_bx"), "底座 center.x 归一应在 (0,1)").toBeLessThan(1.0);
  expect(n("joy_by"), "底座 center.y 归一应在 (0,1)").toBeGreaterThan(0.0);
  expect(n("joy_by"), "底座 center.y 归一应在 (0,1)").toBeLessThan(1.0);
  // 底座留边距：至少 base_radius(84) 在屏内 → frac 应 ≥ 84/720 且 ≤ 1-84/720
  expect(n("joy_bx")).toBeGreaterThanOrEqual(84 / 720 - 0.001);
  expect(n("joy_bx")).toBeLessThanOrEqual(1 - 84 / 720 + 0.001);
  expect(n("joy_by")).toBeGreaterThanOrEqual(84 / 1280 - 0.001);
  expect(n("joy_by")).toBeLessThanOrEqual(1 - 84 / 1280 + 0.001);

  // 3) 摇杆帽也应在屏内
  expect(n("joy_kx")).toBeGreaterThan(-0.05);
  expect(n("joy_kx")).toBeLessThan(1.05);
  expect(n("joy_ky")).toBeGreaterThan(-0.05);
  expect(n("joy_ky")).toBeLessThan(1.05);

  await ctx.close();
});
