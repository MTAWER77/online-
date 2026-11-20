// NOVA AI - Multi Provider Worker
// Groq is the primary provider. Gemini and OpenRouter are automatic fallbacks.
// Configure API keys as Cloudflare Worker Secrets; never put secrets in public/app.js.

const TEXT_MODELS = [
  "openai/gpt-oss-120b",
  "qwen/qwen3.8-27b",
  "openai/gpt-oss-20b",
];
const VISION_MODEL = "qwen/qwen3.8-27b";
const SEARCH_MODELS = ["openai/gpt-oss-120b", "openai/gpt-oss-20b"];

const GROQ_API = "https://api.groq.com/openai/v1/chat/completions";
const GEMINI_API = "https://generativelanguage.googleapis.com/v1beta/openai/chat/completions";
const OPENROUTER_API = "https://openrouter.ai/api/v1/chat/completions";

const MAX_MESSAGES = 30;
const MAX_CHARS = 45000;
const MAX_IMAGES = 3;
const MAX_IMAGE_DATA_CHARS = 1800000;
const MAX_GENERATED_FILES = 20;
const MAX_GENERATED_FILE_CHARS = 100000;
const MAX_GENERATED_TOTAL_CHARS = 300000;
const MAX_KEYS_PER_PROVIDER = 5;

const SYSTEM_PROMPT =
  "You are NOVA AI, a helpful, accurate and friendly assistant. " +
  "Always reply in the same language the user writes in (Arabic or English). " +
  "Be direct and avoid unnecessary introductions. " +
  "You are also a Godot game engine expert. When users upload Godot project files: " +
  "Analyze GDScript code, .tscn scenes, .tres resources, node hierarchies, signals, paths, and interactions. " +
  "Treat multiple uploaded files as one project and reference exact file names. " +
  "Suggest specific, safe fixes and avoid breaking existing systems. " +
  "When images are attached, inspect their visible contents and answer the user's question about them. " +
  "If an image is unclear or unreadable, say so instead of guessing.";

const SEARCH_SYSTEM_PROMPT =
  SYSTEM_PROMPT + " The user enabled web search. Search the web before answering, " +
  "prioritize recent and trustworthy sources, distinguish facts from uncertainty, " +
  "and provide clickable source URLs. Answer in the user's language. Never invent sources or URLs.";

const FILES_SYSTEM_PROMPT =
  "You are NOVA AI's file-generation engine. " +
  'Return ONLY one valid JSON object: {"message":"...","files":[{"name":"relative/path.ext","content":"complete file content"}]}. ' +
  "Create complete, usable files based on the user's latest request and conversation context. " +
  "Do not use Markdown fences around the JSON. For one file, return one file. " +
  "For a project, return all required files and sensible relative paths. " +
  "For Godot projects, include project.godot and required scripts/scenes/resources when appropriate. " +
  "Do not use placeholders such as 'rest of code here'. Keep paths relative and safe. " +
  "Limit to 20 files and compact output. Use the same language as the user's latest message for the message field.";

const json = (body, status = 200, headers = {}) =>
  new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
      ...headers,
    },
  });

function sendEvent(controller, data) {
  controller.enqueue(new TextEncoder().encode(`data: ${JSON.stringify(data)}\n\n`));
}

// Supports either a JSON array secret or newline/comma-separated keys.
// Legacy single-key secrets remain supported.
function readKeys(env, pluralName, singleName) {
  const raw = String(env[pluralName] || env[singleName] || "").trim();
  if (!raw) return [];
  let values;
  try {
    const parsed = JSON.parse(raw);
    values = Array.isArray(parsed) ? parsed : [raw];
  } catch {
    values = raw.split(/[\n,]+/);
  }
  return [...new Set(values.map(v => String(v).trim()).filter(Boolean))]
    .slice(0, MAX_KEYS_PER_PROVIDER);
}

