defmodule Boombox.RTMP do
  @moduledoc false

  import Membrane.ChildrenSpec
  require Membrane.Logger
  alias Boombox.Pipeline.{Ready, Wait}

  @type state :: %{server_pid: pid()} | nil

  @spec create_input(URI.t()) :: Wait.t()
  def create_input(uri) do
    uri = URI.new!(uri)
    [target_app | [target_stream_key]] = String.split(uri.path, "/", trim: true)

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

  @spec handle_socket_control(pid(), state()) :: Wait.t()
  def handle_socket_control(source_pid, state) do
    send(state.server_pid, {:rtmp_source_pid, source_pid})
    %Wait{}
  end
end
