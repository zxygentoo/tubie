# ═══════════════════════════════════════════════════════════════════
# Taboo Game — multi-agent communication with loop + branch
#
# Two LLM agents play Taboo: a Hinter gives clues about a secret word
# without using any taboo words, and a Guesser tries to guess it.
# Demonstrates loop + branch for turn-based multi-agent interaction.
#
# Run:  OPENAI_API_KEY=... elixir examples/taboo.exs
#   or: DEEPSEEK_API_KEY=... elixir examples/taboo.exs
# ═══════════════════════════════════════════════════════════════════

Mix.install([
  {:tubie, path: Path.join(__DIR__, "..")},
  {:req, "~> 0.5"},
  {:jason, "~> 1.4"}
])

Code.require_file("support/llm.exs", __DIR__)

alias Tubie.State

# -------------------------------------------------------------------
# Agent pieces
# -------------------------------------------------------------------

# 1. Hinter: give a clue without using taboo words
hinter = fn state ->
  word = State.get(state, :word)
  taboo = State.get(state, :taboo)
  history = State.get(state, :history, [])

  past_clues = history
    |> Enum.filter(&(&1.role == :hinter))
    |> Enum.map(& &1.text)

  past_guesses = history
    |> Enum.filter(&(&1.role == :guesser))
    |> Enum.map(& &1.text)

  messages = [
    %{"role" => "system", "content" => """
    You are playing Taboo. The secret word is "#{word}".
    You must NOT use these words: #{Enum.join(taboo, ", ")}.
    You must NOT use the secret word itself.
    Give a short, one-sentence clue to help the guesser.\
    """},
    %{"role" => "user", "content" => """
    #{if past_clues != [], do: "Your previous clues: #{Enum.join(past_clues, "; ")}\n"}
    #{if past_guesses != [], do: "Guesser's previous guesses: #{Enum.join(past_guesses, "; ")}\n"}
    Give your next clue.\
    """}
  ]

  case LLM.call(messages) do
    {:ok, msg} ->
      clue = msg["content"]
      IO.puts("  Hinter: #{clue}")
      State.update(state, :history, [], &(&1 ++ [%{role: :hinter, text: clue}]))

    {:error, reason} ->
      State.error(state, reason)
  end
end

# 2. Guesser: try to guess the word from clues
guesser = fn state ->
  history = State.get(state, :history, [])

  clues = history
    |> Enum.filter(&(&1.role == :hinter))
    |> Enum.map(& &1.text)
    |> Enum.with_index(1)
    |> Enum.map(fn {c, i} -> "#{i}. #{c}" end)
    |> Enum.join("\n")

  past_guesses = history
    |> Enum.filter(&(&1.role == :guesser))
    |> Enum.map(& &1.text)

  messages = [
    %{"role" => "system", "content" => """
    You are playing Taboo as the guesser. Someone is giving you clues
    about a secret word. Respond with ONLY your one-word guess, nothing else.\
    """},
    %{"role" => "user", "content" => """
    Clues so far:
    #{clues}
    #{if past_guesses != [], do: "\nYour wrong guesses so far: #{Enum.join(past_guesses, ", ")}\n"}
    What is the secret word?\
    """}
  ]

  case LLM.call(messages) do
    {:ok, msg} ->
      guess = msg["content"] |> String.trim() |> String.downcase()
      IO.puts("  Guesser: #{guess}")
      State.update(state, :history, [], &(&1 ++ [%{role: :guesser, text: guess}]))

    {:error, reason} ->
      State.error(state, reason)
  end
end

# 3. Judge: check if the guess is correct
judge = fn state ->
  word = State.get(state, :word) |> String.downcase()
  history = State.get(state, :history, [])

  last_guess =
    history
    |> Enum.filter(&(&1.role == :guesser))
    |> List.last()
    |> Map.get(:text)

  if String.contains?(last_guess, word) do
    IO.puts("  >> Correct!")
    State.halt(state)
  else
    IO.puts("  >> Wrong, next round...")
    state
  end
end

# -------------------------------------------------------------------
# Compose: loop(hinter → guesser → judge)
# -------------------------------------------------------------------
taboo_game =
  Tubie.sequence([hinter, guesser, judge])
  |> Tubie.loop(max: 5)

# -------------------------------------------------------------------
# Run
# -------------------------------------------------------------------
games = [
  %{word: "elephant", taboo: ["trunk", "big", "gray", "Africa", "animal"]},
  %{word: "pizza", taboo: ["cheese", "Italian", "slice", "dough", "oven"]}
]

for game <- games do
  IO.puts("=== Secret: #{game.word} | Taboo: #{Enum.join(game.taboo, ", ")} ===\n")

  state =
    State.new(game)
    |> taboo_game.()

  rounds = state |> State.get(:history, []) |> Enum.count(&(&1.role == :guesser))

  case state.status do
    :halt -> IO.puts("\nGuessed in #{rounds} round(s)!\n")
    _ -> IO.puts("\nFailed to guess in #{rounds} rounds.\n")
  end
end