function getProviders(env) {
  return [
    {
      id: "groq",
      name: "Groq",
      keys: readKeys(env, "GROQ_API_KEYS", "GROQ_API_KEY"),
      models: [env.GROQ_MODEL, ...TEXT_MODELS].filter(Boolean),
      visionModels: [env.GROQ_VISION_MODEL || VISION_MODEL],
      searchModels: SEARCH_MODELS,
      url: GROQ_API,
    },
    {
      id: "gemini",
      name: "Gemini",
      keys: readKeys(env, "GEMINI_API_KEYS", "GEMINI_API_KEY"),
      models: [env.GEMINI_MODEL || "gemini-3.8-flash"],
      visionModels: [env.GEMINI_MODEL || "gemini-3.8-flash"],
      searchModels: [],
      url: GEMINI_API,
    },
    {
      id: "openrouter",
      name: "OpenRouter",
      keys: readKeys(env, "OPENROUTER_API_KEYS", "OPENROUTER_API_KEY"),
      models: [env.OPENROUTER_MODEL || "openrouter/free"],
      // openrouter/free selects a model supporting image input when images are sent.
      visionModels: [env.OPENROUTER_VISION_MODEL || "openrouter/free"],
      searchModels: [],
      url: OPENROUTER_API,
    },
  ];
}

function configuredProviders(env) {
  return getProviders(env).filter(p => p.keys.length);
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url);

    if (url.pathname === "/api/health") {
      const providers = getProviders(env).map(p => ({
        id: p.id,
        name: p.name,
        configured: p.keys.length > 0,
        keyCount: p.keys.length,
        primary: p.id === "groq",
      }));
      return json({
        ok: true,
        primaryProvider: "groq",
        fallbackOrder: ["gemini", "openrouter"],
        providers,
        textModels: TEXT_MODELS,
        visionModel: VISION_MODEL,
        searchModels: SEARCH_MODELS,
        maxImagesPerRequest: MAX_IMAGES,
        searchProvider: "Groq Browser Search (Groq keys required)",
        note: "Provider/model availability and free-tier limits depend on each provider account.",
      });
    }

    if (url.pathname === "/api/chat") {
      if (request.method !== "POST") return json({ error: "Method not allowed" }, 405);
      return handleChat(request, env);
    }

    if (url.pathname === "/api/generate-files") {
      if (request.method !== "POST") return json({ error: "Method not allowed" }, 405);
      return handleGenerateFiles(request, env);
    }

    if (env.ASSETS) return env.ASSETS.fetch(request);
    return new Response("Not found", { status: 404 });
  },
};

function validateMessages(body) {
  if (!body || !Array.isArray(body.messages) || !body.messages.length) {
    return { error: "لا توجد رسائل." };
  }

  const messages = body.messages
    .filter(m => m && (m.role === "user" || m.role === "assistant") &&
      (typeof m.content === "string" || Array.isArray(m.content)))
    .slice(-MAX_MESSAGES)
    .map(m => ({ role: m.role, content: m.content }));

  while (messages.length && messages[0].role !== "user") messages.shift();
  if (!messages.length || messages[messages.length - 1].role !== "user") {
    return { error: "يجب أن تنتهي المحادثة برسالة من المستخدم." };
  }

  let total = 0, imageCount = 0;
  for (const m of messages) {
    if (typeof m.content === "string") {
      total += m.content.length;
      continue;
    }
    if (m.role !== "user" || !Array.isArray(m.content)) {
      return { error: "تنسيق الرسالة غير صالح." };
    }

    for (const part of m.content) {
      if (part?.type === "text" && typeof part.text === "string") {
        total += part.text.length;
      } else if (part?.type === "image_url" && typeof part.image_url?.url === "string") {
        imageCount++;
        const src = part.image_url.url;
        if (!/^data:image\/(jpeg|jpg|png|webp|gif);base64,[a-z0-9+/=]+$/i.test(src)) {
          return { error: "صيغة الصورة غير مدعومة. ارفع JPG أو PNG أو WEBP." };
        }
        if (src.length > MAX_IMAGE_DATA_CHARS) {
          return { error: "حجم الصورة بعد تجهيزها كبير جدًا." };
        }
      } else {
        return { error: "محتوى مرفق غير صالح." };
      }
    }
  }

  if (total > MAX_CHARS) return { error: "المحادثة طويلة جدًا. ابدأ محادثة جديدة." };
  if (imageCount > MAX_IMAGES) {
    return { error: `يمكن تحليل ${MAX_IMAGES} صور كحد أقصى في الطلب الواحد.` };
  }
  return { messages, hasImages: imageCount > 0 };
}

