defmodule Tubie do
  @moduledoc """
  An agent is any function `State.t() -> State.t()`.

  Combinators that take agents and return agents:

      agent  ::  State -> State

      sequence([a, b, c])        =  a >>> b >>> c   (with early exit)
      and_then(a, b)             =  pipeable sequence of two
      branch(classifier, table)  =  case-dispatch on state
      loop(a, opts)              =  repeat until halt or max
      fan_out([a, b], as: key)   =  concurrent fan-out
      with_retry(a, opts)        =  retry with backoff
      with_fallback(a, handler)  =  try/rescue wrapper

  Every combinator returns `State -> State`, so they compose freely:

      call_llm
      |> with_retry(max: 3)
      |> branch(&classify/1, %{
           tools: &execute/1,
           done:  &State.halt/1
         })
      |> loop(max: 10)
  """

  alias Tubie.State

  @type agent :: (State.t() -> State.t())

  # ── Sequence ────────────────────────────────────────────────────

  @doc """
  Run agents left-to-right, threading state through.
  Stops early on `:halt` or `{:error, _}`.
  """
  @spec sequence([agent()]) :: agent()
  def sequence(agents) when is_list(agents) do
    fn %State{} = state ->
      Enum.reduce_while(agents, state, fn agent, acc ->
        case agent.(acc) do
          %State{status: :ok} = next -> {:cont, next}
          %State{status: :halt} = halted -> {:halt, halted}
          %State{status: {:error, _}} = e -> {:halt, e}
        end
      end)
    end
  end

  @doc "Pipeable `sequence/1` for two agents: `a |> and_then(b)`."
  @spec and_then(agent(), agent()) :: agent()
  def and_then(first, second), do: sequence([first, second])

  # ── Branch ──────────────────────────────────────────────────────

  @doc """
  Dispatch to different agents based on a classifier function.

  `classifier` is `State -> term()`, `table` maps terms to agents.

      branch(
        fn s -> State.get(s, :intent) end,
        %{
          search: &search_agent/1,
          answer: &answer_agent/1
        },
        default: &fallback_agent/1
      )
  """
  @spec branch((State.t() -> term()), %{term() => agent()}, Keyword.t()) :: agent()
  def branch(classifier, table, opts \\ [])

  def branch(agent, classifier, table)
      when is_function(agent, 1) and is_function(classifier, 1) and is_map(table),
      do: and_then(agent, branch(classifier, table))

  def branch(classifier, table, opts) when is_function(classifier, 1) do
    default = Keyword.get(opts, :default, fn s -> State.error(s, :no_matching_branch) end)

    fn %State{} = state ->
      key = classifier.(state)
      agent = Map.get(table, key, default)
      agent.(state)
    end
  end

  @doc "Pipeable `branch/3` with options: `a |> branch(classifier, table, opts)`."
  def branch(agent, classifier, table, opts)
      when is_function(agent, 1) and is_function(classifier, 1) and is_map(table),
      do: and_then(agent, branch(classifier, table, opts))

  # ── Loop ────────────────────────────────────────────────────────

  @doc """
  Repeatedly apply an agent until it returns `:halt` or hits `max`.
  Resets status to `:ok` before each iteration.
  """
  @spec loop(agent(), Keyword.t()) :: agent()
  def loop(agent, opts \\ []) do
    max = Keyword.get(opts, :max, 100)

    fn %State{} = state ->
      do_loop(agent, State.ok(state), 0, max)
    end
  end

  defp do_loop(_agent, %State{status: :halt} = s, _i, _max), do: s
  defp do_loop(_agent, %State{status: {:error, _}} = s, _i, _max), do: s
  defp do_loop(_agent, state, i, max) when i >= max, do: state
  defp do_loop(agent, state, i, max), do: do_loop(agent, agent.(state), i + 1, max)

  # ── Fan-out ─────────────────────────────────────────────────────

  @doc """
  Run agents concurrently on the same input state.

  With `as:` — stores result states under that key for later merging:

      fan_out([search_web, search_db], as: :results)
      |> and_then(fn state ->
        [web, db] = State.get(state, :results)
        # merge however you want
      end)

  Without `as:` — fire-and-forget, original state passes through:

      fan_out([log_a, log_b, log_c])
  """
  @spec fan_out([agent()], Keyword.t()) :: agent()
  def fan_out(agents, opts \\ []) when is_list(agents) do
    results_key = Keyword.get(opts, :as)
    timeout = Keyword.get(opts, :timeout, 30_000)

    fn %State{} = state ->
      results =
        agents
        |> Task.async_stream(fn agent -> agent.(state) end,
          max_concurrency: length(agents),
          timeout: timeout
        )
        |> Enum.map(fn
          {:ok, %State{} = result} -> result
          {:exit, reason} -> State.error(state, {:task_crashed, reason})
        end)

      case results_key do
        nil -> state
        key -> State.put(state, key, results)
      end
    end
  end

  # ── Retry ───────────────────────────────────────────────────────

  @doc """
  Retry an agent up to `max` times on `{:error, _}` status or exception.
  Resets status to `:ok` before each retry. After max attempts, returns
  the last error state or re-raises the last exception.

      call_llm |> with_retry(max: 3, wait: 1_000)
  """
  @spec with_retry(agent(), Keyword.t()) :: agent()
  def with_retry(agent, opts \\ []) do
    max = Keyword.get(opts, :max, 3)
    wait = Keyword.get(opts, :wait, 0)

    fn %State{} = state ->
      do_retry(agent, state, 0, max, wait)
    end
  end

  defp do_retry(_agent, state, attempt, max, _wait) when attempt >= max, do: state

  defp do_retry(agent, state, attempt, max, wait) do
    try do
      case agent.(State.ok(state)) do
        %State{status: {:error, _}} = err ->
          if wait > 0, do: Process.sleep(wait)
          do_retry(agent, err, attempt + 1, max, wait)

        good ->
          good
      end
    rescue
      e ->
        if attempt + 1 >= max, do: reraise(e, __STACKTRACE__)
        if wait > 0, do: Process.sleep(wait)
        do_retry(agent, state, attempt + 1, max, wait)
    end
  end

  # ── Fallback ────────────────────────────────────────────────────

  @doc """
  Wrap an agent with a rescue handler.

      call_llm |> with_fallback(fn state, e -> State.error(state, e.message) end)
  """
  @spec with_fallback(agent(), (State.t(), Exception.t() -> State.t())) :: agent()
  def with_fallback(agent, handler) when is_function(handler, 2) do
    fn %State{} = state ->
      try do
        agent.(state)
      rescue
        e -> handler.(state, e)
      end
    end
  end
end
