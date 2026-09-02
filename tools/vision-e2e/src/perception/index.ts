import { config } from "../config";
import { DeepSeekVisionProvider } from "./deepseek";
import { MockVisionProvider } from "./mock";
import type { PerceptionProvider } from "./types";

let instance: PerceptionProvider | null = null;

/** 全局唯一的感知 provider（按 VISION_MOCK 选择，可被测试注入覆盖） */
export function getProvider(): PerceptionProvider {
  if (instance) return instance;
  instance = config.visionMock
    ? new MockVisionProvider()
    : new DeepSeekVisionProvider();
  return instance;
}

/** 测试注入（替换 provider 实例，便于集成测试） */
export function setProvider(p: PerceptionProvider | null) {
  instance = p;
}