function getRateHeaders(response) {
  const names = [
    "x-ratelimit-limit-requests", "x-ratelimit-limit-tokens",
    "x-ratelimit-remaining-requests", "x-ratelimit-remaining-tokens",
    "x-ratelimit-reset-requests", "x-ratelimit-reset-tokens", "retry-after",
  ];
  const out = {};
  for (const name of names) {
    const value = response.headers.get(name);
    if (value !== null) out[name] = value;
  }
  return out;
}

function novaHeaders(provider, model, response) {
  const headers = new Headers({
    "X-NOVA-Provider": provider,
    "X-NOVA-Model": model,
    "Access-Control-Expose-Headers": "X-NOVA-Provider, X-NOVA-Model, X-NOVA-Rate-Limits",
  });
  headers.set("X-NOVA-Rate-Limits", JSON.stringify(getRateHeaders(response)));
  return headers;
}

function buildPayload(model, messages, options, providerId) {
  const payload = {
    model,
    messages: [{ role: "system", content: options.systemPrompt || SYSTEM_PROMPT }, ...messages],
    stream: !!options.stream,
  };

  if (providerId === "groq") {
    payload.max_completion_tokens = options.maxTokens || 8192;
    if (options.temperature !== undefined) payload.temperature = options.temperature;
    if (options.search) {
      payload.tools = [{ type: "browser_search" }];
      payload.tool_choice = "required";
      payload.reasoning_effort = "low";
    } else if (options.reasoningEffort) {
      payload.reasoning_effort = options.reasoningEffort;
    }
  } else {
    // Gemini and OpenRouter use the OpenAI-compatible max_tokens field.
    payload.max_tokens = options.maxTokens || 8192;
    if (options.temperature !== undefined) payload.temperature = options.temperature;
  }
  return payload;
}

async function requestProvider(provider, model, key, messages, options = {}) {
  const payload = buildPayload(model, messages, options, provider.id);
  const headers = {
    "Content-Type": "application/json",
    "Authorization": `Bearer ${key}`,
  };
  if (provider.id === "openrouter") {
    headers["HTTP-Referer"] = "https://nova-ai.pages.dev";
    headers["X-Title"] = "NOVA AI";
  }

  return fetch(provider.url, {
    method: "POST",
    headers,
    body: JSON.stringify(payload),
  });
}

function modelCandidates(provider, hasImages, options = {}) {
  if (options.search) return provider.searchModels || [];
  if (provider.id === "groq" && options.think) {
    // Correct prefix: the model IDs use "gpt-oss-120b", not "gpt-oss/120b".
    return provider.models.filter(model => model.startsWith("openai/gpt-oss-"));
  }
  return hasImages ? provider.visionModels : provider.models;
}

async function selectUpstream(messages, env, options = {}) {
  const providers = configuredProviders(env);
  let lastStatus = 503;
  let lastDetails = "No configured provider keys.";

  // The order is intentional: Groq is always attempted before Gemini and OpenRouter.
  for (const provider of providers) {
    const models = modelCandidates(provider, !!options.hasImages, options);
    if (!models.length) continue;

    for (const model of models) {
      for (const key of provider.keys) {
        try {
          const response = await requestProvider(provider, model, key, messages, options);
          if (response.ok) return { response, model, provider: provider.id };

          lastStatus = response.status;
          lastDetails = await response.text().catch(() => "");
          console.error(
            `NOVA ${provider.id} model ${model} failed:`,
            response.status,
            lastDetails.slice(0, 500)
          );

          // A bad key may be followed by another configured key for this same provider.
          if ([401, 402, 403].includes(response.status)) continue;

          // These errors may be model-specific or temporary; try the next model/provider.
          if ([400, 404, 408, 413, 429, 500, 502, 503, 504].includes(response.status)) {
            break;
          }
          break;
        } catch (error) {
          console.error(`NOVA ${provider.id} connection failed:`, error);
          lastStatus = 502;
          lastDetails = String(error);
          break;
        }
      }

      // If this model failed, try another model in the same provider where available.
      if ([401, 402, 403].includes(lastStatus)) {
        // Try remaining keys/models, then continue to the next configured provider.
      }
    }
  }
  return { response: null, model: null, provider: null, lastStatus, lastDetails };
}

