class NovelAiProvider {
  const NovelAiProvider(this.id, this.name, this.endpoint, this.models);
  final String id, name, endpoint;
  final List<String> models;

  static NovelAiProvider? forEndpoint(String endpoint) {
    final normalized = endpoint.replaceFirst(RegExp(r'/+$'), '');
    for (final provider in novelAiProviders) {
      if (provider.endpoint == normalized ||
          (provider.id == 'deepseek' && normalized == '${provider.endpoint}/v1')) {
        return provider;
      }
    }
    return null;
  }
}

// Chat Completions providers and model IDs from their public catalogs.
const novelAiProviders = [
  NovelAiProvider('deepseek', 'DeepSeek', 'https://api.deepseek.com', [
    'deepseek-flash', 'deepseek-v4-pro',
  ]),
  NovelAiProvider('openai', 'OpenAI', 'https://api.openai.com/v1', [
    'gpt-6.1-sol', 'gpt-6-astra', 'gpt-6-sol', 'gpt-6-luna',
    'gpt-4.1', 'gpt-4.1-mini', 'gpt-4.1-nano', 'gpt-4o', 'gpt-4o-mini',
  ]),
  NovelAiProvider('siliconflow-cn', '硅基流动 SiliconFlow（中国）', 'https://api.siliconflow.cn/v1', [
    'Pro/deepseek-ai/DeepSeek-V3.2', 'Pro/deepseek-ai/DeepSeek-R1',
    'Pro/moonshotai/Kimi-K2.6', 'Qwen/Qwen3-8B',
    'stepfun-ai/Step-3.5-Flash', 'zai-org/GLM-5.2',
  ]),
  NovelAiProvider('alibaba-cn', '阿里云百炼 Alibaba（中国）', 'https://dashscope.aliyuncs.com/compatible-mode/v1', [
    'qwen3.8-max', 'qwen3.5-397b-a17b', 'qwen3-235b-a22b',
    'qwen3-8b', 'deepseek-v4.1-flash', 'deepseek-v4-flash',
  ]),
  NovelAiProvider('moonshotai-cn', '月之暗面 Moonshot（中国）', 'https://api.moonshot.cn/v1', [
    'kimi-k3', 'kimi-k2.6',
  ]),
  NovelAiProvider('zhipuai', '智谱 Zhipu AI', 'https://open.bigmodel.cn/api/paas/v4', [
    'glm-5.3', 'glm-5.3-flash', 'glm-5.3-flashx', 'glm-4.7', 'glm-4.7-flash',
  ]),
  NovelAiProvider('openrouter', 'OpenRouter', 'https://openrouter.ai/api/v1', [
    'deepseek/deepseek-v4-flash', 'openai/gpt-4.1-mini', 'openai/gpt-4o-mini',
    'anthropic/claude-sonnet-4.5', 'google/gemini-2.5-flash',
  ]),
];
