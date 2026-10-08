defmodule ConvergerWeb.MultipartParser do
  @moduledoc """
  `Plug.Parsers.MULTIPART` with a request size limit derived at runtime from
  `Converger.Uploads.max_file_size/0` (plus 1 MB for the other form fields),
  instead of Plug's fixed 8 MB default.
  """

  @behaviour Plug.Parsers

  @multipart Plug.Parsers.MULTIPART
  @overhead 1_000_000

  @impl true
  def init(opts), do: opts

  @impl true
  def parse(conn, "multipart", subtype, headers, opts) do
    length = Converger.Uploads.max_file_size() + @overhead
    opts = @multipart.init([length: length] ++ opts)
    @multipart.parse(conn, "multipart", subtype, headers, opts)
  end

  def parse(conn, _type, _subtype, _headers, _opts), do: {:next, conn}
end