function searchSources(message) {
  const annotations = Array.isArray(message?.annotations) ? message.annotations : [];
  const found = new Map();
  for (const item of annotations) {
    const cite = item?.url_citation || item?.urlCitation || item;
    const url = typeof cite?.url === "string" ? cite.url : "";
    const title = typeof cite?.title === "string" ? cite.title : url;
    if (url.startsWith("https://") || url.startsWith("http://")) {
      found.set(url, title || url);
    }
  }
  return [...found.entries()].map(([url, title]) => ({ title, url })).slice(0, 10);
}

function appendSources(content, sources) {
  if (!sources.length) return content;
  const lines = sources.map(s =>
    `- [${s.title.replace(/[\[\]]/g, "")}](${s.url})`
  );
  return `${content}\n\n**المصادر:**\n${lines.join("\n")}`;
}

async function handleSearchChat(validated, body, env) {
  if (validated.hasImages) {
    return json({
      error: "البحث على الويب وتحليل الصور غير متاحين معًا في نفس الرسالة. أوقف البحث لتحليل الصورة.",
    }, 400);
  }

  const groq = getProviders(env).find(p => p.id === "groq");
  if (!groq?.keys.length) {
    return json({ error: "البحث يحتاج مفتاح Groq. أضف GROQ_API_KEY أو GROQ_API_KEYS." }, 503);
  }

  const avoid = new Set(Array.isArray(body.avoidModels) ? body.avoidModels : []);
  const models = SEARCH_MODELS.filter(m => !avoid.has(m));
  if (!models.length) {
    return json({ error: "موديلات البحث في فترة راحة مؤقتة. جرّب لاحقًا أو أوقف البحث." }, 429);
  }

  const chosen = await selectUpstream(validated.messages, env, {
    stream: false,
    search: true,
    maxTokens: 4096,
    temperature: 0.2,
    systemPrompt: SEARCH_SYSTEM_PROMPT,
  });

  if (!chosen.response) {
    if (chosen.lastStatus === 400) {
      return json({
        error: "Groq رفض طلب البحث. تأكد أن Browser Search متاح لموديل GPT-OSS في حسابك.",
      }, 502);
    }
    return providerError(chosen.lastStatus, chosen.provider || "groq");
  }

  try {
    const result = await chosen.response.json();
    const message = result.choices?.[0]?.message;
    const raw = message?.content;
    if (typeof raw !== "string" || !raw.trim()) {
      return json({ error: "البحث لم يُرجع إجابة." }, 502);
    }

    const sources = searchSources(message);
    const content = appendSources(raw, sources);
    const headers = novaHeaders(chosen.provider, chosen.model, chosen.response);
    headers.set("Content-Type", "text/event-stream; charset=utf-8");
    headers.set("Cache-Control", "no-cache, no-transform");
    headers.set("X-Accel-Buffering", "no");

    const stream = new ReadableStream({
      start(controller) {
        sendEvent(controller, { t: content });
        sendEvent(controller, {
          done: true,
          finish: result.choices?.[0]?.finish_reason || "stop",
          model: chosen.model,
          provider: chosen.provider,
          sources,
        });
        controller.close();
      },
    });
    return new Response(stream, { status: 200, headers });
  } catch (error) {
    console.error("Browser search response error:", error);
    return json({ error: "تعذرت قراءة نتيجة البحث من Groq." }, 502);
  }
}

