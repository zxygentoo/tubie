# ═══════════════════════════════════════════════════════════════════
# Weather Agent — built entirely from Tubie combinators
#
# Run:  OPENAI_API_KEY=... elixir examples/weather_agent.exs
#   or: DEEPSEEK_API_KEY=... elixir examples/weather_agent.exs
# ═══════════════════════════════════════════════════════════════════

Mix.install([
  {:tubie, path: Path.join(__DIR__, "..")},
  {:req, "~> 0.5"},
  {:jason, "~> 1.4"}
])

Code.require_file("support/llm.exs", __DIR__)

alias Tubie.State

# -------------------------------------------------------------------
# Boundary: Tools (a registry of name → {spec, execute_fn})
# -------------------------------------------------------------------
tools = %{
  "get_weather" => {
    %{
      type: "function",
      function: %{
        name: "get_weather",
        description: "Get current weather for a location",
        parameters: %{
          type: "object",
          properties: %{
            location: %{type: "string", description: "City name"}
          },
          required: ["location"]
        }
      }
    },
    fn %{"location" => loc} ->
      # Stub — random temperature each call
      temp = Enum.random(50..95)
      "#{loc}: #{temp}°F, partly cloudy"
    end
  }
}

tool_specs = tools |> Map.values() |> Enum.map(&elem(&1, 0))

# -------------------------------------------------------------------
# Agent pieces — each is just  State → State
# -------------------------------------------------------------------

# 1. Call the LLM with current message history
call_llm = fn state ->
  messages = State.get(state, :messages, [])

  case LLM.call(messages, tools: tool_specs) do
    {:ok, msg} ->
      state
      |> State.put(:last_message, msg)
      |> State.update(:messages, [], &(&1 ++ [msg]))

    {:error, reason} ->
      State.error(state, reason)
  end
end

# 2. Classifier: does the last message have tool calls?
has_tool_calls? = fn state ->
  case State.get(state, :last_message) do
    %{"tool_calls" => [_ | _]} -> :tools
    _ -> :done
  end
end

# 3. Execute all tool calls, append results to messages
execute_tools = fn state ->
  tool_calls = get_in(State.get(state, :last_message), ["tool_calls"]) || []

  Enum.reduce(tool_calls, state, fn tc, acc ->
    name = get_in(tc, ["function", "name"])
    args = tc["function"]["arguments"] |> Jason.decode!()

    result =
      case Map.get(tools, name) do
        {_spec, exec_fn} -> exec_fn.(args)
        nil -> "Unknown tool: #{name}"
      end

    IO.puts("  ⚙️  #{name}(#{inspect(args)}) → #{result}")

    State.update(acc, :messages, [], fn msgs ->
      msgs ++ [%{"role" => "tool", "tool_call_id" => tc["id"], "content" => result}]
    end)
  end)
end

# -------------------------------------------------------------------
# Compose: the agent is one expression
# -------------------------------------------------------------------
weather_agent =
  call_llm
  |> Tubie.with_retry(max: 3, wait: 1_000)
  |> Tubie.with_fallback(fn state, e ->
    IO.puts("  [error] #{Exception.message(e)}")
    State.error(state, Exception.message(e))
  end)
  |> Tubie.branch(has_tool_calls?, %{
    tools: execute_tools,
    done: &State.halt/1
  })
  |> Tubie.loop(max: 10)

# -------------------------------------------------------------------
# REPL
# -------------------------------------------------------------------
defmodule CLI do
  alias Tubie.State

  def run(agent) do
    IO.puts("Weather Agent (type 'quit' to exit)\n")

    loop(agent, [
      %{
        "role" => "system",
        "content" =>
          "You are a helpful weather assistant. Use the get_weather tool when asked about weather."
      }
    ])
  end

  defp loop(agent, messages) do
    input = IO.gets("You: ") |> String.trim()

    if input in ["quit", "exit"] do
      IO.puts("Bye!")
    else
      messages = messages ++ [%{"role" => "user", "content" => input}]

      state =
        State.new(%{messages: messages})
        |> agent.()

      case state.status do
        status when status in [:ok, :halt] ->
          reply = state |> State.get(:messages) |> List.last() |> Map.get("content")
          IO.puts("\nAgent: #{reply}\n")
          loop(agent, State.get(state, :messages))

        {:error, reason} ->
          IO.puts("\nError: #{reason}\n")
          loop(agent, messages)
      end
    end
  end
end

CLI.run(weather_agent)
