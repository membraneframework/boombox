defmodule Boombox.RTMP do
  @moduledoc false

  import Membrane.ChildrenSpec
  require Membrane.Logger
  alias Boombox.Pipeline.{Ready, Wait}
  alias Membrane.RTMP

  @spec create_input(String.t(), pid()) :: Wait.t()
  def create_input(uri, utility_supervisor) do
    {use_ssl?, port, target_app, target_stream_key} = RTMP.Utils.parse_url(uri)

    boombox = self()

    new_client_callback = fn client_ref, app, stream_key ->
      if app == target_app and stream_key == target_stream_key do
        send(boombox, {:rtmp_client_ref, client_ref})
      else
        Membrane.Logger.warning("Unexpected client connected on /#{app}/#{stream_key}")
      end
    end

    server_options = %{
      handler: %Membrane.RTMP.Source.ClientHandler{controlling_process: self()},
      port: port,
      use_ssl?: use_ssl?,
      new_client_callback: new_client_callback,
      client_timeout: 1_000
    }

    {:ok, _server} =
      Membrane.UtilitySupervisor.start_link_child(
        utility_supervisor,
        {Membrane.RTMP.Server, server_options}
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
end
