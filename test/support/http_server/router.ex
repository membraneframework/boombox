defmodule HTTPServer.Router do
  use Plug.Router

  require Logger

  plug(:match)
  plug(:dispatch)

  @impl true
  def call(conn, opts) do
    assign(conn, :directory, opts.directory)
    |> super(opts)
  end

  post "/hls_output/:filename" do
    hls_dir = conn.assigns.directory

    file_path = Path.join(hls_dir, filename)
    conn = write_body_to_file(conn, file_path)
    send_resp(conn, 200, "File successfully written")
  end

  delete "/hls_output/:filename" do
    hls_dir = conn.assigns.directory

    case Path.join(hls_dir, filename) |> File.rm() do
      :ok ->
        send_resp(conn, 200, "File deleted successfully")

      {:error, error} ->
        send_resp(conn, 409, "Error deleting file: #{inspect(error)}")
    end
  end

  match _ do
    send_resp(conn, 404, "Not found")
  end

  defp write_body_to_file(conn, file_path) do
    case read_body(conn) do
      {:ok, body, conn} ->
        File.write(file_path, body)
        conn

      {:more, partial_body, conn} ->
        File.write(file_path, partial_body)
        write_body_to_file(conn, file_path)
    end
  end
end
