defmodule Boombox.RTMP do
  @moduledoc false

  import Membrane.ChildrenSpec
  alias Boombox.Pipeline.{Ready, Wait}

  @type state :: %{server_pid: pid()} | nil

  @spec create_input(URI.t(), pid()) :: Wait.t()
  def create_input(uri, utility_supervisor) do
    uri = URI.new!(uri)
    {:ok, ip} = :inet.getaddr(~c"#{uri.host}", :inet)

    boombox = self()

    server_options = %Membrane.RTMP.Source.TcpServer{
      port: uri.port,
      listen_options: [:binary, packet: :raw, active: false, ip: ip],
      socket_handler: fn socket ->
        send(boombox, {:rtmp_tcp_server, self(), socket})

        receive do
          {:rtmp_source_pid, pid} -> {:ok, pid}
          :rtmp_already_connected -> {:error, :rtmp_already_connected}
        end
      end
    }

    {:ok, _pid} =
      Membrane.UtilitySupervisor.start_link_child(
        utility_supervisor,
        {Membrane.RTMP.Source.TcpServer, server_options}
      )

    %Wait{}
  end

  @spec handle_connection(pid(), :gen_tcp.socket() | :ssl.sslsocket(), state()) ::
          {Ready.t(), state()}
  def handle_connection(server_pid, socket, nil = _state) do
    spec = [
      child(:rtmp_source, %Membrane.RTMP.SourceBin{socket: socket})
      |> via_out(:audio)
      |> child(Membrane.AAC.Parser)
      |> child(:aac_decoder, Membrane.AAC.FDK.Decoder)
    ]

    track_builders = %{
      audio: get_child(:aac_decoder),
      video: get_child(:rtmp_source) |> via_out(:video)
    }

    {%Ready{spec_builder: spec, track_builders: track_builders}, %{server_pid: server_pid}}
  end

  def handle_connection(_server_pid, _socket, state) do
    send(state.server_pid, :rtmp_already_connected)
    {%Wait{}, state}
  end

  @spec handle_socket_control(pid(), state()) :: Wait.t()
  def handle_socket_control(source_pid, state) do
    send(state.server_pid, {:rtmp_source_pid, source_pid})
    %Wait{}
  end
end
