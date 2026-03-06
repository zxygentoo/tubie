# ═══════════════════════════════════════════════════════════════════
# RAG — Retrieval-Augmented Generation with Tubie.sequence
#
# Demonstrates the sequence combinator: retrieve → build prompt → LLM.
# Uses simple keyword matching (no vector DB) for retrieval.
#
# Run:  OPENAI_API_KEY=... elixir examples/rag.exs
#   or: DEEPSEEK_API_KEY=... elixir examples/rag.exs
# ═══════════════════════════════════════════════════════════════════

Mix.install([
  {:tubie, path: Path.join(__DIR__, "..")},
  {:req, "~> 0.5"},
  {:jason, "~> 1.4"}
])

Code.require_file("support/llm.exs", __DIR__)

alias Tubie.State

# -------------------------------------------------------------------
# Knowledge base — a list of text chunks
# -------------------------------------------------------------------
chunks = [
  "Tubie is a minimal agent composition library for Elixir. " <>
    "An agent is any function State -> State. Combinators compose agents into larger agents.",

  "Tubie.sequence runs agents left-to-right, threading state through. " <>
    "It stops early on :halt or {:error, _} status.",

  "Tubie.branch dispatches to different agents based on a classifier function. " <>
    "The classifier returns a key, and the table maps keys to agents.",

  "Tubie.loop repeatedly applies an agent until it returns :halt or hits a max iteration count. " <>
    "It resets status to :ok before each iteration.",

  "Tubie.fan_out runs agents concurrently on the same input state. " <>
    "With the :as option, it stores result states under a key for later merging.",

  "Tubie.with_retry retries an agent on {:error, _} status or exception. " <>
    "After max attempts, it returns the last error state or re-raises the last exception.",

  "Tubie.with_fallback wraps an agent with a try/rescue handler. " <>
    "The handler receives the original state and the exception.",

  "Tubie.State is a map-like accumulator with a status field. " <>
    "Status can be :ok, :halt, or {:error, reason}. Status controls flow through combinators."
]

# -------------------------------------------------------------------
# Agent pieces
# -------------------------------------------------------------------

# 1. Retrieve: find top-k chunks by keyword substring matching
#    (a real system would use embeddings + vector search)
stop_words = ~w(what how does is do on the a an to of for with)

retrieve = fn state ->
  query_terms =
    State.get(state, :query)
    |> String.downcase()
    |> String.split(~r/[^\w]+/)
    |> Enum.reject(&(&1 in stop_words))

  scored =
    chunks
    |> Enum.map(fn chunk ->
      lower = String.downcase(chunk)
      score = Enum.count(query_terms, &String.contains?(lower, &1))
      {score, chunk}
    end)
    |> Enum.filter(fn {score, _} -> score > 0 end)
    |> Enum.sort_by(&elem(&1, 0), :desc)
    |> Enum.take(3)
    |> Enum.map(&elem(&1, 1))

  IO.puts("  [retrieve] found #{length(scored)} chunks")
  State.put(state, :context, scored)
end

# 2. Generate: ask the LLM to answer using retrieved context
generate = fn state ->
  context = State.get(state, :context) |> Enum.join("\n\n")
  query = State.get(state, :query)

  messages = [
    %{"role" => "system", "content" => """
    Answer the question using ONLY the provided context. \
    If the context doesn't contain the answer, say so.\
    """},
    %{"role" => "user", "content" => """
    Context:
    #{context}

    Question: #{query}\
    """}
  ]

  case LLM.call(messages) do
    {:ok, msg} -> State.put(state, :answer, msg["content"])
    {:error, reason} -> State.error(state, reason)
  end
end

# -------------------------------------------------------------------
# Compose: retrieve → generate
# -------------------------------------------------------------------
rag = Tubie.sequence([retrieve, generate])

# -------------------------------------------------------------------
# Run
# -------------------------------------------------------------------
queries = [
  "What is Tubie?",
  "How does fan_out work?",
  "What does with_retry do on failure?"
]

for q <- queries do
  IO.puts("\nQ: #{q}")

  state =
    State.new(%{query: q})
    |> rag.()

  case state.status do
    status when status in [:ok, :halt] ->
      IO.puts("A: #{State.get(state, :answer)}\n")

    {:error, reason} ->
      IO.puts("Error: #{reason}\n")
  end
end
