defmodule Converger.Pipeline.MiddlewareTest do
  use ExUnit.Case, async: true

  alias Converger.Pipeline.Middleware
  alias Converger.Pipeline.Middleware.{AddPrefix, AddSuffix, TextReplace, TruncateText, SetMetadata, ContentFilter}

  # Stub activity struct for unit tests
  defp activity(attrs \\ %{}) do
    Map.merge(
      %{
        id: "act-1",
        text: "Hello world",
        metadata: %{},
        sender: "user-1",
        type: "message"
      },
      attrs
    )
  end

  defp channel(transformations) do
    %{id: "ch-1", transformations: transformations}
  end

  # --- AddPrefix ---

  describe "AddPrefix" do
    test "prepends prefix to text" do
      assert {:cont, result} = AddPrefix.call(activity(), %{}, %{"prefix" => "[Alert] "})
      assert result.text == "[Alert] Hello world"
    end

    test "handles nil text" do
      assert {:cont, result} = AddPrefix.call(activity(%{text: nil}), %{}, %{"prefix" => "Hi: "})
      assert result.text == "Hi: "
    end

    test "passes through with missing opts" do
      assert {:cont, result} = AddPrefix.call(activity(), %{}, %{})
      assert result.text == "Hello world"
    end

    test "validate_opts requires prefix string" do
      assert :ok = AddPrefix.validate_opts(%{"prefix" => "[!] "})
      assert {:error, _} = AddPrefix.validate_opts(%{})
      assert {:error, _} = AddPrefix.validate_opts(%{"prefix" => 123})
    end
  end

  # --- AddSuffix ---

  describe "AddSuffix" do
    test "appends suffix to text" do
      assert {:cont, result} = AddSuffix.call(activity(), %{}, %{"suffix" => " [end]"})
      assert result.text == "Hello world [end]"
    end

    test "handles nil text" do
      assert {:cont, result} = AddSuffix.call(activity(%{text: nil}), %{}, %{"suffix" => "!"})
      assert result.text == "!"
    end

    test "validate_opts requires suffix string" do
      assert :ok = AddSuffix.validate_opts(%{"suffix" => "!"})
      assert {:error, _} = AddSuffix.validate_opts(%{})
    end
  end

  # --- TextReplace ---

  describe "TextReplace" do
    test "replaces pattern in text" do
      assert {:cont, result} =
               TextReplace.call(activity(), %{}, %{"pattern" => "world", "replacement" => "there"})

      assert result.text == "Hello there"
    end

    test "replaces all occurrences" do
      act = activity(%{text: "aaa bbb aaa"})

      assert {:cont, result} =
               TextReplace.call(act, %{}, %{"pattern" => "aaa", "replacement" => "ccc"})

      assert result.text == "ccc bbb ccc"
    end

    test "validate_opts requires both pattern and replacement" do
      assert :ok = TextReplace.validate_opts(%{"pattern" => "a", "replacement" => "b"})
      assert {:error, _} = TextReplace.validate_opts(%{"pattern" => "a"})
      assert {:error, _} = TextReplace.validate_opts(%{})
    end
  end

  # --- TruncateText ---

  describe "TruncateText" do
    test "truncates long text with default ellipsis" do
      act = activity(%{text: "This is a long message"})

      assert {:cont, result} = TruncateText.call(act, %{}, %{"max_length" => 10})
      assert result.text == "This is a ..."
    end

    test "does not truncate short text" do
      assert {:cont, result} = TruncateText.call(activity(), %{}, %{"max_length" => 100})
      assert result.text == "Hello world"
    end

    test "uses custom ellipsis" do
      act = activity(%{text: "This is a long message"})

      assert {:cont, result} =
               TruncateText.call(act, %{}, %{"max_length" => 10, "ellipsis" => "~"})

      assert result.text == "This is a ~"
    end

    test "validate_opts requires positive integer max_length" do
      assert :ok = TruncateText.validate_opts(%{"max_length" => 160})
      assert {:error, _} = TruncateText.validate_opts(%{"max_length" => 0})
      assert {:error, _} = TruncateText.validate_opts(%{"max_length" => "abc"})
      assert {:error, _} = TruncateText.validate_opts(%{})
    end
  end

  # --- SetMetadata ---

  describe "SetMetadata" do
    test "merges values into metadata" do
      assert {:cont, result} =
               SetMetadata.call(activity(), %{}, %{"values" => %{"source" => "converger"}})

      assert result.metadata == %{"source" => "converger"}
    end

    test "merges with existing metadata" do
      act = activity(%{metadata: %{"existing" => true}})

      assert {:cont, result} =
               SetMetadata.call(act, %{}, %{"values" => %{"new_key" => "val"}})

      assert result.metadata == %{"existing" => true, "new_key" => "val"}
    end

    test "overrides existing keys" do
      act = activity(%{metadata: %{"key" => "old"}})

      assert {:cont, result} =
               SetMetadata.call(act, %{}, %{"values" => %{"key" => "new"}})

      assert result.metadata == %{"key" => "new"}
    end

    test "validate_opts requires values map" do
      assert :ok = SetMetadata.validate_opts(%{"values" => %{"k" => "v"}})
      assert {:error, _} = SetMetadata.validate_opts(%{})
      assert {:error, _} = SetMetadata.validate_opts(%{"values" => "not a map"})
    end
  end

  # --- ContentFilter ---

  describe "ContentFilter" do
    test "halts when text matches a block pattern" do
      assert {:halt, reason} =
               ContentFilter.call(activity(%{text: "buy spam now"}), %{}, %{
                 "block_patterns" => ["spam"]
               })

      assert reason =~ "blocked"
    end

    test "continues when text does not match" do
      assert {:cont, _} =
               ContentFilter.call(activity(), %{}, %{"block_patterns" => ["spam", "blocked"]})
    end

    test "handles multiple patterns" do
      assert {:halt, _} =
               ContentFilter.call(activity(%{text: "click here for deals"}), %{}, %{
                 "block_patterns" => ["spam", "deals"]
               })
    end

    test "validate_opts requires list of strings" do
      assert :ok = ContentFilter.validate_opts(%{"block_patterns" => ["a", "b"]})
      assert {:error, _} = ContentFilter.validate_opts(%{"block_patterns" => [1, 2]})
      assert {:error, _} = ContentFilter.validate_opts(%{})
    end
  end

  # --- Middleware Runner ---

  describe "Middleware.run/2" do
    test "returns activity unchanged for empty transformations" do
      act = activity()
      assert {:ok, ^act} = Middleware.run(act, channel([]))
    end

    test "returns activity unchanged for nil transformations" do
      act = activity()
      assert {:ok, ^act} = Middleware.run(act, %{})
    end

    test "applies single transformation" do
      act = activity()
      chain = [%{"type" => "add_prefix", "prefix" => "[!] "}]
      assert {:ok, result} = Middleware.run(act, channel(chain))
      assert result.text == "[!] Hello world"
    end

    test "chains multiple transformations in order" do
      act = activity(%{text: "Hello world"})

      chain = [
        %{"type" => "add_prefix", "prefix" => ">> "},
        %{"type" => "add_suffix", "suffix" => " <<"},
        %{"type" => "text_replace", "pattern" => "world", "replacement" => "there"}
      ]

      assert {:ok, result} = Middleware.run(act, channel(chain))
      assert result.text == ">> Hello there <<"
    end

    test "halts chain on content filter match" do
      act = activity(%{text: "spam message"})

      chain = [
        %{"type" => "add_prefix", "prefix" => "[!] "},
        %{"type" => "content_filter", "block_patterns" => ["spam"]},
        %{"type" => "add_suffix", "suffix" => " [end]"}
      ]

      assert {:halt, reason} = Middleware.run(act, channel(chain))
      assert reason =~ "blocked"
    end

    test "skips unknown middleware types" do
      act = activity()
      chain = [%{"type" => "unknown_type"}, %{"type" => "add_prefix", "prefix" => "X: "}]
      assert {:ok, result} = Middleware.run(act, channel(chain))
      assert result.text == "X: Hello world"
    end
  end

  # --- Middleware.validate_chain/1 ---

  describe "Middleware.validate_chain/1" do
    test "returns ok for valid chain" do
      chain = [
        %{"type" => "add_prefix", "prefix" => "[!] "},
        %{"type" => "truncate_text", "max_length" => 160}
      ]

      assert :ok = Middleware.validate_chain(chain)
    end

    test "returns ok for empty list" do
      assert :ok = Middleware.validate_chain([])
    end

    test "returns error for unknown type" do
      chain = [%{"type" => "nonexistent"}]
      assert {:error, msg} = Middleware.validate_chain(chain)
      assert msg =~ "unknown"
    end

    test "returns error for invalid opts" do
      chain = [%{"type" => "add_prefix"}]
      assert {:error, msg} = Middleware.validate_chain(chain)
      assert msg =~ "prefix"
    end

    test "returns error for non-list input" do
      assert {:error, _} = Middleware.validate_chain("not a list")
    end
  end

  # --- Registry ---

  describe "Middleware.middleware_for/1" do
    test "resolves known types" do
      assert Middleware.middleware_for("add_prefix") == AddPrefix
      assert Middleware.middleware_for("add_suffix") == AddSuffix
      assert Middleware.middleware_for("text_replace") == TextReplace
      assert Middleware.middleware_for("truncate_text") == TruncateText
      assert Middleware.middleware_for("set_metadata") == SetMetadata
      assert Middleware.middleware_for("content_filter") == ContentFilter
    end

    test "returns nil for unknown type" do
      assert Middleware.middleware_for("unknown") == nil
    end
  end
end
