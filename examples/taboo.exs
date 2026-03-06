# ===================================================================
# Taboo Game — true multi-agent message passing
#
# Two LLM agents play Taboo concurrently: a Hinter gives clues and a
# Guesser tries to guess. They communicate through message queues
# (built on Elixir's Agent), each running in its own loop via fan_out.
#
# Demonstrates: fan_out (concurrency) + loop (per-agent) + message
# queues for async inter-agent communication.
#
# Run:  OPENAI_API_KEY=... elixir examples/taboo.exs
#   or: DEEPSEEK_API_KEY=... elixir examples/taboo.exs
# ===================================================================

Mix.install([
  {:tubie, path: Path.join(__DIR__, "..")},
  {:req, "~> 0.5"},
  {:jason, "~> 1.4"}
])

Code.require_file("support/llm.exs", __DIR__)

alias Tubie.State

# -------------------------------------------------------------------
# Message Queue — a simple blocking queue built on Elixir's Agent
# -------------------------------------------------------------------

defmodule MQ do
  def new do
    {:ok, pid} = Agent.start_link(fn -> :queue.new() end)
    pid
  end

  def send_msg(pid, msg) do
    Agent.update(pid, fn q -> :queue.in(msg, q) end)
  end

  def recv_msg(pid) do
    poll(pid)
  end

  defp poll(pid) do
    case Agent.get(pid, fn q -> :queue.out(q) end) do
      {{:value, msg}, rest} ->
        Agent.update(pid, fn _q -> rest end)
        msg

      {:empty, _} ->
        Process.sleep(50)
        poll(pid)
    end
  end
end

# -------------------------------------------------------------------
# Game setup
# -------------------------------------------------------------------

run_game = fn game ->
  word = game.word
  taboo = game.taboo
  max_rounds = 5

  IO.puts("=== Secret: #{word} | Taboo: #{Enum.join(taboo, ", ")} ===\n")

  # Create message queues
  hinter_inbox = MQ.new()
  guesser_inbox = MQ.new()

  # Seed: tell the hinter to start
  MQ.send_msg(hinter_inbox, :start)

  # -----------------------------------------------------------------
  # Hinter agent — runs in its own loop
  # -----------------------------------------------------------------
  hinter_agent =
    Tubie.loop(
      fn state ->
        msg = MQ.recv_msg(hinter_inbox)

        case msg do
          :done ->
            State.halt(state)

          _ ->
            past_clues = State.get(state, :clues, [])
            past_wrong = case msg do
              {:wrong, guess} -> State.get(state, :wrong, []) ++ [guess]
              :start -> []
              _ -> State.get(state, :wrong, [])
            end

            messages = [
              %{"role" => "system", "content" => """
              You are playing Taboo. The secret word is "#{word}".
              You must NOT use these words: #{Enum.join(taboo, ", ")}.
              You must NOT use the secret word itself.
              Give a short, one-sentence clue to help the guesser.\
              """},
              %{"role" => "user", "content" => """
              #{if past_clues != [], do: "Your previous clues: #{Enum.join(past_clues, "; ")}\n"}
              #{if past_wrong != [], do: "Guesser's wrong guesses: #{Enum.join(past_wrong, "; ")}\n"}
              Give your next clue.\
              """}
            ]

            case LLM.call(messages) do
              {:ok, msg} ->
                clue = msg["content"]
                IO.puts("  Hinter: #{clue}")
                MQ.send_msg(guesser_inbox, {:clue, clue})

                state
                |> State.update(:clues, [], &(&1 ++ [clue]))
                |> State.put(:wrong, past_wrong)

              {:error, reason} ->
                IO.puts("  Hinter error: #{inspect(reason)}")
                State.halt(state)
            end
        end
      end,
      max: max_rounds
    )

  # -----------------------------------------------------------------
  # Guesser agent — runs in its own loop
  # -----------------------------------------------------------------
  guesser_agent =
    Tubie.loop(
      fn state ->
        msg = MQ.recv_msg(guesser_inbox)

        case msg do
          {:clue, clue} ->
            all_clues = State.get(state, :clues, []) ++ [clue]
            past_guesses = State.get(state, :guesses, [])

            clues_text =
              all_clues
              |> Enum.with_index(1)
              |> Enum.map(fn {c, i} -> "#{i}. #{c}" end)
              |> Enum.join("\n")

            messages = [
              %{"role" => "system", "content" => """
              You are playing Taboo as the guesser. Someone is giving you clues
              about a secret word. Respond with ONLY your one-word guess, nothing else.\
              """},
              %{"role" => "user", "content" => """
              Clues so far:
              #{clues_text}
              #{if past_guesses != [], do: "\nYour wrong guesses so far: #{Enum.join(past_guesses, ", ")}\n"}
              What is the secret word?\
              """}
            ]

            case LLM.call(messages) do
              {:ok, resp} ->
                guess = resp["content"] |> String.trim() |> String.downcase()
                IO.puts("  Guesser: #{guess}")

                if String.contains?(guess, String.downcase(word)) do
                  IO.puts("  >> Correct!")
                  MQ.send_msg(hinter_inbox, :done)
                  state |> State.put(:clues, all_clues) |> State.put(:result, :won) |> State.halt()
                else
                  IO.puts("  >> Wrong, next round...")
                  MQ.send_msg(hinter_inbox, {:wrong, guess})

                  state
                  |> State.put(:clues, all_clues)
                  |> State.update(:guesses, [], &(&1 ++ [guess]))
                end

              {:error, reason} ->
                IO.puts("  Guesser error: #{inspect(reason)}")
                State.halt(state)
            end

          _ ->
            state
        end
      end,
      max: max_rounds
    )

  # -----------------------------------------------------------------
  # Compose: fan_out runs both agents concurrently
  # -----------------------------------------------------------------
  taboo_game = Tubie.fan_out([hinter_agent, guesser_agent], as: :agents, timeout: 120_000)

  result = taboo_game.(State.new())

  [_hinter_state, guesser_state] = State.get(result, :agents)
  rounds = guesser_state |> State.get(:guesses, []) |> length()
  won? = State.get(guesser_state, :result) == :won

  if won? do
    IO.puts("\nGuessed in #{rounds + 1} round(s)!\n")
  else
    IO.puts("\nFailed to guess in #{rounds} rounds.\n")
  end
end

# -------------------------------------------------------------------
# Run
# -------------------------------------------------------------------
games = [
  %{word: "gerrymandering", taboo: ["district", "vote", "election", "political", "map",
    "boundary", "manipulate", "partisan", "congress", "redraw", "unfair", "representative"]},
  %{word: "defenestration", taboo: ["window", "throw", "fall", "building", "Prague",
    "eject", "toss", "glass", "out", "drop", "push", "opening"]},
  %{word: "sonder", taboo: ["stranger", "life", "realize", "everyone", "complex", "passing",
    "people", "story", "individual", "awareness", "anonymous", "crowd"]},
  %{word: "petrichor", taboo: ["rain", "smell", "earth", "wet", "ground", "soil", "storm",
    "scent", "aroma", "dry", "dust", "water", "after", "odor"]}
]

Enum.each(games, run_game)
