# Tubie

A minimal agent composition library in Elixir. Inspired by [PocketFlow](https://github.com/The-Pocket/PocketFlow).

**Core idea:** An agent is any function `State -> State`. Combinators compose agents into larger agents. That's the whole framework.

- **Minimal** — zero dependencies, ~200 lines of code.
- **Agent-friendly** — small enough for an AI agent to read, modify, and build on.

## Installation

```elixir
def deps do
  [{:tubie, "~> 0.1.0"}]
end
```

Or in a script:

```elixir
Mix.install([{:tubie, "~> 0.1.0"}])
```

## State

`Tubie.State` is a map-like accumulator with a `status` field (`:ok`, `:halt`, or `{:error, reason}`) that controls flow:

```elixir
state = Tubie.State.new(%{messages: []})
state = Tubie.State.put(state, :name, "Alice")
Tubie.State.get(state, :name)  # => "Alice"
```

## Combinators

Every combinator takes agents and returns a new agent. Most are pipeable.

| Combinator | What it does |
|---|---|
| `sequence([a, b, c])` | Run left-to-right, early exit on halt/error |
| `and_then(a, b)` | Pipeable sequence of two |
| `branch(classifier, table)` | Dispatch based on state |
| `loop(a, max: n)` | Repeat until halt or max iterations |
| `fan_out([a, b], as: key)` | Run concurrently, collect results under `key` |
| `fan_out([a, b])` | Run concurrently, fire-and-forget |
| `with_retry(a, max: n)` | Retry on error with optional backoff |
| `with_fallback(a, handler)` | Rescue exceptions |

## Examples

Each example demonstrates a different [design pattern](https://the-pocket.github.io/PocketFlow/design_pattern/) using Tubie's combinators. All examples auto-detect your LLM provider from env vars (`OPENAI_API_KEY` or `DEEPSEEK_API_KEY`).

```bash
OPENAI_API_KEY=sk-... elixir examples/tool_calling.exs
# or
DEEPSEEK_API_KEY=... elixir examples/rag.exs
```

| Example | Pattern | Key Combinators |
|---|---|---|
| [tool_calling.exs](examples/tool_calling.exs) | Tool Use | `branch`, `loop`, `with_retry`, `with_fallback` |
| [rag.exs](examples/rag.exs) | RAG | `sequence` |
| [map_reduce.exs](examples/map_reduce.exs) | Map-Reduce | `fan_out`, `and_then` |
| [structured_output.exs](examples/structured_output.exs) | Structured Output | `sequence`, `with_retry`, `with_fallback` |
| [taboo.exs](examples/taboo.exs) | Multi-Agent (Taboo Game) | `fan_out`, `loop`, message queues |

### Agent + Tool Use

An LLM agent that calls tools in a loop until it has a final answer:

```elixir
weather_agent =
  call_llm
  |> Tubie.with_retry(max: 3, wait: 1_000)
  |> Tubie.with_fallback(fn state, e ->
    Tubie.State.error(state, Exception.message(e))
  end)
  |> Tubie.branch(has_tool_calls?, %{
    tools: execute_tools,
    done:  &Tubie.State.halt/1
  })
  |> Tubie.loop(max: 10)
```

### RAG

Retrieve relevant chunks, then generate an answer:

```elixir
rag = Tubie.sequence([retrieve, generate])
```

### Map-Reduce

Summarize sections in parallel, then merge:

```elixir
summarizer =
  Tubie.fan_out(map_agents, as: :partials)
  |> Tubie.and_then(reduce)
```

### Structured Output

Extract structured YAML, validate, retry on failure:

```elixir
extractor =
  Tubie.sequence([extract, parse, validate])
  |> Tubie.with_retry(max: 3, wait: 500)
  |> Tubie.with_fallback(fn state, e ->
    Tubie.State.error(state, Exception.message(e))
  end)
```

### Multi-Agent (Taboo Game)

Two LLM agents run concurrently via `fan_out`, each in its own `loop`, communicating through message queues:

```elixir
hinter_agent = Tubie.loop(fn state ->
  msg = MQ.recv_msg(hinter_inbox)        # block until message
  clue = generate_clue(state, msg)
  MQ.send_msg(guesser_inbox, {:clue, clue})  # send to other agent
  state
end, max: 5)

guesser_agent = Tubie.loop(fn state ->
  {:clue, clue} = MQ.recv_msg(guesser_inbox)
  guess = generate_guess(state, clue)
  if correct?(guess), do: MQ.send_msg(hinter_inbox, :done)
  state
end, max: 5)

taboo_game = Tubie.fan_out([hinter_agent, guesser_agent])
```

## License

MIT
