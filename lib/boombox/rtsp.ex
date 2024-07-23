defmodule Boombox.RTSP do
  @moduledoc false
  import Membrane.ChildrenSpec

  alias Boombox.Pipeline.{Ready, Wait}
  require Membrane.Pad
  @type state :: %{server_pid: pid()} | nil

  @spec create_input(URI.t()) :: Wait.t()
  def create_input(uri) do

    spec = [
      child(:rtsp_source, %Membrane.RTSP.Source{
        transport: {:udp, 20000, 20005},
        allowed_media_types: [:video],
        stream_uri: uri
      }),
    ]

    %Wait{actions: [spec: spec]}
  end

  def handle_input_tracks(ssrc, track) do
    # {spss, ppss} =
    #   case track.fmtp.sprop_parameter_sets do
    #     nil -> {[], []}
    #     parameter_sets -> {parameter_sets.sps, parameter_sets.pps}
    #   end

    # spec = [
    #   get_child(:rtsp_source)
    #   |> via_out(Membrane.Pad.ref(:output, ssrc))
    #   |> child(
    #     :rtsp_h264_parser,
    #     %Membrane.H264.Parser{
    #       spss: spss,
    #       ppss: ppss,
    #       generate_best_effort_timestamps: %{framerate: {60, 1}}
    #     }
    #   )
    # ]

    track_builders = %{
      # audio: get_child(:aac_decoder),
      # video: get_child(:rtsp_h264_parser)
      video: get_child(:rtsp_source) |> via_out(Membrane.Pad.ref(:output, ssrc))
    }

    %Ready{
      # spec_builder: spec,
      track_builders: track_builders
    }

  end

end