async function handleChat(request, env) {
  let body;
  try {
    body = await request.json();
  } catch {
    return json({ error: "طلب JSON غير صالح." }, 400);
  }

  const validated = validateMessages(body);
  if (validated.error) return json({ error: validated.error }, 400);
  if (!configuredProviders(env).length) {
    return json({
      error: "لا توجد مفاتيح API. أضف GROQ_API_KEY أو GEMINI_API_KEY أو OPENROUTER_API_KEY في Cloudflare Secrets.",
    }, 500);
  }

  if (body.search === true) return handleSearchChat(validated, body, env);

  const think = body.think === true && !validated.hasImages;
  const chosen = await selectUpstream(validated.messages, env, {
    stream: true,
    hasImages: validated.hasImages,
    think,
    reasoningEffort: think ? "high" : undefined,
    maxTokens: 8192,
  });

  if (!chosen.response) return providerError(chosen.lastStatus, "available providers");

  const upstream = chosen.response;
  const selectedModel = chosen.model;
  const selectedProvider = chosen.provider;
  if (!upstream.body) return json({ error: "مزود الذكاء الاصطناعي لم يرجع مجرى بيانات." }, 502);

  console.log("NOVA selected provider/model:", selectedProvider, selectedModel, getRateHeaders(upstream));

  const headers = novaHeaders(selectedProvider, selectedModel, upstream);
  headers.set("Content-Type", "text/event-stream; charset=utf-8");
  headers.set("Cache-Control", "no-cache, no-transform");
  headers.set("X-Accel-Buffering", "no");

  const stream = new ReadableStream({
    async start(controller) {
      const reader = upstream.body.getReader();
      const decoder = new TextDecoder();
      let buffer = "", finish = null, closed = false;

      const close = () => {
        if (!closed) {
          closed = true;
          controller.close();
        }
      };
      const fail = message => {
        if (!closed) {
          sendEvent(controller, { error: message });
          close();
        }
      };
      const processLine = line => {
        line = line.trim();
        if (!line.startsWith("data:")) return;
        const raw = line.slice(5).trim();
        if (!raw || raw === "[DONE]") return;

        let chunk;
        try {
          chunk = JSON.parse(raw);
        } catch {
          return;
        }

        const choice = chunk.choices?.[0];
        const content = choice?.delta?.content;
        if (typeof content === "string" && content.length) sendEvent(controller, { t: content });
        if (choice?.finish_reason) finish = choice.finish_reason;
      };

      try {
        while (!closed) {
          const { done, value } = await reader.read();
          if (done) break;
          buffer += decoder.decode(value, { stream: true });
          const lines = buffer.split("\n");
          buffer = lines.pop() || "";
          for (const line of lines) processLine(line);
        }

        buffer += decoder.decode();
        if (buffer.trim()) processLine(buffer);
        sendEvent(controller, {
          done: true,
          finish: finish === "length" ? "MAX_TOKENS" : finish,
          model: selectedModel,
          provider: selectedProvider,
        });
        close();
      } catch (error) {
        console.error(`${selectedProvider} streaming error:`, error);
        fail("انقطع الاتصال أثناء استقبال الرد.");
      } finally {
        try { reader.releaseLock(); } catch {}
      }
    },
    async cancel() {
      try { await upstream.body.cancel(); } catch {}
    },
  });

  return new Response(stream, { status: 200, headers });
}

