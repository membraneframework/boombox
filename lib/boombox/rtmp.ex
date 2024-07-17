defmodule Boombox.RTMP do
  @moduledoc false

  import Membrane.ChildrenSpec
  alias Boombox.Pipeline.{Ready, Wait}

  @type state :: %{server_pid: pid()} | nil

  @spec create_input(URI.t(), pid()) :: {Wait.t(), state()}
  def create_input(uri, utility_supervisor) do

    uri = URI.new!(uri)
    [app | [stream_key]] = String.split(uri.path, "/", [trim: true])

    boombox = self()

    new_client_callback = fn client_ref, app, stream_key ->
      send(boombox, {:rtmp_client_ref, client_ref, app, stream_key})
    end

    # Run the standalone server
    {:ok, server} =
      Membrane.RTMP.Server.start_link(
        handler: %Membrane.RTMP.Source.ClientHandler{controlling_process: self()},
        port: uri.port,
        use_ssl?: false,
        new_client_callback: new_client_callback,
        client_timeout: 1_000
      )

    %Wait{}
  end

  # @spec handle_connection(pid(), :gen_tcp.socket() | :ssl.sslsocket(), state()) :: {Ready.t(), state()}
  def handle_connection(client_ref, state) do
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

    {%Ready{spec_builder: spec, track_builders: track_builders}, state}
  end

  # @spec handle_connection(pid(), :gen_tcp.socket() | :ssl.sslsocket(), state()) ::
  #         {Ready.t(), state()}
  # def handle_connection(client_ref, state) do
  #   spec = [
  #     child(:rtmp_source, %Membrane.RTMP.SourceBin{client_ref: client_ref})
  #     |> via_out(:audio)
  #     |> child(Membrane.AAC.Parser)
  #     |> child(:aac_decoder, Membrane.AAC.FDK.Decoder)
  #   ]

  #   track_builders = %{
  #     audio: get_child(:aac_decoder),
  #     video: get_child(:rtmp_source) |> via_out(:video)
  #   }

  #   {%Ready{spec_builder: spec, track_builders: track_builders}, state}
  # end

  # def handle_connection(_server_pid, _socket, state) do
  #   send(state.server_pid, :rtmp_already_connected)
  #   {%Wait{}, state}
  # end

  @spec handle_socket_control(pid(), state()) :: Wait.t()
  def handle_socket_control(source_pid, state) do
    send(state.server_pid, {:rtmp_source_pid, source_pid})
    %Wait{}
  end
end
