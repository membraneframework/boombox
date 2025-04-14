defmodule Boombox.RTSP do
  @moduledoc false
  import Membrane.ChildrenSpec

  require Membrane.Pad

  require Membrane.Logger
  alias Membrane.{RTP, RTSP}
  alias Boombox.InternalBin.{Ready, State, Wait}

  @type state :: %{
          set_up_tracks: %{
            optional(:audio) => Membrane.RTSP.Source.track(),
            optional(:video) => Membrane.RTSP.Source.track()
          },
          tracks_left_to_link: non_neg_integer(),
          track_builders: Boombox.InternalBin.track_builders()
        }

  @spec create_input(URI.t()) :: Wait.t()
  def create_input(uri) do
    port = Enum.random(5_000..65_000)

    spec =
      child(:rtsp_source, %RTSP.Source{
        transport: {:udp, port, port + 20},
        allowed_media_types: [:video, :audio],
        stream_uri: uri,
        on_connection_closed: :send_eos
      })

    %Wait{actions: [spec: spec]}
  end

  @spec handle_set_up_tracks([RTSP.Source.track()], State.t()) :: {Wait.t(), State.t()}
  def handle_set_up_tracks(tracks, state) do
    rtsp_state = %{
      set_up_tracks: Map.new(tracks, fn track -> {track.type, track} end),
      tracks_left_to_link: length(tracks),
      track_builders: %{}
    }

    {%Wait{}, %{state | rtsp_state: rtsp_state}}
  end

  @spec handle_input_track(RTP.ssrc(), RTSP.Source.track(), State.t()) ::
          {Ready.t() | Wait.t(), State.t()}
  def handle_input_track(ssrc, track, state) do
    track_builders = state.rtsp_state.track_builders

    {spec, track_builders} =
      case track do
        %{type: type} when is_map_key(track_builders, type) ->
          Membrane.Logger.warning(
            "Tried to link a track of type #{inspect(type)}, but another track
            of that type has already been received"
          )

          spec =
            get_child(:rtsp_source)
            |> via_out(Membrane.Pad.ref(:output, ssrc))

          {spec, track_builders}

        %{rtpmap: %{encoding: "H264"}} ->
          {spss, ppss} =
            case track.fmtp.sprop_parameter_sets do
              nil -> {[], []}
              parameter_sets -> {parameter_sets.sps, parameter_sets.pps}
            end

          video_spec =
            get_child(:rtsp_source)
            |> via_out(Membrane.Pad.ref(:output, ssrc))
            |> child(:rtsp_in_h264_parser, %Membrane.H264.Parser{spss: spss, ppss: ppss})

          {[], Map.put(track_builders, :video, video_spec)}

        %{rtpmap: %{encoding: "mpeg4-generic"}, type: :audio} ->
          audio_spec =
            get_child(:rtsp_source)
            |> via_out(Membrane.Pad.ref(:output, ssrc))
            |> child(:rtsp_in_aac_parser, Membrane.AAC.Parser)

          {[], Map.put(track_builders, :audio, audio_spec)}

        %{rtpmap: %{encoding: unsupported_encoding}} ->
          raise "Received unsupported encoding with RTSP: #{inspect(unsupported_encoding)}"
      end

    state =
      state
      |> Bunch.Struct.put_in([:rtsp_state, :track_builders], track_builders)
      |> Bunch.Struct.update_in([:rtsp_state, :tracks_left_to_link], &(&1 - 1))

    if state.rtsp_state.tracks_left_to_link == 0 do
      {%Ready{actions: [spec: spec], track_builders: track_builders}, state}
    else
      {%Wait{actions: [spec: spec]}, state}
    end
  end
end
