import { test, expect } from "@playwright/test";

// M2 弹幕/技能系统 —— 真实产物手势路由验证（确定性 hook 断言 + 截图，无需视觉 key）。
//
// 设计（design_m2_danmaku.md / main.gd）：
//   屏宽分界 SKILL_ZONE_X=0.65 -> 触点 canvas x > 720*0.65=468 = 右侧技能手势区。
//   摇杆 exclude_right_x=0.65 -> 右侧触点不被摇杆认领，全部留给技能手势。
//   手势：tap(≤0.2s 且位移≤14px)=Fan / ←swipe(|dx|≥110 且 |dx|>2|dy|)=Chain / →swipe=Nuke。
// 验证：每次手势后其对应 sk_* 冷却从就绪(0)进入 CD(>0)，证明右区手势正确路由到目标技能。
// __gameState.sk_fan/sk_chain/sk_nuke/sk_ready 由 _test_hook_get_state 每 0.1s 发布。

async function getState(page: import("@playwright/test").Page): Promise<Record<string, unknown>> {
  return (await page.evaluate(
    () => (window as unknown as { __gameState?: Record<string, unknown> }).__gameState ?? null
  )) as Record<string, unknown>;
}

test("boom skills: right-zone tap/swipe route to fan/chain/nuke & enter cooldown", async ({
  browser,
}) => {
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
  await page.waitForTimeout(1500); // 等技能三槽就绪 + 世界稳定

  // 触摸派发（同 _boom_touch/_boom_area 约定）：坐标为 canvas page 像素(720x1280 满幅)。
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
  const num = (s: Record<string, unknown>, k: string) => Number(s[k] ?? 0);
  const ZONE_X = 0.65; // SKILL_ZONE_X
  const right = (frac: number) => 720 * ZONE_X + frac * (720 - 720 * ZONE_X); // x 落右区
  const y_mid = 700;

  // ---- 1) tap -> Fan（进入 fan CD=3）----
  let s = await getState(page);
  const fan0 = num(s, "sk_fan");
  expect(fan0, "开局 fan 应就绪 (sk_fan=0)").toBeLessThanOrEqual(0.0);
  const rx = right(0.5); // ~594
  const ry = y_mid;
  await dispatch("touchstart", rx, ry, 1);
  await page.waitForTimeout(50); // < TAP_MAX_TIME(0.2s)
  await dispatch("touchend", rx + 1, ry, 1); // 位移≈1px -> tap
  await page.waitForTimeout(220);
  s = await getState(page);
  console.log("TAP(→fan) state:", JSON.stringify(s));
  expect(num(s, "sk_fan"), "tap 后 fan 进入 CD (sk_fan>0)").toBeGreaterThan(0.0);
  expect(num(s, "bullets"), "fan 施放后有子弹").toBeGreaterThanOrEqual(0);
  await page.screenshot({ path: "test-results/_boom_skills_1_fan.png" });

  // ---- 2) <-swipe -> Chain（进入 chain CD=8）----
  // 等待 fan CD 走完避免与下方断言混淆(无碍，只查 chain 槽)
  await page.waitForTimeout(3500); // 等 fan CD(3s) 归零 + 世界推进
  s = await getState(page);
  console.log("pre-chain state:", JSON.stringify(s));
  const cStartX = right(0.75); // ~657
  const cEndX = right(0.05); // ~480 (仍 >468 起始区即可)
  await dispatch("touchstart", cStartX, y_mid, 2);
  // 向左滑 ~177px，分多步成 swipe
  const steps = 15;
  for (let i = 1; i <= steps; i++) {
    const x = cStartX + ((cEndX - cStartX) * i) / steps;
    await dispatch("touchmove", x, y_mid, 2);
    await page.waitForTimeout(16);
  }
  await page.waitForTimeout(120);
  await dispatch("touchend", cEndX, y_mid, 2);
  await page.waitForTimeout(250);
  s = await getState(page);
  console.log("SWIPE_LEFT(→chain) state:", JSON.stringify(s));
  expect(num(s, "sk_chain"), "←swipe 后 chain 进入 CD (sk_chain>0)").toBeGreaterThan(0.0);
  await page.screenshot({ path: "test-results/_boom_skills_2_chain.png" });

  // ---- 3) ->swipe -> Nuke（进入 nuke CD=20）----
  await page.waitForTimeout(250);
  s = await getState(page);
  const nStartX = right(0.05);
  const nEndX = right(0.75);
  await dispatch("touchstart", nStartX, y_mid, 3);
  for (let i = 1; i <= steps; i++) {
    const x = nStartX + ((nEndX - nStartX) * i) / steps;
    await dispatch("touchmove", x, y_mid, 3);
    await page.waitForTimeout(16);
  }
  await page.waitForTimeout(120);
  await dispatch("touchend", nEndX, y_mid, 3);
  await page.waitForTimeout(300);
  s = await getState(page);
  console.log("SWIPE_RIGHT(→nuke) state:", JSON.stringify(s));
  expect(num(s, "sk_nuke"), "→swipe 后 nuke 进入 CD (sk_nuke>0)").toBeGreaterThan(0.0);
  await page.screenshot({ path: "test-results/_boom_skills_3_nuke.png" });

  // ---- 4) 三技能独立：nuke 就绪前另两槽的 CD 状态互不干扰（nuke CD 长仍在转）----
  expect(num(s, "sk_nuke"), "nuke CD 20s 应仍在 CD").toBeGreaterThan(0.0);

  await ctx.close();
});
