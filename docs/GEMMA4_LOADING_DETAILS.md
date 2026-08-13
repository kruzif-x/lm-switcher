# Gemma 4 12B Loading Details for llama.cpp

This document is the authoritative reference for how LM Switcher loads
**Gemma 4 12B** and **Gemma 4 12B QAT** via `llama-server`. It covers the
exact command line, every argument, how the multimodal projection (mmproj)
encoder is loaded, how Multi-Token Prediction (MTP) heads are handled, and
why a custom Jinja chat template is required when using agentic harnesses
like opencode, pi, or OpenClaw.

The goal is that after reading this you understand not just *what* the app
does, but *why* and *what happens inside llama.cpp*.

---

## 1. Overview

When you click "Load Selected" (or run `llama load gemma-4-12b-it-qat-...`),
LM Switcher spawns one `llama-server` process per model. The process
inherits a carefully constructed argument vector that:

1. Points to the main GGUF model (`-m`)
2. Auto-pairs and attaches the multimodal projection GGUF (`--mmproj`) so
   the model can process images
3. Suppresses Gemma 4's `reasoning_content` field (`--reasoning off` and
   `--reasoning-format none`) so OpenAI-compatible clients do not break
4. Optionally overrides the built-in chat template (`--chat-template`)
   when running under an agentic harness

This document unpacks each of those flags and the *llama.cpp* machinery
behind them.

---

## 2. The Two Model Variants

There are two distributions you will commonly see in `~/models/gguf/`:

### 2.1 Gemma 4 12B IT (standard)

Released by Google and republished by community quantizers. Shipped as a
single self-contained GGUF plus a single mmproj:

```
gemma-4-12B-it-Q4_K_M.gguf          # the language model (4.0-bit quant)
mmproj-gemma-4-12B-it-Q8_0.gguf     # the vision encoder + projection
```

Naming follows the `<base>-<quant>` convention. The mmproj is named
`mmproj-<base>-<quant>.gguf`, so name-based auto-pairing works.

### 2.2 Gemma 4 12B IT QAT (Quantization-Aware Training)

Typically the **unsloth** QAT build. Two important differences from the
standard distribution:

1. The mmproj is named generically (`mmproj-BF16.gguf`) instead of
   `mmproj-gemma-4-12B-it-Q8_0.gguf`. LM Switcher's fallback matcher
   catches this.
2. A **Multi-Token Prediction (MTP) head** is included as a separate
   GGUF. This file is **not** a standalone model — `llama-server` reads
   a metadata reference in the main model and loads the MTP head
   automatically.

```
gemma-4-12B-it-qat-GGUF/
├── gemma-4-12B-it-qat-UD-Q4_K_XL.gguf   # main model (QAT-quantized)
├── mmproj-BF16.gguf                       # vision encoder (fallback match)
└── mtp-gemma-4-12B-it.gguf                # MTP head (auto-loaded)
```

The directory layout also commonly includes an optional custom chat
template for agentic use:

```
├── mmproj-BF16.gguf
├── mtp-gemma-4-12B-it.gguf
└── gemma4_chat_template.jinja             # optional; only for agentic harnesses
```

### 2.3 What is "QAT" exactly?

**Quantization-Aware Training** is a training-time technique: the model is
trained with simulated low-precision arithmetic in the forward pass, so
the final weights are calibrated to the target bit width. The result is
**better quality at the same bit rate** (e.g. Q4_K_XL from a QAT-trained
checkpoint often matches or beats a Q5_K_M from a post-training-quantized
checkpoint). From `llama-server`'s perspective the GGUF is loaded
identically — the QAT nature is baked into the tensor values. No special
flags are required.

---

## 3. The Exact `llama-server` Command Line

For the **standard** variant on `localhost:8080`, the constructed command
is:

```bash
llama-server \
    -m ~/models/gguf/gemma-4-12B-it-Q4_K_M.gguf \
    --mmproj ~/models/gguf/mmproj-gemma-4-12B-it-Q8_0.gguf \
    --host 127.0.0.1 \
    --port 8080 \
    --ctx-size 4096 \
    --reasoning off \
    --reasoning-format none
```

