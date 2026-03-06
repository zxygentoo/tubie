# ═══════════════════════════════════════════════════════════════════
# Map-Reduce — parallel summarization with Tubie.fan_out
#
# Demonstrates fan_out (map) + and_then (reduce):
#   split document → summarize chunks in parallel → merge summaries.
#
# Run:  OPENAI_API_KEY=... elixir examples/map_reduce.exs
#   or: DEEPSEEK_API_KEY=... elixir examples/map_reduce.exs
# ═══════════════════════════════════════════════════════════════════

Mix.install([
  {:tubie, path: Path.join(__DIR__, "..")},
  {:req, "~> 0.5"},
  {:jason, "~> 1.4"}
])

Code.require_file("support/llm.exs", __DIR__)

alias Tubie.State

# -------------------------------------------------------------------
# Sample document (Tubie's own documentation, split into sections)
# -------------------------------------------------------------------
sections = [
  """
  Tubie is a minimal agent composition library for Elixir. The core idea is
  that an agent is simply any function State -> State. You build complex agents
  by composing simple ones with combinators like sequence, branch, and loop.
  The entire library is about 200 lines with zero dependencies.
  """,
  """
  Tubie.State is a map-like accumulator with a status field that controls flow.
  Status can be :ok (continue), :halt (stop gracefully), or {:error, reason}
  (signal failure). All data operations are immutable and return new State structs.
  Functions include new, get, put, update, merge, halt, error, ok, and ok?.
  """,
  """
  Combinators are the heart of Tubie. sequence runs agents left-to-right with
  early exit on halt or error. branch dispatches based on a classifier function.
  loop repeats until halt or max iterations. fan_out runs agents concurrently.
  with_retry retries on error or exception. with_fallback wraps with try/rescue.
  All combinators return agents, so they compose freely via the pipe operator.
  """
]

# -------------------------------------------------------------------
# Agent pieces
# -------------------------------------------------------------------

# Map: summarize a single section
summarize_section = fn index ->
  fn state ->
    section = State.get(state, :sections) |> Enum.at(index)

    IO.puts("  [map] summarizing section #{index + 1}...")

    case LLM.call([
           %{"role" => "user", "content" => "Summarize this in one sentence:\n\n#{section}"}
         ]) do
      {:ok, msg} -> State.put(state, :summary, msg["content"])
      {:error, reason} -> State.error(state, reason)
    end
  end
end

# Reduce: merge partial summaries into a final summary
reduce = fn state ->
  partials =
    State.get(state, :partials)
    |> Enum.map(&State.get(&1, :summary))
    |> Enum.with_index(1)
    |> Enum.map(fn {s, i} -> "#{i}. #{s}" end)
    |> Enum.join("\n")

  IO.puts("  [reduce] merging #{length(State.get(state, :partials))} summaries...")

  case LLM.call([
         %{
           "role" => "user",
           "content" => """
           Combine these partial summaries into one coherent paragraph:

           #{partials}\
           """
         }
       ]) do
    {:ok, msg} -> State.put(state, :final_summary, msg["content"])
    {:error, reason} -> State.error(state, reason)
  end
end

# -------------------------------------------------------------------
# Compose: fan_out (map) → reduce
# -------------------------------------------------------------------
map_agents = Enum.map(0..(length(sections) - 1), &summarize_section.(&1))

summarizer =
  Tubie.fan_out(map_agents, as: :partials)
  |> Tubie.and_then(reduce)

# -------------------------------------------------------------------
# Run
# -------------------------------------------------------------------
IO.puts("Summarizing #{length(sections)} sections in parallel...\n")

state =
  State.new(%{sections: sections})
  |> summarizer.()

case state.status do
  status when status in [:ok, :halt] ->
    IO.puts("\nFinal summary:")
    IO.puts(State.get(state, :final_summary))

  {:error, reason} ->
    IO.puts("\nError: #{reason}")
end
