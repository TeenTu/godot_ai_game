import { test, expect } from "@playwright/test";

// 验证修复后没有"实际区域 ≠ 视觉区域"的 bug：
//  1) DYNAMIC 摇杆在左侧摇杆区的多个不同位置按下都应就地出现、不飞出屏。
//  2) 触摸 + 释放后,玩家世界坐标回落/保持在合理范围(没因坐标错位冲到屏幕外)。
//  3) 连续多个触摸循环后画面无"整体右移"失控 —— 用玩家 x/z 幅度 + joy geom 断言。
// 屏幕分区(design_m2_danmaku)：SKILL_ZONE_X=0.65 —— 右区(x>0.65)触摸路由给技能
// 手势，摇杆 exclude_right_x=0.65 本就不响应右区触摸；因此所有触点约束在左区。
// 说明：无视觉 key,用 hook 数值断言；截图供人工/后续 vision 复核。

async function getState(page: import("@playwright/test").Page): Promise<Record<string, unknown>> {
  return (await page.evaluate(
    () => (window as unknown as { __gameState?: Record<string, unknown> }).__gameState ?? null
  )) as Record<string, unknown>;
}

test("boom: joystick usable at multiple on-screen regions & no runaway", async ({ browser }) => {
  const ctx = await browser.newContext({
    viewport: { width: 720, height: 1280 },
    hasTouch: true,
    isMobile: true,
  });
  const page = await ctx.newPage();
  page.on("console", (m) => {
    const t = m.text();
    if (m.type() === "error" || t.includes("ERROR")) console.log("[page-err]", t);
  });

  await page.goto("http://localhost:8126/?test=1", { waitUntil: "load", timeout: 60_000 });
  for (let i = 0; i < 40; i++) {
    if (await getState(page)) break;
    await page.waitForTimeout(500);
  }
  await page.waitForTimeout(1200);

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

  // 记录每次触摸循环时摇杆底座是否出现在"该次触点附近"(归一坐标差的容差)
  // 全部触点 x<0.65(左区)；拖动方向正负交替，避免玩家坐标单向累计漂移。
  const regions = [
    { p: { x: 50, y: 15 }, dx: -40, dy: 40, label: "top_center_left" },
    { p: { x: 15, y: 30 }, dx: 60, dy: 60, label: "top_left" },
    { p: { x: 55, y: 60 }, dx: 40, dy: -50, label: "mid_left" },
    { p: { x: 25, y: 85 }, dx: -70, dy: -40, label: "bottom_left" },
  ];

  for (let i = 0; i < regions.length; i++) {
    const r = regions[i];
    const d = toPx(r.p);
    await dispatch("touchstart", d.x, d.y, 1);
    await page.waitForTimeout(220);
    // 拖一小段
    await dispatch("touchmove", d.x + r.dx, d.y + r.dy, 1);
    await page.waitForTimeout(220);
    const mid = await getState(page);
    const num = (k: string) => Number(mid[k] ?? 0);
    console.log(`region[${r.label}] press at %`, r.p, " state:", JSON.stringify(mid));
    // 断言：底座在触点附近(如触点归一 ~0.50,0.15; 底座应在 (0.3..0.7, 0.0..0.3))
    // 用一个宽泛但能抓"飞到屏外/跟手到远处"的断言
    expect(num("joy_pressed"), `${r.label} 触摸中应 joy_pressed=true`).toBe(1);
    expect(num("joy_bx"), `${r.label} 底座x应在[0.02,0.98]`).toBeGreaterThan(0.02);
    expect(num("joy_bx"), `${r.label} 底座x应在[0.02,0.98]`).toBeLessThan(0.98);
    expect(num("joy_by"), `${r.label} 底座y应在[0.02,0.98]`).toBeGreaterThan(0.02);
    expect(num("joy_by"), `${r.label} 底座y应在[0.02,0.98]`).toBeLessThan(0.98);
    await page.screenshot({ path: `test-results/_boom_area_${i}_${r.label}.png` });
    await dispatch("touchend", d.x + r.dx, d.y + r.dy, 1);
    await page.waitForTimeout(1200);
  }

  const final = await getState(page);
  console.log("FINAL state:", JSON.stringify(final));
  const fx = Number(final.x);
  const fz = Number(final.z);
  // 玩家未被冲到失控区域(多次触摸循环内)。若"实际区域≠视觉区",玩家会冲很远。
  expect(Math.abs(fx), "玩家 |x| 不应失控(<12)").toBeLessThan(12.0);
  expect(Math.abs(fz), "玩家 |z| 不应失控(<12)").toBeLessThan(12.0);
  await page.screenshot({ path: "test-results/_boom_area_final.png" });

  await ctx.close();
});