For the **QAT** variant with a custom chat template (agentic harness):

```bash
llama-server \
    -m ~/models/gguf/gemma-4-12B-it-qat-GGUF/gemma-4-12B-it-qat-UD-Q4_K_XL.gguf \
    --mmproj ~/models/gguf/gemma-4-12B-it-qat-GGUF/mmproj-BF16.gguf \
    --host 127.0.0.1 \
    --port 8080 \
    --ctx-size 4096 \
    --reasoning off \
    --reasoning-format none \
    --chat-template ~/models/gguf/gemma-4-12B-it-qat-GGUF/gemma4_chat_template.jinja
```

### 3.1 Flag-by-flag

| Flag | Purpose | Notes |
|------|---------|-------|
| `-m <path>` | Path to the main GGUF model | Loads the language-model tensors into RAM/VRAM. Gemma 4 uses the Gemma2 architecture in llama.cpp. |
| `--mmproj <path>` | Path to the multimodal projection GGUF | Loads the vision encoder + linear projection. See §4. |
| `--host 127.0.0.1` | Bind to loopback | Security + convenience. Prevents LAN exposure. |
| `--port <n>` | HTTP port for the OpenAI-compatible API | Per-model; default 8080, increments for additional models. |
| `--ctx-size <n>` | Context window in tokens | Per-model; default 4096. |
| `--reasoning off` | Disable the `reasoning_content` field | See §3.2. **Required for Gemma 4.** |
| `--reasoning-format none` | Suppress reasoning tokens in stream | See §3.2. **Required for Gemma 4.** |
| `--chat-template <file>` | Custom Jinja template (optional) | See §7. Only for agentic use. |

### 3.2 Why `--reasoning off --reasoning-format none` is required

Gemma 4 was trained to emit chain-of-thought reasoning in a separate
output field called `reasoning_content` (analogous to DeepSeek-R1's
`reasoning_content` field). The behavior is:

- `llama-server` exposes this in the OpenAI-compatible response as an
  extra `reasoning_content` field on chat completion responses.
