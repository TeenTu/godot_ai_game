import { test, expect } from "@playwright/test";

// M12 技能系统 —— 真实 Web 产物触摸路由验证（确定性 hook 断言 + 截图）。
//
// 默认构筑同时包含被动 lamp_quick_wick 与主动 lamp_firefly_volley；战斗触发槽
// 必须只投影主动技能，避免 tap 被位于构筑首位的被动技能吞掉。
// 手势容错：tap(≤0.35s 且位移≤24px)，右侧技能区起点 x > 720*0.65。

async function getState(page: import("@playwright/test").Page): Promise<Record<string, unknown>> {
  return (await page.evaluate(
    () => (window as unknown as { __gameState?: Record<string, unknown> }).__gameState ?? null
  )) as Record<string, unknown>;
}

test("boom skills: passive does not swallow tap and active skill presents", async ({ browser }) => {
  const ctx = await browser.newContext({
    viewport: { width: 720, height: 1280 },
    hasTouch: true,
    isMobile: true,
  });
  const page = await ctx.newPage();
  const pageErrors: string[] = [];
  page.on("console", (m) => {
    const message = m.text();
    if (m.type() === "error" || message.includes("SCRIPT ERROR")) pageErrors.push(message);
  });
  page.on("pageerror", (error) => pageErrors.push(error.message));

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
        identifier: id,
        target,
        clientX,
        clientY,
        pageX: clientX,
        pageY: clientY,
        screenX: clientX,
        screenY: clientY,
        radiusX: 5,
        radiusY: 5,
        rotationAngle: 0,
        force: 1,
      });
      target.dispatchEvent(
        new TouchEvent(t, {
          cancelable: true,
          bubbles: true,
          touches: t === "touchend" ? [] : [touch],
          targetTouches: t === "touchend" ? [] : [touch],
          changedTouches: [touch],
        })
      );
    }, { t: type, x, y, id });
  };
  const num = (state: Record<string, unknown>, key: string) => Number(state[key] ?? 0);
  const waitForSkillCD = async (key: string, timeoutMs = 6000) => {
    const deadline = Date.now() + timeoutMs;
    let state = await getState(page);
    while (Date.now() < deadline) {
      state = await getState(page);
      if (num(state, key) > 0) return state;
      await page.waitForTimeout(200);
    }
    return state;
  };

  let state = await getState(page);
  expect(state, "测试钩子应发布游戏状态").toBeTruthy();
  expect(state.sk_slots, "HUD 触发槽只应包含主动技能").toEqual([
    "lamp_firefly_volley",
    "",
    "",
  ]);
  expect(state.sk_passives, "被动技能仍应保留在构筑中").toContain("lamp_quick_wick");
  expect(num(state, "sk_lamp_firefly_volley"), "开局流萤散射应就绪").toBeLessThanOrEqual(0);

  // 右区短按：完整穿过浏览器 TouchEvent -> Godot 输入 -> 主动槽 0 -> 技能施放。
  const tapX = 594;
  const tapY = 700;
  await dispatch("touchstart", tapX, tapY, 1);
  await page.waitForTimeout(80);
  await dispatch("touchend", tapX + 2, tapY + 1, 1);
  state = await waitForSkillCD("sk_lamp_firefly_volley");

  expect(num(state, "sk_lamp_firefly_volley"), "tap 后流萤散射应进入冷却").toBeGreaterThan(0);
  expect(state.sk_presentation).toMatchObject({
    skill_id: "lamp_firefly_volley",
    presentation: "firefly_fan",
  });
  expect(num(state, "bullets"), "流萤散射应生成弹体").toBeGreaterThan(0);
  expect(pageErrors, "Web 运行期间不应出现脚本或页面错误").toEqual([]);

  await page.screenshot({ path: "test-results/_boom_skills_m12_firefly.png" });
  await ctx.close();
});
