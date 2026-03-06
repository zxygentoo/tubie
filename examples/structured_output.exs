# ═══════════════════════════════════════════════════════════════════
# Structured Output — validated extraction with retry and fallback
#
# Demonstrates with_retry + with_fallback: ask the LLM for structured
# YAML output, validate required fields, retry on validation failure.
#
# Run:  OPENAI_API_KEY=... elixir examples/structured_output.exs
#   or: DEEPSEEK_API_KEY=... elixir examples/structured_output.exs
# ═══════════════════════════════════════════════════════════════════

Mix.install([
  {:tubie, path: Path.join(__DIR__, "..")},
  {:req, "~> 0.5"},
  {:jason, "~> 1.4"},
  {:yaml_elixir, "~> 2.9"}
])

Code.require_file("support/llm.exs", __DIR__)

alias Tubie.State

# -------------------------------------------------------------------
# Agent pieces
# -------------------------------------------------------------------

required_fields = ~w(name date location summary)

# 1. Ask LLM to extract structured data as YAML
extract = fn state ->
  text = State.get(state, :text)

  messages = [
    %{
      "role" => "user",
      "content" => """
      Extract event information from the text below.
      Return ONLY a YAML block with these fields: name, date, location, summary.

      ```yaml
      name: ...
      date: ...
      location: ...
      summary: ...
      ```

      Text: #{text}\
      """
    }
  ]

  case LLM.call(messages) do
    {:ok, msg} -> State.put(state, :raw_output, msg["content"])
    {:error, reason} -> State.error(state, reason)
  end
end

# 2. Parse YAML from the response
parse = fn state ->
  raw = State.get(state, :raw_output)

  yaml_str =
    case Regex.run(~r/```ya?ml\n(.*?)```/s, raw) do
      [_, content] -> content
      nil -> raw
    end

  case YamlElixir.read_from_string(yaml_str) do
    {:ok, parsed} -> State.put(state, :parsed, parsed)
    {:error, _} -> State.error(state, "Failed to parse YAML from LLM response")
  end
end

# 3. Validate required fields are present and non-empty
validate = fn state ->
  parsed = State.get(state, :parsed)

  missing =
    required_fields
    |> Enum.reject(fn f ->
      val = Map.get(parsed, f)
      val != nil and val != "" and val != "..."
    end)

  case missing do
    [] ->
      IO.puts("  [validate] all fields present")
      state

    fields ->
      IO.puts("  [validate] missing: #{Enum.join(fields, ", ")}")
      State.error(state, "Missing fields: #{Enum.join(fields, ", ")}")
  end
end

# -------------------------------------------------------------------
# Compose: extract → parse → validate, with retry and fallback
# -------------------------------------------------------------------
extractor =
  Tubie.sequence([extract, parse, validate])
  |> Tubie.with_retry(max: 3, wait: 500)
  |> Tubie.with_fallback(fn state, e ->
    IO.puts("  [fallback] #{Exception.message(e)}")
    State.error(state, Exception.message(e))
  end)

# -------------------------------------------------------------------
# Run
# -------------------------------------------------------------------
texts = [
  """
  Join us for ElixirConf 2025 on August 27-29 in Orlando, Florida!
  This year's conference features talks on LiveView, Nerves, and
  the latest in the BEAM ecosystem. Don't miss the keynote by Jose Valim.
  """,
  """
  The Erlang User Conference will be held June 12th at the Brewery
  in Stockholm. Topics include OTP 27, distributed systems, and
  the future of BEAM languages.
  """
]

for text <- texts do
  IO.puts("--- Input ---")
  IO.puts(String.trim(text))
  IO.puts("")

  state =
    State.new(%{text: text})
    |> extractor.()

  case state.status do
    status when status in [:ok, :halt] ->
      parsed = State.get(state, :parsed)
      IO.puts("--- Extracted ---")
      for field <- required_fields do
        IO.puts("  #{field}: #{Map.get(parsed, field)}")
      end

    {:error, reason} ->
      IO.puts("--- Error ---")
      IO.puts("  #{reason}")
  end

  IO.puts("")
end
