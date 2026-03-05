defmodule Tubie.State do
  @moduledoc """
  The universal currency of agent composition.

  A State is a map-like accumulator with a `status` field that
  controls flow: `:ok` keeps going, `:halt` stops gracefully,
  `{:error, reason}` signals failure.

  Everything else lives in `data` — a plain map you own entirely.
  No opinions about what goes in it.
  """

  @type status :: :ok | :halt | {:error, any()}
  @type t :: %__MODULE__{data: map(), status: status()}

  defstruct data: %{}, status: :ok

  def new(data \\ %{}), do: %__MODULE__{data: data}

  def get(%__MODULE__{data: data}, key, default \\ nil),
    do: Map.get(data, key, default)

  def put(%__MODULE__{} = s, key, value),
    do: %{s | data: Map.put(s.data, key, value)}

  def update(%__MODULE__{} = s, key, default, fun),
    do: %{s | data: Map.update(s.data, key, default, fun)}

  def merge(%__MODULE__{} = s, map) when is_map(map),
    do: %{s | data: Map.merge(s.data, map)}

  def halt(%__MODULE__{} = s), do: %{s | status: :halt}
  def error(%__MODULE__{} = s, reason), do: %{s | status: {:error, reason}}
  def ok(%__MODULE__{} = s), do: %{s | status: :ok}

  def ok?(%__MODULE__{status: :ok}), do: true
  def ok?(_), do: false
end
