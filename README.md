# Tubie

A minimal agent composition library in Elixir. Inspired by [PocketFlow](https://github.com/The-Pocket/PocketFlow).

**Core idea:** An agent is any function `State -> State`. Combinators compose agents into larger agents. That's the whole framework.

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

Every combinator takes agents and returns a new agent. All are pipeable.

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

### LLM tool-calling loop

```elixir
weather_agent =
  call_llm
  |> Tubie.with_retry(max: 3, wait: 1_000)
  |> Tubie.with_fallback(fn state, e ->
    Tubie.State.error(state, Exception.message(e))
  end)
  |> Tubie.and_then(
    Tubie.branch(has_tool_calls?, %{
      tools: execute_tools,
      done:  &Tubie.State.halt/1
    })
  )
  |> Tubie.loop(max: 10)
```

### Concurrent fan-out with merge

```elixir
fetch_weather = fn label ->
  fn state ->
    loc = Tubie.State.get(state, :location)
    temp = Enum.random(50..95)
    Tubie.State.put(state, :temp, temp)
  end
end

average_temps = fn state ->
  [a, b] = Tubie.State.get(state, :readings)
  avg = div(Tubie.State.get(a, :temp) + Tubie.State.get(b, :temp), 2)
  Tubie.State.put(state, :avg_temp, avg)
end

Tubie.fan_out([fetch_weather.("A"), fetch_weather.("B")], as: :readings)
|> Tubie.and_then(average_temps)
```

### Running the full example

```bash
DEEPSEEK_API_KEY=sk-... elixir examples/weather_agent.exs
```

## License

MIT
