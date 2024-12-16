defmodule Boombox.HLS do
  @moduledoc false

  defmodule DTSer do
    use Membrane.Filter

    def_input_pad :input,
      accepted_format: _any

    def_output_pad :output,
      accepted_format: _any

    @impl true
    def handle_init(_ctx, _opts) do
      {[], %{dts: 0}}
    end

    @impl true
    def handle_buffer(:input, buffer, _ctx, state) do
      dts = if buffer.metadata.h264.key_frame?, do: buffer.pts, else: state.dts
      buffer = %{buffer | dts: dts}
      state = %{state | dts: buffer.dts + 1}
      # IO.inspect(buffer.metadata)
      # state = %{state | dts: state.dts + 40_000_000}

      {[buffer: {:output, buffer}], state}
    end
  end

  import Membrane.ChildrenSpec

  require Membrane.Pad, as: Pad
  alias Boombox.Pipeline.Ready
  alias Membrane.H264
  alias Membrane.Time

  @spec link_output(
          Path.t(),
          Boombox.Pipeline.track_builders(),
          Membrane.ChildrenSpec.t()
        ) :: Ready.t()
  def link_output(location, track_builders, spec_builder) do
    {directory, manifest_name} =
      if Path.extname(location) == ".m3u8" do
        {Path.dirname(location), Path.basename(location, ".m3u8")}
      else
        {location, "index"}
      end

    hls_mode =
      if Map.keys(track_builders) == [:video], do: :separate_av, else: :muxed_av

    spec =
      [
        spec_builder,
        child(
          :hls_sink_bin,
          %Membrane.HTTPAdaptiveStream.SinkBin{
            manifest_name: manifest_name,
            manifest_module: Membrane.HTTPAdaptiveStream.HLS,
            storage: %Membrane.HTTPAdaptiveStream.Storages.FileStorage{
              directory: directory
            },
            hls_mode: hls_mode,
            mp4_parameters_in_band?: true,
            target_window_duration: Membrane.Time.seconds(20)
          }
        ),
        Enum.map(track_builders, fn
          {:audio, builder} ->
            builder
            |> child(:hls_audio_transcoder, %Boombox.Transcoder{
              output_stream_format: Membrane.AAC
            })
            |> via_in(Pad.ref(:input, :audio),
              options: [encoding: :AAC, segment_duration: Time.milliseconds(2000)]
            )
            |> get_child(:hls_sink_bin)

          {:video, builder} ->
            builder
            |> child(:hls_video_transcoder, %Boombox.Transcoder{
              output_stream_format: %H264{alignment: :au, stream_structure: :avc3}
            })
            |> child(DTSer)
            |> child(%Membrane.Debug.Filter{handle_buffer: &IO.inspect({&1.pts, &1.dts})})
            |> via_in(Pad.ref(:input, :video),
              options: [encoding: :H264, segment_duration: Time.milliseconds(2000)]
            )
            |> get_child(:hls_sink_bin)
        end)
      ]

    %Ready{actions: [spec: spec]}
  end
end
