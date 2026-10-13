defmodule ConvergerWeb.ETag do
  @moduledoc """
  ETags and `If-Match` preconditions for the management API (ADR-0061), so
  infrastructure-as-code tools can do optimistic concurrency.

  A resource's ETag is derived from its id and `updated_at`: it changes on
  every update. Responses carry it in `ETag`; a `PUT`, `PATCH` or `DELETE`
  with `If-Match` is applied only when one of the listed tags (or `*`)
  matches, `412 precondition_failed` otherwise. Without `If-Match` the
  request is applied unconditionally.
  """

  import Plug.Conn

  alias ConvergerWeb.APIError

  @doc "The strong ETag of a resource with `id` and `updated_at`."
  def etag(%{id: id, updated_at: %DateTime{} = updated_at}) do
    digest =
      :crypto.hash(:sha256, "#{id}:#{DateTime.to_unix(updated_at, :microsecond)}")
      |> Base.url_encode64(padding: false)
      |> binary_part(0, 22)

    ~s("#{digest}")
  end

  @doc "Sets the `ETag` response header for `resource`."
  def put_etag(conn, resource), do: put_resp_header(conn, "etag", etag(resource))

  @doc """
  Checks the request's `If-Match` against `resource`: `:ok`, or
  `{:error, %APIError{}}` (`precondition_failed`) for the fallback controller.
  """
  def check_if_match(conn, resource) do
    case get_req_header(conn, "if-match") do
      [] ->
        :ok

      values ->
        tags =
          values
          |> Enum.flat_map(&String.split(&1, ","))
          |> Enum.map(&String.trim/1)

        if "*" in tags or etag(resource) in tags do
          :ok
        else
          {:error, APIError.new(:precondition_failed, nil, %{"current_etag" => etag(resource)})}
        end
    end
  end
end
