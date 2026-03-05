defmodule Tubie.MixProject do
  use Mix.Project

  def project do
    [
      app: :tubie,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: "A minimal agent composition library. Agents are functions, composition is the framework.",
      package: package(),
      source_url: "https://github.com/zxygentoo/tubie"
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:ex_doc, "~> 0.31", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      files: ~w(lib mix.exs README.md LICENSE),
      links: %{"GitHub" => "https://github.com/zxygentoo/tubie"}
    ]
  end
end
