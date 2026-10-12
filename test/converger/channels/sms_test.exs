defmodule Converger.Channels.SmsTest do
  use ExUnit.Case, async: true

  alias Converger.Channels.Sms

  doctest Sms

  describe "normalize_e164/2" do
    test "keeps E.164 and strips formatting" do
      assert Sms.normalize_e164("+1 (415) 555-0100") == {:ok, "+14155550100"}
      assert Sms.normalize_e164("+44 7700.900.000") == {:ok, "+447700900000"}
    end

    test "turns a 00 prefix and bare international digits into +" do
      assert Sms.normalize_e164("0044 7700 900000") == {:ok, "+447700900000"}
      assert Sms.normalize_e164("14155550100") == {:ok, "+14155550100"}
    end

    test "needs a default country code for national numbers" do
      assert Sms.normalize_e164("0532 123 45 67") == :error
      assert Sms.normalize_e164("0532 123 45 67", "90") == {:ok, "+905321234567"}
      assert Sms.normalize_e164("0532 123 45 67", "+90") == {:ok, "+905321234567"}
    end

    test "rejects what is not a phone number" do
      assert Sms.normalize_e164("ACME") == :error
      assert Sms.normalize_e164("12345") == :error
      assert Sms.normalize_e164("+0123456789") == :error
      assert Sms.normalize_e164("+1234567890123456") == :error
      assert Sms.normalize_e164(nil) == :error
    end
  end

  test "participant_id/2 keeps short codes and sender ids as they are" do
    assert Sms.participant_id("14155550100") == "+14155550100"
    assert Sms.participant_id("ACME") == "ACME"
    assert Sms.participant_id(" 12345 ") == "12345"
  end

  describe "segments/1" do
    test "GSM-7" do
      assert Sms.segments("") == {:gsm7, 0}
      assert Sms.segments(String.duplicate("a", 160)) == {:gsm7, 1}
      assert Sms.segments(String.duplicate("a", 161)) == {:gsm7, 2}
      assert Sms.segments(String.duplicate("a", 306)) == {:gsm7, 2}
      assert Sms.segments(String.duplicate("a", 307)) == {:gsm7, 3}
    end

    test "extension characters take two septets" do
      assert Sms.segments(String.duplicate("€", 80)) == {:gsm7, 1}
      assert Sms.segments(String.duplicate("€", 81)) == {:gsm7, 2}
    end

    test "UCS-2 for anything outside GSM-7, emoji count twice" do
      assert Sms.segments(String.duplicate("ı", 70)) == {:ucs2, 1}
      assert Sms.segments(String.duplicate("ı", 71)) == {:ucs2, 2}
      assert Sms.segments(String.duplicate("😀", 35)) == {:ucs2, 1}
      assert Sms.segments(String.duplicate("😀", 36)) == {:ucs2, 2}
    end
  end

  describe "check_length/2" do
    test "honours the channel max_segments" do
      channel = %{config: %{"max_segments" => "2"}}
      assert Sms.check_length(channel, String.duplicate("a", 306)) == {:ok, 2}
      assert {:error, message} = Sms.check_length(channel, String.duplicate("a", 307))
      assert message =~ "3 gsm7 segments"
    end

    test "defaults to 10 segments" do
      channel = %{config: %{}}
      assert {:ok, 10} = Sms.check_length(channel, String.duplicate("a", 1530))
      assert {:error, _} = Sms.check_length(channel, String.duplicate("a", 1531))
    end
  end

  describe "opt-out keywords" do
    test "classifies whole-message keywords, case-insensitive" do
      assert Sms.opt_keyword(" stop ") == :opt_out
      assert Sms.opt_keyword("Unsubscribe") == :opt_out
      assert Sms.opt_keyword("START") == :opt_in
      assert Sms.opt_keyword("please stop") == nil
      assert Sms.opt_keyword("HELP") == nil
    end

    test "apply_opt_keyword/2 turns a keyword into an event" do
      message = %{"type" => "message", "text" => "STOP", "metadata" => %{"a" => 1}}

      assert %{"type" => "event", "opt_out" => "stop", "metadata" => %{"smsOptOut" => "stop"}} =
               Sms.apply_opt_keyword(message)

      assert Sms.apply_opt_keyword(%{"text" => "hi"}) == %{"text" => "hi"}
      assert %{"opt_out" => "start"} = Sms.apply_opt_keyword(%{"text" => "hi"}, :opt_in)
    end
  end
end
