defmodule Converger.RoutingRules.ConditionsTest do
  use ExUnit.Case, async: true

  alias Converger.RoutingRules.Conditions

  defp context(overrides \\ %{}) do
    activity =
      Map.merge(
        %{
          type: "message",
          sender: "905551112233",
          text: "Hello, I need a refund for order 42",
          metadata: %{"vip" => true, "department" => "sales", "score" => 7, "tags" => ["a", "b"]},
          inserted_at: ~U[2026-10-12 09:30:00.000000Z]
        },
        overrides
      )

    conversation = %{metadata: %{"region" => "eu"}, status: "active"}

    participant = %{
      external_id: "905551112233",
      display_name: "Sheena",
      metadata: %{"tier" => "gold"}
    }

    Conditions.context(activity, conversation, participant)
  end

  defp p(field, op, value), do: %{"field" => field, "op" => op, "value" => value}

  describe "normalize/1" do
    test "nil is empty and a list is an all group with string keys" do
      assert Conditions.normalize(nil) == %{}

      assert Conditions.normalize([%{field: "type", op: "eq", value: "message"}]) ==
               %{"all" => [p("type", "eq", "message")]}
    end
  end

  describe "matches?/2" do
    test "an empty condition matches everything" do
      assert Conditions.matches?(%{}, context())
    end

    test "eq and neq over activity, conversation and participant fields" do
      assert Conditions.matches?(p("metadata.vip", "eq", true), context())
      refute Conditions.matches?(p("metadata.vip", "eq", true), context(%{metadata: %{}}))
      assert Conditions.matches?(p("metadata.vip", "neq", true), context(%{metadata: %{}}))
      assert Conditions.matches?(p("type", "eq", "message"), context())
      assert Conditions.matches?(p("sender", "eq", "905551112233"), context())
      assert Conditions.matches?(p("conversation.metadata.region", "eq", "eu"), context())
      assert Conditions.matches?(p("conversation.status", "eq", "active"), context())
      assert Conditions.matches?(p("participant.metadata.tier", "eq", "gold"), context())
      assert Conditions.matches?(p("participant.display_name", "eq", "Sheena"), context())
      # 7 equals 7.0 (JSON numbers).
      assert Conditions.matches?(p("metadata.score", "eq", 7.0), context())
    end

    test "in, contains, exists" do
      assert Conditions.matches?(p("metadata.department", "in", ["sales", "billing"]), context())
      refute Conditions.matches?(p("metadata.department", "in", ["support"]), context())
      # A list field is in the values when any element is.
      assert Conditions.matches?(p("metadata.tags", "in", ["b", "z"]), context())
      assert Conditions.matches?(p("text", "contains", "refund"), context())
      assert Conditions.matches?(p("metadata.tags", "contains", "a"), context())
      assert Conditions.matches?(p("metadata", "contains", "vip"), context())
      assert Conditions.matches?(%{"field" => "metadata.vip", "op" => "exists"}, context())
      assert Conditions.matches?(p("metadata.missing", "exists", false), context())
      refute Conditions.matches?(p("metadata.missing", "exists", true), context())
    end

    test "gt and lt compare numbers or strings, nothing else" do
      assert Conditions.matches?(p("metadata.score", "gt", 5), context())
      assert Conditions.matches?(p("metadata.score", "lt", 10), context())
      refute Conditions.matches?(p("metadata.score", "gt", "5"), context())
      refute Conditions.matches?(p("metadata.missing", "lt", 10), context())
    end

    test "regex matches strings only" do
      assert Conditions.matches?(p("text", "regex", "order \\d+"), context())
      refute Conditions.matches?(p("text", "regex", "^order"), context())
      refute Conditions.matches?(p("metadata.score", "regex", "7"), context())
    end

    test "a catastrophic regex hits the match limit and does not match" do
      subject = String.duplicate("a", 30) <> "!"
      refute Conditions.matches?(p("text", "regex", "^(a+)+$"), context(%{text: subject}))
    end

    test "all, any and not groups" do
      vip_sales = %{
        "all" => [p("metadata.vip", "eq", true), p("metadata.department", "eq", "sales")]
      }

      assert Conditions.matches?(vip_sales, context())
      refute Conditions.matches?(vip_sales, context(%{metadata: %{"vip" => true}}))

      either = %{"any" => [p("type", "eq", "event"), p("metadata.vip", "eq", true)]}
      assert Conditions.matches?(either, context())

      assert Conditions.matches?(%{"not" => p("type", "eq", "typing")}, context())
    end

    test "time windows use the activity time, shifted by utc_offset_minutes" do
      # 09:30 UTC on Monday 2026-10-12.
      business_hours = %{
        "all" => [p("time.hour", "gt", 8), p("time.hour", "lt", 17), p("time.weekday", "lt", 6)]
      }

      assert Conditions.matches?(business_hours, context())

      refute Conditions.matches?(
               business_hours,
               context(%{inserted_at: ~U[2026-10-12 20:00:00Z]})
             )

      assert Conditions.matches?(p("time.minute_of_day", "eq", 570), context())
      assert Conditions.matches?(p("time.date", "eq", "2026-10-12"), context())

      # 09:30 UTC is 12:30 at UTC+3.
      istanbul = Map.put(p("time.hour", "eq", 12), "utc_offset_minutes", 180)
      assert Conditions.matches?(istanbul, context())
    end
  end

  describe "validate/1" do
    test "accepts valid conditions" do
      assert :ok = Conditions.validate(%{})
      assert :ok = Conditions.validate(p("metadata.vip", "eq", true))

      assert :ok =
               Conditions.validate(%{
                 "any" => [p("text", "regex", "^hi"), p("type", "in", ["message"])]
               })

      assert :ok =
               Conditions.validate(Map.put(p("time.hour", "gt", 8), "utc_offset_minutes", -300))
    end

    test "rejects unknown fields, ops and keys" do
      assert {:error, message} = Conditions.validate(p("channel", "eq", "x"))
      assert message =~ "unknown field channel"
      assert {:error, message} = Conditions.validate(p("type", "like", "x"))
      assert message =~ "unknown op"
      assert {:error, message} = Conditions.validate(Map.put(p("type", "eq", "x"), "extra", 1))
      assert message =~ "unknown keys"
      assert {:error, _} = Conditions.validate(p("metadata", "eq", 1))
      assert {:error, _} = Conditions.validate(p("participant.phone", "eq", 1))

      assert {:error, _} =
               Conditions.validate(Map.put(p("type", "eq", "x"), "utc_offset_minutes", 60))
    end

    test "rejects bad values" do
      assert {:error, _} = Conditions.validate(%{"field" => "type", "op" => "eq"})
      assert {:error, _} = Conditions.validate(p("type", "in", "message"))
      assert {:error, _} = Conditions.validate(p("metadata.n", "gt", true))
      assert {:error, _} = Conditions.validate(p("metadata.n", "exists", "yes"))
      assert {:error, _} = Conditions.validate(p("type", "in", Enum.to_list(1..101)))
    end

    test "regexes must compile and are bounded in length" do
      assert {:error, message} = Conditions.validate(p("text", "regex", "(unclosed"))
      assert message =~ "does not compile"

      long = String.duplicate("a", Conditions.max_regex_bytes() + 1)
      assert {:error, message} = Conditions.validate(p("text", "regex", long))
      assert message =~ "longer than 256 bytes"
      assert {:error, _} = Conditions.validate(p("text", "regex", 5))
    end

    test "bounds groups, depth and the number of predicates" do
      assert {:error, _} = Conditions.validate(%{"all" => []})
      assert {:error, _} = Conditions.validate(%{"all" => [p("type", "eq", "x")], "any" => []})

      deep =
        Enum.reduce(1..5, p("type", "eq", "x"), fn _, acc -> %{"all" => [acc]} end)

      assert {:error, message} = Conditions.validate(deep)
      assert message =~ "nested deeper"

      many = %{"any" => for(i <- 1..33, do: p("metadata.k", "eq", i))}
      assert {:error, message} = Conditions.validate(many)
      assert message =~ "33 predicates"
      assert {:error, _} = Conditions.validate("type == message")
    end
  end
end
