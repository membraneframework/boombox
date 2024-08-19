defmodule Membrane.HTTPAdaptiveStream.Source do
  @moduledoc false

  use Membrane.Source

  alias Membrane.{Buffer, MP4}
  alias Membrane.MP4.MovieBox.TrackBox

  def_options directory: [
                spec: Path.t(),
                description: "directory containing hls files"
              ]

  def_output_pad :output,
    accepted_format: any_of(%Membrane.H264{}, %Membrane.AAC{}),
    availability: :on_request,
    flow_control: :manual,
    demand_unit: :buffers

  @impl true
  def handle_init(_ctx, opts) do
    {parsed_header, ""} =
      get_prefixed_files(opts.directory, "muxed_header")
      |> List.first()
      |> File.read!()
      |> MP4.Container.parse!()

    %{
      audio_track: %MP4.Track{id: audio_id, stream_format: audio_stream_format},
      video_track: %MP4.Track{id: video_id, stream_format: video_stream_format}
    } =
      parsed_header[:moov].children
      |> Keyword.get_values(:trak)
      |> Enum.map(&TrackBox.unpack/1)
      |> Enum.reduce(fn track, tracks_map ->
        case track.stream_format do
          %Membrane.AAC{} -> %{tracks_map | audio_track: track}
          %Membrane.H264{} -> %{tracks_map | video_track: track}
          _other -> tracks_map
        end
      end)

    segments_filenames = get_prefixed_files(opts.directory, "muxed_segment") |> Enum.sort()

    {audio_buffers, video_buffers} =
      Enum.map(segments_filenames, fn file ->
        %{^audio_id => segment_audio_buffers, ^video_id => segment_video_buffers} =
          get_buffers_from_segment(file)

        {segment_audio_buffers, segment_video_buffers}
      end)
      |> Enum.unzip()
      |> then(fn {audio_buffers, video_buffers} ->
        {List.flatten(audio_buffers), List.flatten(video_buffers)}
      end)

    state =
      %{
        track_data: %{
          audio: %{
            stream_format: audio_stream_format,
            buffers_left: audio_buffers
          },
          video: %{
            stream_format: video_stream_format,
            buffers_left: video_buffers
          }
        }
      }

    {[
       notify_parent:
         {:new_tracks, [{:audio, audio_stream_format}, {:video, video_stream_format}]}
     ], state}
  end

  @impl true
  def handle_pad_added(Pad.ref(:output, id) = pad, _ctx, state) do
    {[stream_format: {pad, state.track_data[id].stream_format}], state}
  end

  @impl true
  def handle_demand(Pad.ref(:output, id) = pad, demand_size, :buffers, _ctx, state) do
    {buffers_to_send, buffers_left} = state.track_data[id].buffers_left |> Enum.split(demand_size)

    actions =
      if buffers_left == [] do
        [buffer: {pad, buffers_to_send}, end_of_stream: pad]
      else
        [buffer: {pad, buffers_to_send}]
      end

    state = put_in(state, [:track_data, id, :buffers_left], buffers_left)

    {actions, state}
  end

  @spec get_buffers_from_segment(Path.t()) :: %{(track_id :: pos_integer()) => [Buffer.t()]}
  defp get_buffers_from_segment(segment_filename) do
    {container, ""} = segment_filename |> File.read!() |> MP4.Container.parse!()

    Enum.zip(
      Keyword.get_values(container, :moof),
      Keyword.get_values(container, :mdat)
    )
    |> Enum.map(fn {moof_box, mdat_box} ->
      traf_box_children = moof_box.children[:traf].children

      sample_sizes =
        traf_box_children[:trun].fields.samples
        |> Enum.map(& &1.sample_size)

      buffers = get_buffers_from_samples(sample_sizes, mdat_box.content)

      {traf_box_children[:tfhd].fields.track_id, buffers}
    end)
    |> Enum.into(%{})
  end

  @spec get_buffers_from_samples([pos_integer()], binary()) :: [Buffer.t()]
  defp get_buffers_from_samples([], <<>>) do
    []
  end

  defp get_buffers_from_samples([first_sample_length | sample_lengths_rest], samples_binary) do
    <<payload::binary-size(first_sample_length), samples_binary_rest::binary>> = samples_binary

    [
      %Buffer{payload: payload}
      | get_buffers_from_samples(sample_lengths_rest, samples_binary_rest)
    ]
  end

  @spec get_prefixed_files(Path.t(), String.t()) :: [Path.t()]
  defp get_prefixed_files(directory, prefix) do
    File.ls!(directory)
    |> Enum.filter(&String.starts_with?(&1, prefix))
    |> Enum.map(&Path.join(directory, &1))
  end
end
