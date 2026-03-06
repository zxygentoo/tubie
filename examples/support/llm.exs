# Shared LLM helper for examples.
#
# Auto-detects provider from env vars (checks OPENAI_API_KEY first,
# then DEEPSEEK_API_KEY). Override model/url with LLM_MODEL / LLM_URL.

defmodule LLM do
  def call(messages, opts \\ []) do
    config = config()

    payload =
      %{model: config.model, messages: messages}
      |> maybe_put(:tools, Keyword.get(opts, :tools))

    case Req.post(config.url, json: payload, auth: {:bearer, config.api_key}) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, get_in(body, ["choices", Access.at(0), "message"])}

      {:ok, %{status: status, body: body}} ->
        {:error, "API #{status}: #{inspect(body)}"}

      {:error, err} ->
        {:error, inspect(err)}
    end
  end

  defp config do
    {url, model, api_key} =
      cond do
        key = System.get_env("OPENAI_API_KEY") ->
          {"https://api.openai.com/v1/chat/completions", "gpt-4o-mini", key}

        key = System.get_env("DEEPSEEK_API_KEY") ->
          {"https://api.deepseek.com/chat/completions", "deepseek-chat", key}

        true ->
          raise "Set OPENAI_API_KEY or DEEPSEEK_API_KEY"
      end

    %{
      url: System.get_env("LLM_URL", url),
      model: System.get_env("LLM_MODEL", model),
      api_key: api_key
    }
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, val), do: Map.put(map, key, val)
end
