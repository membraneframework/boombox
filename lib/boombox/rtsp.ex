defmodule Boombox.RTSP do
  @moduledoc false
  import Membrane.ChildrenSpec

  require Membrane.Pad

  alias Membrane.RTP
  alias Boombox.Pipeline.{Ready, Wait}

  @spec create_input(URI.t()) :: Wait.t()
  def create_input(uri) do
    port = Enum.random(5_000..65_000)

    spec =
      child(:rtsp_source, %Membrane.RTSP.Source{
        transport: {:udp, port, port + 20},
        allowed_media_types: [:video, :audio],
        stream_uri: uri,
        on_connection_closed: :send_eos
      })

    %Wait{actions: [spec: spec]}
  end

  @spec handle_input_tracks([{RTP.ssrc_t(), map()}]) :: Ready.t()
  def handle_input_tracks(tracks) do
    track_builders =
      Map.new(tracks, fn
        {ssrc, %{rtpmap: %{encoding: "H264"}} = track} ->
          {spss, ppss} =
            case track.fmtp.sprop_parameter_sets do
              nil -> {[], []}
              parameter_sets -> {parameter_sets.sps, parameter_sets.pps}
            end

          spec =
            get_child(:rtsp_source)
            |> via_out(Membrane.Pad.ref(:output, ssrc))
            |> child(:rtsp_in_h264_parser, %Membrane.H264.Parser{spss: spss, ppss: ppss})

          {:video, spec}

        {ssrc, %{rtpmap: %{encoding: "MP4A-LATM"}}} ->
          spec =
            get_child(:rtsp_source)
            |> via_out(Membrane.Pad.ref(:output, ssrc))
            |> child(:rtsp_in_aac_parser, Membrane.AAC.Parser)
            |> child(:rtsp_in_aac_decoder, Membrane.AAC.FDK.Decoder)

          {:audio, spec}

        {_ssrc, %{rtpmap: %{encoding: unsupported_encoding}}} ->
          raise "Received unsupported encoding with RTSP: #{inspect(unsupported_encoding)}"
      end)

    %Ready{track_builders: track_builders}
  end
end