- Most OpenAI-compatible clients (including opencode, pi, OpenClaw,
  Continue, Cursor's local mode) **strictly validate** the response
  schema and either:
  - Silently drop the unknown `reasoning_content` field
  - Throw a parse error because the field is unexpected
  - Get confused about which field is the actual response text

The fix is two flags:

- `--reasoning off` tells llama-server **not to extract** the chain of
  thought into a separate field — it stays embedded in `content`.
- `--reasoning-format none` tells llama-server **not to stream**
  reasoning tokens in the SSE event stream.

Without these flags, Gemma 4 outputs reasoning content and OpenAI
clients break. **Both LM Switcher's CLI and Swift app now apply these
flags automatically when launching a model.** This brings it in line
with the companion `LocalLLMToggle` project.

### 3.3 Per-model overrides

All flags above can be overridden per model. LM Switcher reads per-model
`port` and `ctx-size` from `~/Library/Preferences/local.llama-menubar.plist`:

```bash
llama port gemma 9000     # sets model.<hash>.port = 9000
llama ctx  gemma 8192     # sets model.<hash>.ctx  = 8192
```

`--reasoning off`, `--reasoning-format none`, and `--mmproj` are
applied by default, but **reasoning suppression is now per-model
overridable** (Settings → Per-Model → Suppress reasoning, or
`model.<hash>.suppressReasoning`). Keep it ON for Gemma 4 models and
turn it OFF for **Muse Glimmer**: with suppression active, Muse's
thinking protocol leaks raw into content (`to=self<|message|>…`
garbage) and the DFlash drafter's acceptance collapses. Custom chat
templates are configured via the **Global** settings tab and apply to
every model loaded.

---

## 4. How the Multimodal Projection (mmproj) Encoder Works

### 4.1 What is inside the mmproj GGUF

Gemma 4 uses a **SigLIP** vision encoder (the same family used by
PaliGemma and Gemma 3) plus a learned linear projection that maps
vision features into the language model's embedding space.

- SigLIP output dimension: **1152**
- Gemma 4 hidden dimension: **4608**
- The projection GGUF therefore contains a `[1152, 4608]` linear layer
  (plus biases and a possible layernorm).

The mmproj GGUF is a separate file because:

1. The vision encoder can be shared across multiple language model
   versions (different quantizations of the same base).
2. Users who only need text inference can skip downloading the vision
   encoder entirely (~400 MB savings on a 4-bit quant).

### 4.2 How `llama-server` loads it

When `llama-server` starts with `--mmproj <path>`, the following
happens (see `llama.cpp/src/llama.cpp` and `llama-mmproj.cpp`):

1. `llama_model_load()` is called for the main GGUF. The model's
   `n_layer`, `n_embd`, `n_head` etc. are read.
2. After the main model is loaded, `llama_model_load_mmproj()` is
   called for the mmproj path. This:
   - Reads the mmproj GGUF header to determine its type (CLIP / SigLIP
     / custom).
   - Allocates buffers for the vision encoder tensors and the
     projection layer.
   - GPU-offloads both the encoder and the projection if `--n-gpu-layers`
     is high enough (default: all).
3. The vision encoder is **kept in memory** for the lifetime of the
   process. Image inputs in chat requests are preprocessed (resize to
   896×896, normalize, patch-embed), run through the encoder, and the
   resulting 1152-dim feature vectors are projected into 4608-dim
   embeddings that are concatenated with text token embeddings.

### 4.3 Inference data path for an image

```
User uploads image (multipart) or sends data URL
        |
        v
llama-server image preprocessing
   (resize 896x896, normalize, patch)
        |
        v
SigLIP vision encoder (mmproj GGUF)
   -> 1152-dim features per patch
        |
        v
Linear projection [1152, 4608] (mmproj GGUF)
   -> 4608-dim features matching Gemma 4 embeddings
        |
        v
Concatenate with text token embeddings
        |
        v
Standard transformer forward pass
```

### 4.4 Auto-pairing algorithm

LM Switcher auto-discovers the mmproj in the same directory as the
model. The same algorithm is used by both the Swift app
(`findCompanion(for:prefix:)` in `src/LlamaMenubarApp.swift:1556`) and
the bash CLI (`src/llama:354-370`).

**Step 1 — Name-based matching:**

1. Take the model's basename without the `.gguf` extension.
2. Strip common quantization suffixes: `-Q4_K_M`, `-Q4_K_S`,
   `-Q5_K_M`, `-Q5_K_S`, `-Q6_K`, `-Q8_0`.
3. Look for `mmproj-<stripped>-*.gguf` in the same directory.
4. If exactly one match, use it.

**Step 2 — Fallback matching:**

If no name-based match is found, scan the directory for **any**
`mmproj-*.gguf`. If exactly one exists, use it. If multiple exist,
pick the alphabetically first one.

**Worked example 1 (standard naming — Step 1 matches):**

```
~/models/gguf/
├── gemma-4-12B-it-Q4_K_M.gguf          # model
└── mmproj-gemma-4-12B-it-Q8_0.gguf     # matched by name
```

`gemma-4-12B-it-Q4_K_M` → strip `-Q4_K_M` → `gemma-4-12B-it` → look
for `mmproj-gemma-4-12B-it-*.gguf` → found.

**Worked example 2 (QAT naming — Step 2 fallback):**

```
~/models/gguf/gemma-4-12B-it-qat-GGUF/
├── gemma-4-12B-it-qat-UD-Q4_K_XL.gguf
├── mmproj-BF16.gguf
└── mtp-gemma-4-12B-it.gguf
```

`gemma-4-12B-it-qat-UD-Q4_K_XL` → strip quantization → `gemma-4-12B-it-qat-UD`.
Look for `mmproj-gemma-4-12B-it-qat-UD-*.gguf` → not found. Fallback:
scan for any `mmproj-*.gguf` → `mmproj-BF16.gguf` found → use it.

---

## 5. How Multi-Token Prediction (MTP) Is Handled

### 5.1 What MTP is

**Multi-Token Prediction** is an inference optimization where a model
predicts multiple future tokens per forward pass. The architecture is:

- The main language model produces its standard next-token distribution
  for position `t`.
- A separate, smaller **MTP head** (a lightweight transformer with
  significantly fewer layers) consumes the main model's hidden state at
  position `t` and produces a parallel prediction for position `t+1`
  (or `t+1` and `t+2` depending on the configuration).

The motivation is **throughput**: speculatively pre-computing the next
token lets the inference loop skip a forward pass when the speculation
is correct (the typical case for predictable text).

In the unsloth QAT Gemma 4 build, the MTP head is shipped as a
**separate GGUF file** alongside the main model:

```
gemma-4-12B-it-qat-UD-Q4_K_XL.gguf
mtp-gemma-4-12B-it.gguf                 <-- the MTP head
```

### 5.2 How llama.cpp loads it (no `--mtp` flag needed)

Crucially, the MTP head is **not** loaded via a command-line flag. The
loading sequence is:

1. `llama_model_load()` parses the main model's GGUF metadata.
2. If a metadata key references an MTP head filename (the field is
   something like `clip.vision.mtp_model` or `llama.mtp_model` depending
   on llama.cpp version; in recent builds the main model's GGUF
   metadata stores the relative path to the companion MTP head), the
   loader resolves the path **relative to the main model's directory**.
3. The MTP head GGUF is opened, parsed, and its tensors are
   GPU-offloaded alongside the main model.
4. At inference time, the main model's forward pass calls
   `llama_mtp_eval()` which invokes the head for speculative decoding.

The two practical consequences are:

- The MTP head must live in the **same directory** as the main model
  (because the path is resolved relative to `-m`).
- It is silently ignored if the path is wrong or the file is missing
  (the model still works without MTP, just slower).

### 5.3 Why LM Switcher excludes `mtp-*.gguf` from the model list

If the MTP head appeared as a clickable "model" in the menu, a user
would try to load it directly:

```bash
llama-server -m mtp-gemma-4-12B-it.gguf
```

This fails with a confusing error like "unknown architecture" or
"missing config" because the MTP head is **not a self-contained
model** — it has no tokenizer, no embedding table, no final output
projection. It only contains the extra transformer layers used for
speculative decoding.

**Exclusion rule:** any `.gguf` file whose basename starts with the
prefix `mtp-` is excluded from the model list. Files with `-mtp-` as
an **infix** are **not** excluded (e.g. `gemma-3-mtp-Q4_K_M.gguf` is
a real standalone model that happens to have "mtp" in its name).

This is implemented as a glob in `src/llama:143`:

```bash
case "$bn" in
    mmproj-*|mtp-*|modernbert-embed-*) continue ;;
esac
```

And equivalently in `src/LlamaMenubarApp.swift` (model discovery logic).

### 5.4 Verifying MTP is loaded

Three ways to confirm the MTP head is actually loaded:

1. **Server startup log** — llama-server prints a line like:
   ```
   llama_model_loader: - type  f32:  256 tensors
   llama_model_loader: - type q4_K:  644 tensors
   llm_load_tensors: MTP head loaded from mtp-gemma-4-12B-it.gguf
   ```
2. **Metrics endpoint** — `curl http://127.0.0.1:8080/metrics` may
   include `mtp_speculative_tokens_total` and `mtp_accepted_tokens_total`
   counters once a few requests have been served.
3. **Inspect the GGUF metadata directly:**
   ```bash
   python3 -c "
   import gguf
   r = gguf.GGUFReader('gemma-4-12B-it-qat-UD-Q4_K_XL.gguf')
   for k, v in r.fields.items():
       if 'mtp' in k.lower(): print(k, '=', v.parts[v.data[0]])
   "
   ```
   Look for keys like `clip.vision.mtp_model` or `llama.mtp_model`
   referencing the MTP head filename.

---

## 6. QAT vs Standard: What's Different Under the Hood

| Aspect | Standard (post-training quant) | QAT (unsloth) |
|--------|--------------------------------|---------------|
| Training | Standard training, then quantize weights | Training-time simulation of low precision |
| Bit rate / quality | Q5_K_M ≈ Q4_K_XL | Q4_K_XL often matches or beats Q5_K_M from a standard quant |
| mmproj name | `mmproj-<model>-<quant>.gguf` | Often `mmproj-BF16.gguf` (generic) |
| MTP head included? | No | Yes (separate `mtp-*.gguf`) |
| Custom chat template included? | Sometimes | Often |
| File naming for main model | `gemma-4-12B-it-Q4_K_M.gguf` | `gemma-4-12B-it-qat-UD-Q4_K_XL.gguf` (note `-qat-UD-` infix) |
| Loading with llama-server | Identical | Identical |

### 6.1 Approximate VRAM and throughput

Numbers below are ballpark for an M2 Pro / M3 Max / RTX 4090 with a 4096
context window and a single concurrent request. They are **hardware
and quantization dependent** — use them as a rough guide only.

| Model | Quant | VRAM (M2 Pro) | tok/s (prompt) | tok/s (gen) |
|-------|-------|---------------|----------------|-------------|
| Gemma 4 12B IT | Q4_K_M | ~9 GB | ~1200 | ~25 |
| Gemma 4 12B IT QAT | Q4_K_XL | ~9 GB | ~1250 | ~26 |
| Gemma 4 12B IT | Q8_0 | ~14 GB | ~1100 | ~18 |

The QAT build at the same bit rate is roughly 5-10% faster because the
quantized weights decode more efficiently on Apple Silicon and CUDA
tensor cores. The vision encoder adds a fixed ~400 MB to VRAM and
~50 ms to the first image of each request.

### 6.2 Why no special flags are needed for QAT

The QAT technique only changes the *weight values* in the GGUF. The
tensor shapes, layer types, and metadata schema are identical to a
post-training quant of the same architecture. `llama-server` loads both
files through the same `ggml`-backend code path. From its perspective,
the file is just tensors with quantization type identifiers
(`Q4_K_XL` is a valid type the loader already supports).

---

## 7. Chat Template Deep-Dive

This is the most important section for anyone using Gemma 4 with an
agentic coding harness. Read carefully.

### 7.1 What a chat template is

A chat template is a **Jinja2** string stored in the GGUF's
`tokenizer.chat_template` metadata field. `llama-server` evaluates this
template on every chat completion request to convert the API request
(the OpenAI-style `messages` array and optional `tools` array) into the
exact prompt format the model was trained to consume.

The template controls:

- How `<start_of_turn>` / `<end_of_turn>` special tokens wrap each
  message.
- How system messages are prepended.
- How user/assistant roles are labelled.
- How `tools` definitions are converted into the model's native
  tool-calling format.
- How model-generated `tool_calls` are extracted back out of the
  generated text into OpenAI's `tool_calls` JSON structure.

### 7.2 Normal chat / web UI — no custom template needed

If you use Gemma 4 through **Open WebUI, Ollama WebUI, SillyTavern, or
a similar chat frontend**, the request looks like:

```json
{
  "messages": [
    {"role": "user", "content": "Hello!"},
    {"role": "assistant", "content": "Hi there."}
  ]
}
```

There is no `tools` field. The built-in Gemma 4 template handles this
correctly. **Do not point `--chat-template` at the agentic
`gemma4_chat_template.jinja` for normal chat** — the custom template
may use slightly different tokenization or omit special tokens that
the model expects in non-tool contexts, leading to degraded
conversational quality or tokenization warnings in the server log.

### 7.3 Agentic harnesses — why the built-in template breaks

Agentic coding tools like **opencode, pi, OpenClaw, Continue, and
Cursor's local mode** send OpenAI-compatible requests that include a
`tools` array:

```json
{
  "messages": [{"role": "user", "content": "What's the weather in Tokyo?"}],
  "tools": [
    {
      "type": "function",
      "function": {
        "name": "get_weather",
        "description": "Get current weather",
        "parameters": {
          "type": "object",
          "properties": {"city": {"type": "string"}},
          "required": ["city"]
        }
      }
    }
  ],
  "tool_choice": "auto"
}
```

`llama-server` calls the Jinja template to convert this `tools` array
into the model's native tool-call format. Gemma 4's built-in template
has **four bugs** that only surface during multi-turn tool calling:

| # | Bug | Symptom in the model output |
|---|-----|-----------------------------|
| 1 | **Broken tool call arguments** | When the harness sends `arguments` as a JSON string (common with the Vercel AI SDK), the template wraps it in extra braces, producing invalid output like `call:get_weather{{"city":"Tokyo"}}` |
| 2 | **Dropped reasoning** | After 3-4 turns of tool use, the model's prior reasoning is stripped from history, causing subsequent tool calls to collapse to `arguments: {}` |
| 3 | **Thinking disabled** | `enable_thinking` defaults to `false` in the standard template, and OpenAI-compatible adapters drop unknown fields, so thinking never activates |
| 4 | **Null corruption** | `null` values in tool parameters render as the Python string `"None"` instead of JSON `null`, causing the downstream tool to receive `"None"` and crash |

A fixed `gemma4_chat_template.jinja` patches all four.

### 7.4 Why Hermes and OpenClaw work fine with built-in templates

It's important to understand: **the bugs above are specific to Gemma 4's
built-in template.** They are not a property of tool calling in general
or of the OpenAI API.

- **Hermes** (NousResearch, e.g. Hermes 3): the model was fine-tuned
  with a carefully tested function-calling format, and the GGUF
  ships with a chat template that has been validated against the
  actual training data. Tool calls round-trip cleanly. **Use the
  built-in template. Do not override `--chat-template` for Hermes.**

- **OpenClaw** (and any agent that uses Qwen, Command R, Llama 3.1
  Instruct, Mistral, etc.): the same applies — the model was trained
  with a working tool-calling template and the GGUF ships that
  template. The harness sends `tools` → the template formats them
  correctly → the model emits valid `tool_calls` → the harness
  receives them.

  The combination of **Gemma 4 + any agentic harness** is uniquely
  broken because Gemma 4's built-in template is the only one with all
  four bugs above.

### 7.5 The full `gemma4_chat_template.jinja` (annotated)

The custom template is just the built-in Gemma 4 template with four
targeted patches. Below is an annotated walkthrough of the structure
(do not copy this verbatim — your `gemma4_chat_template.jinja` is the
authoritative source):

```jinja
{# === BUG 4 FIX: render None as JSON null, not Python string === #}
{# The built-in template uses `tojson` which is correct, but the
   place where tool parameters get injected used `{{ value }}` which
   renders None as the empty string. The fix is to use `tojson` for
   every value that can be null. #}

{% for message in messages %}
  {% if message.role == "system" %}
    <start_of_turn>system
    {{ message.content }}<end_of_turn>
  {% elif message.role == "user" %}
    <start_of_turn>user
    {{ message.content }}<end_of_turn>
  {% elif message.role == "assistant" %}
    <start_of_turn>model
    {{ message.content }}
    {# === BUG 2 FIX: emit reasoning inline, do not strip from history === #}
    {% if message.reasoning_content %}
      {{ message.reasoning_content }}
    {% endif %}
    {% if message.tool_calls %}
      {# === BUG 1 FIX: emit arguments as JSON, not double-braced === #}
      {% for call in message.tool_calls %}
        call:{{ call.function.name }}{{ call.function.arguments | tojson }}
      {% endfor %}
    {% endif %}
    <end_of_turn>
  {% elif message.role == "tool" %}
    <start_of_turn>tool
    {{ message.content }}<end_of_turn>
  {% endif %}
{% endfor %}

{# === BUG 3 FIX: emit enable_thinking=true at the end so it
   survives OpenAI adapter field filtering === #}
{% if add_generation_prompt %}
  <start_of_turn>model
  enable_thinking=true
  {# Tool definitions go here #}
  {% for tool in tools %}
    {{ tool.function.name }}: {{ tool.function.description }}
    args: {{ tool.function.parameters | tojson }}
  {% endfor %}
{% endif %}
```

The four annotations above correspond to the four bugs in §7.3.

### 7.6 When to use / not use a custom template

| Use case | Template to use | Why |
|----------|-----------------|-----|
| Gemma 4 in Open WebUI / Ollama WebUI | Built-in (leave `--chat-template` empty) | No tool calls → no bugs → built-in works perfectly |
| Gemma 4 in SillyTavern / roleplay UI | Built-in | Same as above |
| Gemma 4 via opencode / pi / OpenClaw | **Custom `gemma4_chat_template.jinja`** | Fixes the 4 tool-calling bugs |
| Hermes 3 in opencode / pi / OpenClaw | Built-in | Hermes template was validated against the training data |
| Qwen 2.5 / 3 in opencode / pi / OpenClaw | Built-in | Qwen templates are correct |
| Command R+ in OpenClaw | Built-in | Command R template is correct |
| Llama 3.1 / 3.3 Instruct in any harness | Built-in | Works |
| Mistral / Mixtral in any harness | Built-in | Works |
| Any model + curl / API testing (no tools) | Built-in | No tool calls = no bug |

**Rule of thumb:** the only `(model, harness)` combination that needs a
custom template is **Gemma 4 + any agentic harness**. Every other
combination works with the model's built-in template.

### 7.7 How `--chat-template` overrides the built-in

When you pass `--chat-template <file>`, `llama-server`:

1. Ignores the GGUF's `tokenizer.chat_template` metadata entirely.
2. Loads the contents of `<file>` as a Jinja2 template string.
3. Caches the parsed AST for the lifetime of the process.

The template receives the same variables the built-in one would:
`messages`, `tools`, `add_generation_prompt`, `bos_token`, `eos_token`,
etc. The custom template is responsible for emitting the same special
tokens (`<start_of_turn>`, `<end_of_turn>`) the model expects.

If the custom template emits **different special tokens** from what the
model's tokenizer knows, you will see errors like
`tokenizer encoding error: unknown token '<|im_start|>'` in the server
log. The Gemma 4 custom template MUST use `<start_of_turn>` and
`<end_of_turn>`, not Llama 3's `<|start_header_id|>` or ChatML's
`<|im_start|>`.

---

## 8. Manual Verification Steps

After starting a Gemma 4 model with LM Switcher, run these to confirm
everything is correctly loaded:

### 8.1 Check the server startup log

```bash
tail -f ~/.local/share/llama-menubar/logs/gemma-4-12B-it-Q4_K_M.gguf.log
```

Look for these lines (order may vary):

```
llama_model_loader: - type   f32:  ...
llama_model_loader: - type  q4_K:  ...
llm_load_tensors:              CPU buffer size =  ...
llm_load_tensors:              CUDA buffer size =  ...   # (or Metal)
llm_load_tensors:              MTP head loaded from mtp-gemma-4-12B-it.gguf
llama_new_context_with_model:  n_ctx = 4096
llama_new_context_with_model:  n_threads = ...
main:                          server listening on 127.0.0.1:8080
```

**Pass criteria:**

- A line mentioning MTP head loaded (if your build includes one)
- A line mentioning mmproj / vision encoder (if your model has one)
- `server listening` on the expected port
- No `error` or `failed` lines

### 8.2 Check `/v1/models` endpoint

```bash
curl -s http://127.0.0.1:8080/v1/models | python3 -m json.tool
```

Should return:

```json
{
  "object": "list",
  "data": [
    {
      "id": "gemma-4-12b-it-qat-UD-Q4_K_XL.gguf",
      "object": "model",
      "created": ...,
      "owned_by": "llamacpp"
    }
  ]
}
```

### 8.3 Test vision (mmproj) is functional

```bash
# Use any small PNG
curl -s http://127.0.0.1:8080/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{
      "messages": [
        {"role": "user", "content": [
          {"type": "text", "text": "What is in this image?"},
          {"type": "image_url", "image_url": {"url": "data:image/png;base64,..."}}
        ]}
      ],
      "max_tokens": 100
    }'
```

If mmproj is not loaded, you'll get a 400 error like "image input
requires --mmproj". If it is loaded, you'll get a normal completion.

### 8.4 Inspect GGUF metadata for MTP reference

```bash
python3 -c "
import gguf
r = gguf.GGUFReader('gemma-4-12B-it-qat-UD-Q4_K_XL.gguf')
for k, v in r.fields.items():
    if any(s in k.lower() for s in ['mtp', 'mmproj', 'clip', 'vision']):
        print(k, '=', v.parts[v.data[0]] if v.data else '<empty>')
"
```

You should see metadata fields referencing the companion files.

### 8.5 Confirm reasoning is suppressed

```bash
curl -s http://127.0.0.1:8080/v1/chat/completions \
    -H "Content-Type: application/json" \
    -d '{
      "messages": [{"role": "user", "content": "What is 2+2?"}],
      "max_tokens": 50
    }' | python3 -m json.tool
```

The response should **not** contain a `reasoning_content` field. If it
does, the `--reasoning off` flag is not being applied.

---

## Appendix A: Quick Reference

### A.1 All flags used by LM Switcher when loading Gemma 4

| Flag | Value source | User-overridable? |
|------|--------------|-------------------|
| `-m` | Discovered model path | No |
| `--mmproj` | Auto-paired from same dir | No |
| `--host` | Hardcoded `127.0.0.1` | No |
| `--port` | Per-model override or `defaultPort` | Yes (`llama port`) |
| `--ctx-size` | Per-model override or `defaultCtxSize` | Yes (`llama ctx`) |
| `--reasoning` | Hardcoded `off` | No |
| `--reasoning-format` | Hardcoded `none` | No |
| `--chat-template` | `chatTemplatePath` setting or env | Yes (Settings → Global) |
| *(anything in `globalExtraArgs`)* | User-defined | Yes (Settings → Global) |

### A.2 Environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `LLAMA_MODELS_DIR` | `~/models` | Root of recursive model scan |
| `LLAMA_PORT` | `8080` | Base port for auto-assignment |
| `LLAMA_CTX_SIZE` | `4096` | Default context window |
| `LLAMA_EXTRA_ARGS` | `""` | Whitespace-separated extra flags |
| `LLAMA_SERVER` | `/opt/homebrew/bin/llama-server` | Path to backend binary |
| `MLX_SERVER` | `~/Library/Python/3.14/bin/mlx_lm.server` | Path to MLX backend |
| `LLAMA_CHAT_TEMPLATE` | `""` | Optional `.jinja` path (CLI only) |

### A.3 Source-of-truth files in this repo

| File | What it does |
|------|--------------|
| `src/LlamaMenubarApp.swift:1370-1409` | Swift model-loading code (constructs `args` array) |
| `src/LlamaMenubarApp.swift:1556-1588` | `findCompanion(for:prefix:)` mmproj auto-pairing |
| `src/llama:349-385` | Bash CLI model-loading code (constructs `args` array) |
| `src/llama:354-370` | Bash mmproj auto-pairing logic |
| `src/llama:143` | File exclusion (mtp, mmproj, modernbert-embed prefixes) |
| `docs/ARCHITECTURE.md` | High-level component diagram |
| `docs/STATE.md` | Where state lives on disk |

### A.4 External references

- `llama.cpp` source: [github.com/ggerganov/llama.cpp](https://github.com/ggerganov/llama.cpp)
- `llama-server` flags: `llama-server --help`
- Gemma 4 model card: [huggingface.co/google](https://huggingface.co/google)
- unsloth QAT build: [huggingface.co/unsloth](https://huggingface.co/unsloth)
- opencode: [opencode.ai](https://opencode.ai)
- OpenClaw: [github.com/openclaw/openclaw](https://github.com/openclaw/openclaw)