async function handleGenerateFiles(request, env) {
  let body;
  try {
    body = await request.json();
  } catch {
    return json({ error: "طلب JSON غير صالح." }, 400);
  }

  const validated = validateMessages(body);
  if (validated.error) return json({ error: validated.error }, 400);
  if (validated.hasImages) {
    return json({ error: "أوقف إرفاق الصور قبل طلب توليد الملفات." }, 400);
  }
  if (!configuredProviders(env).length) {
    return json({ error: "لا توجد مفاتيح API مضافة في Cloudflare Secrets." }, 500);
  }

  const chosen = await selectUpstream(validated.messages, env, {
    stream: false,
    maxTokens: 8192,
    temperature: 0.2,
    systemPrompt: FILES_SYSTEM_PROMPT,
  });
  if (!chosen.response) return providerError(chosen.lastStatus, "available providers");

  try {
    const result = await chosen.response.json();
    const raw = result.choices?.[0]?.message?.content;
    if (typeof raw !== "string" || !raw.trim()) {
      return json({ error: "النموذج لم يُرجع محتوى للملفات." }, 502);
    }

    let parsed;
    try {
      const cleaned = raw.replace(/^```(?:json)?\s*/i, "").replace(/\s*```$/, "").trim();
      const start = cleaned.indexOf("{");
      const end = cleaned.lastIndexOf("}");
      parsed = JSON.parse(start >= 0 && end > start ? cleaned.slice(start, end + 1) : cleaned);
    } catch (error) {
      console.error("Generated files JSON parse error:", error, raw.slice(0, 1000));
      return json({ error: "تعذر قراءة الملفات التي أنشأها النموذج. جرّب طلبًا أبسط." }, 502);
    }

    const files = normalizeGeneratedFiles(parsed.files);
    if (!files.length) return json({ error: "لم يتم إنشاء ملفات صالحة." }, 502);

    const rateLimits = getRateHeaders(chosen.response);
    return json({
      ok: true,
      message: typeof parsed.message === "string"
        ? parsed.message.slice(0, 3000)
        : "تم إنشاء الملفات المطلوبة. يمكنك تحميلها من الأسفل.",
      files,
      model: chosen.model,
      provider: chosen.provider,
      rateLimits,
    }, 200, {
      "X-NOVA-Provider": chosen.provider,
      "X-NOVA-Model": chosen.model,
      "X-NOVA-Rate-Limits": JSON.stringify(rateLimits),
    });
  } catch (error) {
    console.error("File generation response error:", error);
    return json({ error: "تعذر قراءة استجابة مزود الذكاء الاصطناعي." }, 502);
  }
}

function normalizeGeneratedFiles(input) {
  if (!Array.isArray(input)) return [];
  const files = [];
  let totalChars = 0;
  const usedNames = new Set();

  for (const item of input.slice(0, MAX_GENERATED_FILES)) {
    if (!item || typeof item.name !== "string" || typeof item.content !== "string") continue;

    let name = item.name.replace(/\\/g, "/").trim();
    name = name.split("/").filter(part => part && part !== "." && part !== "..").join("/");
    name = name.replace(/[<>:"|?*\u0000-\u001f]/g, "_").slice(0, 180);

    if (!name || item.content.length > MAX_GENERATED_FILE_CHARS) continue;
    if (totalChars + item.content.length > MAX_GENERATED_TOTAL_CHARS) break;

    let uniqueName = name;
    let suffix = 2;
    while (usedNames.has(uniqueName.toLowerCase())) {
      const dot = name.lastIndexOf(".");
      uniqueName = dot > 0
        ? name.slice(0, dot) + "-" + suffix++ + name.slice(dot)
        : name + "-" + suffix++;
    }

    usedNames.add(uniqueName.toLowerCase());
    totalChars += item.content.length;
    files.push({ name: uniqueName, content: item.content });
  }
  return files;
}

function providerError(status, provider) {
  if (status === 401) {
    return json({ error: `مفتاح API غير صالح لدى ${provider}. راجع Cloudflare Secrets.` }, 502);
  }
  if (status === 402) {
    return json({ error: `حساب ${provider} لا يملك رصيدًا أو أهلية استخدام كافية.` }, 502);
  }
  if (status === 403) {
    return json({ error: `حساب ${provider} لا يملك صلاحية استخدام هذا الموديل أو الخدمة.` }, 502);
  }
  if (status === 413) {
    return json({ error: "حجم الطلب كبير جدًا. قلل عدد الملفات أو الصور." }, 413);
  }
  if (status === 429) {
    return json({
      error: "وصلت كل الخدمات المتاحة إلى حدود الاستخدام المؤقت. جرّب لاحقًا.",
    }, 429);
  }
  return json({
    error: "تعذر تشغيل الخدمات المتاحة حاليًا. راجع إعدادات المفاتيح والموديلات ثم حاول مرة أخرى.",
  }, 502);
}
