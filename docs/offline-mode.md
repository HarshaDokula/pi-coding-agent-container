# Offline mode (llama.cpp)

> **Purpose:** Set up a local llama.cpp/Ollama-style model server and run without a cloud provider.
>
> Back to [README](../README.md) · [documentation index](README.md).


To run the agent completely offline using local models, configure the following files in your `.pi-data/agent/` directory:

**.pi-data/agent/models.json**
```json
{
  "providers": {
    "llama-cpp": {
      "baseUrl": "http://127.0.0.1:1337/v1",
      "api": "openai-completions",
      "apiKey": "none",
      "models": [
        {
          "id": "gemma-4-26B-A4B-it-GGUF"
        }
      ]
    }
  }
}
```

**.pi-data/agent/settings.json**
```json
{
  "defaultProvider": "llama-cpp",
  "defaultModel": "gemma-4-26B-A4B-it-GGUF",
  "autocompleteMaxVisible": 7,
  "defaultThinkingLevel": "off"
}
```

> **Run with `EGRESS=false` when the model server is on the host.** The egress
> mode puts the container on an `internal: true` network with no route to the
> host, so a llama.cpp/Ollama/LM Studio server listening on the host is
> unreachable even though the URL says `127.0.0.1`. Either disable the proxy for
> that session (`pictl --no-egress`) or run the server in a container on the same
> network. A server *inside* the agent container keeps working with egress on,
> because `127.0.0.1` is in `NO_PROXY`.

---

---
