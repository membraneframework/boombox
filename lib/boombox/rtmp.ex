defmodule Boombox.RTMP do
  @moduledoc false

  import Membrane.ChildrenSpec
  require Membrane.Logger
  alias Boombox.Pipeline.{Ready, Wait}

  @type state :: %{server_pid: pid()} | nil

  @spec create_input(URI.t()) :: Wait.t()
  def create_input(uri) do
    uri = URI.new!(uri)

    {target_app, target_stream_key} = get_app_stream_key_from_path(uri.path)

    boombox = self()

    new_client_callback = fn client_ref, app, stream_key ->
      if app == target_app and stream_key == target_stream_key do
        send(boombox, {:rtmp_client_ref, client_ref})
      else
        Membrane.Logger.warning("Unexpected client connected on /#{app}/#{stream_key}")
      end
    end

    # Run the standalone server
    {:ok, _server} =
      Membrane.RTMP.Server.start_link(
        handler: %Membrane.RTMP.Source.ClientHandler{controlling_process: self()},
        port: uri.port,
        use_ssl?: false,
        new_client_callback: new_client_callback,
        client_timeout: 1_000
      )

    %Wait{}
  end

  @spec handle_connection(pid()) :: Ready.t()
  def handle_connection(client_ref) do
    spec = [
      child(:rtmp_source, %Membrane.RTMP.SourceBin{client_ref: client_ref})
      |> via_out(:audio)
      |> child(Membrane.AAC.Parser)
      |> child(:aac_decoder, Membrane.AAC.FDK.Decoder)
    ]

    track_builders = %{
      audio: get_child(:aac_decoder),
      video: get_child(:rtmp_source) |> via_out(:video)
    }

    %Ready{spec_builder: spec, track_builders: track_builders}
  end

  defp get_app_stream_key_from_path(path) do
    case String.split(path, "/", trim: true) do
      [app | [stream_key]] ->
        {app, stream_key}

      _error ->
        raise "Invalid RTMP URI path #{inspect(path)}, expected /{app}/{stream_key}"
    end
  end
end
