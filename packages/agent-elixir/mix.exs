defmodule ConvergerAgent.MixProject do
  use Mix.Project

  @version "0.1.1"
  @source_url "https://github.com/AimTune/converger/tree/main/packages/agent-elixir"

  def project do
    [
      app: :converger_agent,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),
      description:
        "Elixir agent SDK for Converger: a bot backend answering the conversations of a channel over one Protocol v1 WebSocket (Mint.WebSocket).",
      package: package(),
      docs: [
        main: "readme",
        extras: ["README.md", "CHANGELOG.md"],
        source_ref: "agent-elixir/v#{@version}"
      ],
      source_url: @source_url
    ]
  end

  def application do
    [extra_applications: [:logger, :crypto]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:mint, "~> 1.6"},
      {:mint_web_socket, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:bandit, "~> 1.5", only: :test},
      {:websock_adapter, "~> 0.5", only: :test},
      {:plug, "~> 1.15", only: :test},
      {:jsv, "~> 0.26", only: :test},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      name: "converger_agent",
      licenses: ["MIT"],
      files: ~w(lib mix.exs README.md CHANGELOG.md LICENSE),
      links: %{
        "Source" => @source_url,
        "Docs" => "https://converger.aimtune.dev/sdk/agent-elixir"
      }
    ]
  end
end
