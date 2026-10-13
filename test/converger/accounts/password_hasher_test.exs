defmodule Converger.Accounts.PasswordHasherTest do
  # Changes the global :password_hasher setting.
  use ExUnit.Case, async: false

  alias Converger.Accounts.{AdminUser, PasswordHasher}

  @bcrypt_compiled Code.ensure_loaded?(Bcrypt)

  setup do
    previous = Application.get_env(:converger, :password_hasher)
    on_exit(fn -> Application.put_env(:converger, :password_hasher, previous) end)
  end

  describe "with Pbkdf2 configured" do
    setup do
      Application.put_env(:converger, :password_hasher, Pbkdf2)
    end

    test "hashes with PBKDF2 and verifies the result" do
      hash = PasswordHasher.hash_pwd_salt("correct horse")

      assert "$pbkdf2-sha512$" <> _ = hash
      assert PasswordHasher.verify_pass("correct horse", hash)
      refute PasswordHasher.verify_pass("wrong horse", hash)
    end

    test "user changesets store a PBKDF2 hash that valid_password? accepts" do
      changeset =
        AdminUser.registration_changeset(%AdminUser{}, %{
          email: "ops@example.com",
          password: "correct horse",
          name: "Ops"
        })

      user = Ecto.Changeset.apply_changes(changeset)

      assert "$pbkdf2-" <> _ = user.password_hash
      assert user.password == "correct horse"
      assert AdminUser.valid_password?(user, "correct horse")
      refute AdminUser.valid_password?(user, "wrong horse")
    end

    if @bcrypt_compiled do
      test "still verifies existing bcrypt hashes" do
        hash = Bcrypt.hash_pwd_salt("correct horse")

        assert PasswordHasher.verify_pass("correct horse", hash)
        refute PasswordHasher.verify_pass("wrong horse", hash)
      end
    else
      test "rejects bcrypt hashes when bcrypt_elixir is not compiled in" do
        hash = "$2b$04$" <> String.duplicate("a", 53)

        log =
          ExUnit.CaptureLog.capture_log(fn ->
            refute PasswordHasher.verify_pass("correct horse", hash)
          end)

        assert log =~ "not compiled in"
      end
    end
  end

  if @bcrypt_compiled do
    describe "with Bcrypt configured" do
      setup do
        Application.put_env(:converger, :password_hasher, Bcrypt)
      end

      test "hashes with bcrypt and still verifies PBKDF2 hashes" do
        assert "$2b$" <> _ = PasswordHasher.hash_pwd_salt("correct horse")

        hash = Pbkdf2.hash_pwd_salt("correct horse")
        assert PasswordHasher.verify_pass("correct horse", hash)
        refute PasswordHasher.verify_pass("wrong horse", hash)
      end
    end
  end

  test "an unrecognised hash never verifies" do
    refute PasswordHasher.verify_pass("x", "plaintext")
    refute PasswordHasher.verify_pass("x", "")
  end

  test "no_user_verify/0 returns false" do
    refute PasswordHasher.no_user_verify()
  end
end
