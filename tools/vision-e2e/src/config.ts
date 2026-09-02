import "dotenv/config";
import path from "node:path";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
/** 项目根：tools/vision-e2e/ */
const root = path.resolve(here, "..");

function env(name: string, fallback = ""): string {
  const v = process.env[name];
  return v === undefined || v === "" ? fallback : v;
}

export const config = {
  /** DeepSeek API key */
  deepseekApiKey: env("DEEPSEEK_API_KEY"),
  /** 视觉模型名 */
  visionModel: env("VISION_MODEL", "deepseek-v4-flash-vision-exp"),
  /** low=512x512 更省 / high=原图 */
  visionDetail: env("VISION_DETAIL", "low"),
  /** 1 = 使用 mock 视觉，不调 API */
  visionMock: env("VISION_MOCK", "0") === "1",
  /** 视觉断言失败重试次数 */
  visionRetry: Number(env("VISION_RETRY", "2")),
  /** 被测地址（env 覆盖 YAML base_url） */
  baseUrlOverride: env("BASE_URL"),
  /** 本地构建产物根目录（相对本目录） */
  webRoot: env("WEB_ROOT", "../../build/web"),
  /** 证据与结果输出目录（相对本目录） */
  outDir: env("OUT_DIR", "test-results/vision"),
};

export function absWebRoot(): string {
  return path.resolve(root, config.webRoot);
}

export function absOutDir(): string {
  return path.resolve(root, config.outDir);
}
