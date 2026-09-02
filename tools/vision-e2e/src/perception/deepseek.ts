import { config } from "../config";
import type { ExpectSchema, PerceptionProvider, PerceptionResult } from "./types";
import { buildOutputTemplate } from "./types";

/**
 * DeepSeek V4 Flash Vision 适配器。
 * 官方 API 是 OpenAI 兼容格式：POST https://api.deepseek.com/chat/completions，
 * 图片以 base64 data URL 放进 image_url 内容块。见
 * https://api-docs.deepseek.com/guides/vision
 */
export class DeepSeekVisionProvider implements PerceptionProvider {
  readonly model: string;
  private readonly apiKey: string;

  constructor(opts?: { apiKey?: string; model?: string }) {
    this.model = opts?.model ?? config.visionModel;
    this.apiKey = opts?.apiKey ?? config.deepseekApiKey;
    if (!this.apiKey) {
      throw new Error(
        "缺少 DEEPSEEK_API_KEY —— 在 tools/vision-e2e/.env 里配置（参考 .env.example），或设 VISION_MOCK=1 用 mock 跑"
      );
    }
  }

  async query(
    image: Buffer,
    question: string,
    schema: ExpectSchema
  ): Promise<PerceptionResult> {
    const template = buildOutputTemplate(schema);
    const prompt = [
      "你是游戏自动化测试的「眼睛」。观察这张游戏截图，回答测试员的问题。",
      "严格只输出一个 JSON 对象，不要输出任何解释、代码块标记或其他文字。",
      `输出必须符合这个结构（每个字段都要填）：\n${template}`,
      `问题：${question}`,
      "不确定的字段填 null，不要编造。",
    ].join("\n");

    const body = {
      model: this.model,
      messages: [
        {
          role: "user",
          content: [
            { type: "text", text: prompt },
            {
              type: "image_url",
              image_url: {
                url: `data:image/png;base64,${image.toString("base64")}`,
                detail: config.visionDetail, // low=512x512 更快更省；high=原图
              },
            },
          ],
        },
      ],
      temperature: 0.2,
      // 关闭推理模式，降低延迟（实验性模型默认 thinking 开启）
      reasoning_effort: "none",
      response_format: { type: "json_object" },
    } as Record<string, unknown>;

    const resp = await fetch("https://api.deepseek.com/chat/completions", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${this.apiKey}`,
      },
      body: JSON.stringify(body),
    });

    if (!resp.ok) {
      const text = await resp.text().catch(() => "");
      throw new Error(`视觉模型 API 调用失败 HTTP ${resp.status}: ${text.slice(0, 300)}`);
    }

    const data = (await resp.json()) as {
      choices?: Array<{ message?: { content?: string } }>;
    };
    const raw = data.choices?.[0]?.message?.content ?? "";

    let state: Record<string, unknown>;
    try {
      // 去掉可能的代码块围栏后解析
      state = JSON.parse(raw.replace(/^```(?:json)?\s*/i, "").replace(/```\s*$/, ""));
    } catch {
      throw new Error(`视觉模型返回的不是合法 JSON：\n${raw.slice(0, 500)}`);
    }

    return { raw, state, model: this.model };
  }
}
