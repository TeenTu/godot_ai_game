// S1-11 Batch 7 / AT-45：真实 Web 导出 + 视觉 E2E 驱动（Playwright + 真浏览器 WebGL2）。
//
// 用途：把游戏的 Web 导出产物用真实 Chromium 打开，按脚本点击/截图，并把
// 浏览器 console 与 pageerror 全量落盘——Godot 渲染在 canvas 里，DOM 无从断言，
// 所以「有没有跑起来 / 有没有报错 / 中文有没有漏英文」只能靠真机截图看。
//
// 用法（在仓库根目录）：
//   python games/sonar/tools/serve_web_coop.py games/sonar/build/web 8330 &
//   node tools/vision-e2e/scripts/sonar_web_visual.mjs '<json-plan>'
//   node tools/vision-e2e/scripts/sonar_web_visual.mjs @scenarios/sonar/xxx.json
//
// plan = { url, out_dir, viewport:[w,h], steps:[ ... ] }
//   {kind:"wait",ms} {kind:"shot",name} {kind:"click",x,y} {kind:"rclick",x,y}
//   {kind:"drag",x,y,x2,y2,steps} {kind:"move",x,y} {kind:"viewport",w,h}
//   {kind:"key",key} {kind:"eval",js}
// x/y 为 canvas 内比例坐标（0..1）。截图与 console.log 落在 out_dir。
//
// 环境变量：PW_PLAYWRIGHT（playwright 模块 URL）、PW_CHROME（Chromium 可执行文件）。
import fs from "node:fs";
import path from "node:path";

const PW =
	process.env.PW_PLAYWRIGHT ||
	"file:///C:/Users/10532/AppData/Local/npm-cache/_npx/423231821c231c73/node_modules/playwright/index.mjs";
const { chromium } = await import(PW);

const rawPlan = process.argv[2];
const plan = JSON.parse(
	rawPlan.startsWith("@") ? fs.readFileSync(rawPlan.slice(1), "utf8") : rawPlan,
);
const outDir = plan.out_dir;
fs.mkdirSync(outDir, { recursive: true });
const log = [];
const say = (s) => {
	log.push(s);
	console.log(s);
};

const launchOpts = {
	args: [
		"--enable-unsafe-swiftshader",
		"--use-gl=angle",
		"--use-angle=swiftshader",
		"--ignore-gpu-blocklist",
		"--disable-dev-shm-usage",
	],
};
launchOpts.executablePath = process.env.PW_CHROME || findChromium();
if (!launchOpts.executablePath) delete launchOpts.executablePath;

/** 本机 ms-playwright 缓存里的完整 Chromium（比 headless shell 更稳地拿到 WebGL2）。 */
function findChromium() {
	const root = path.join(
		process.env.LOCALAPPDATA || path.join(process.env.USERPROFILE || "", "AppData", "Local"),
		"ms-playwright",
	);
	if (!fs.existsSync(root)) return "";
	const dirs = fs
		.readdirSync(root)
		.filter((d) => d.startsWith("chromium-"))
		.sort()
		.reverse();
	for (const d of dirs) {
		const exe = path.join(root, d, "chrome-win64", "chrome.exe");
		if (fs.existsSync(exe)) return exe;
	}
	return "";
}

const browser = await chromium.launch(launchOpts);
const ctx = await browser.newContext({
	viewport: { width: plan.viewport[0], height: plan.viewport[1] },
	deviceScaleFactor: 1,
});
const page = await ctx.newPage();
const consoleErrors = [];
page.on("console", (m) => {
	const t = `${m.type()}: ${m.text()}`;
	log.push(`[console] ${t}`);
	if (m.type() === "error") consoleErrors.push(t);
});
page.on("pageerror", (e) => {
	consoleErrors.push(`pageerror: ${e.message}`);
	log.push(`[pageerror] ${e.message}`);
});

await page.goto(plan.url, { waitUntil: "load", timeout: 120000 });
say("goto ok");

const canvasBox = async () => {
	const el = await page.$("canvas");
	return el ? await el.boundingBox() : null;
};
const at = (b, x, y) => ({ x: b.x + b.width * x, y: b.y + b.height * y });

for (const st of plan.steps) {
	if (st.kind === "wait") {
		await page.waitForTimeout(st.ms);
	} else if (st.kind === "shot") {
		const p = path.join(outDir, `${st.name}.png`);
		await page.screenshot({ path: p });
		const b = await canvasBox();
		const size = b ? `${Math.round(b.width)}x${Math.round(b.height)}` : "none";
		say(`shot ${st.name} canvas=${size}`);
	} else if (st.kind === "click" || st.kind === "rclick") {
		const b = await canvasBox();
		const pos = at(b, st.x, st.y);
		await page.mouse.click(pos.x, pos.y, st.kind === "rclick" ? { button: "right" } : {});
		say(`${st.kind} ${st.x},${st.y}`);
	} else if (st.kind === "drag") {
		const b = await canvasBox();
		const from = at(b, st.x, st.y);
		await page.mouse.move(from.x, from.y);
		await page.mouse.down();
		const n = st.steps || 8;
		for (let i = 1; i <= n; i++) {
			const p = at(b, st.x + ((st.x2 - st.x) * i) / n, st.y + ((st.y2 - st.y) * i) / n);
			await page.mouse.move(p.x, p.y);
			await page.waitForTimeout(40);
		}
		await page.mouse.up();
		say(`drag ${st.x},${st.y} -> ${st.x2},${st.y2}`);
	} else if (st.kind === "move") {
		const b = await canvasBox();
		const p = at(b, st.x, st.y);
		await page.mouse.move(p.x, p.y, { steps: 6 });
	} else if (st.kind === "viewport") {
		await page.setViewportSize({ width: st.w, height: st.h });
	} else if (st.kind === "key") {
		await page.keyboard.press(st.key);
	} else if (st.kind === "eval") {
		say(`eval ${st.js} => ${JSON.stringify(await page.evaluate(st.js))}`);
	}
}

fs.writeFileSync(path.join(outDir, "console.log"), log.join("\n"));
say(`CONSOLE_ERRORS=${consoleErrors.length}`);
for (const e of consoleErrors) say(`ERR ${e}`);
await browser.close();
process.exit(consoleErrors.length === 0 ? 0 : 1);
