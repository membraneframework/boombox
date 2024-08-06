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
    {parsed_video_header, ""} =
      get_prefixed_files(opts.directory, "video_header")
      |> List.first()
      |> File.read!()
      |> MP4.Container.parse!()

    %MP4.Track{stream_format: video_stream_format} =
      TrackBox.unpack(parsed_video_header[:moov].children[:trak])

    video_segments_filenames = get_prefixed_files(opts.directory, "video_segment") |> Enum.sort()

    {parsed_audio_header, ""} =
      get_prefixed_files(opts.directory, "audio_header")
      |> List.first()
      |> File.read!()
      |> MP4.Container.parse!()

    %MP4.Track{stream_format: audio_stream_format} =
      TrackBox.unpack(parsed_audio_header[:moov].children[:trak])

    audio_segment_filenames = get_prefixed_files(opts.directory, "audio_segment") |> Enum.sort()

    state =
      %{
        track_data: %{
          video: %{
            stream_format: video_stream_format,
            segment_filenames: video_segments_filenames,
            current_segment_samples: []
          },
          audio: %{
            stream_format: audio_stream_format,
            segment_filenames: audio_segment_filenames,
            current_segment_samples: []
          }
        }
      }

    {[
       notify_parent:
         {:new_tracks, [{:audio, audio_stream_format}, {:video, video_stream_format}]}
     ], state}
  end

  @impl true
  def handle_pad_added(:input, _ctx, state) do
    {[], state}
  end

  def handle_pad_added(Pad.ref(:output, id) = pad, _ctx, state) do
    {[stream_format: {pad, state.track_data[id].stream_format}], state}
  end

  @impl true
  def handle_demand(Pad.ref(:output, id) = pad, _size, :buffers, _ctx, state) do
    %{current_segment_samples: current_segment_samples, segment_filenames: segment_filenames} =
      state.track_data[id]

    {actions, current_segment_samples, segment_filenames} =
      get_next_sample_actions(pad, current_segment_samples, segment_filenames)

    state =
      state
      |> put_in([:track_data, id, :segment_filenames], segment_filenames)
      |> put_in([:track_data, id, :current_segment_samples], current_segment_samples)

    {actions, state}
  end

  @spec get_next_sample_actions(Membrane.Pad.ref(), [binary()], [Path.t()]) ::
          {Membrane.Element.Action.t(), [binary()], [Path.t()]}
  def get_next_sample_actions(pad, [], []) do
    {[end_of_stream: pad], [], []}
  end

  def get_next_sample_actions(pad, [], [new_segment_filename | rest_segment_filenames]) do
    new_segment_samples = get_segment_samples(new_segment_filename)
    get_next_sample_actions(pad, new_segment_samples, rest_segment_filenames)
  end

  def get_next_sample_actions(pad, [first_sample | rest_samples], segment_filenames) do
    {
      [buffer: {pad, %Buffer{payload: first_sample}}, redemand: pad],
      rest_samples,
      segment_filenames
    }
  end

  @spec get_segment_samples(Path.t()) :: [binary()]
  def get_segment_samples(segment_filename) do
    {container, ""} = segment_filename |> File.read!() |> MP4.Container.parse!()

    sample_lengths =
      container[:moof].children[:traf].children[:trun].fields.samples
      |> Enum.map(& &1.sample_size)

    samples_binary = container[:mdat].content

    split_samples(samples_binary, sample_lengths)
  end

  @spec split_samples(samples_binary :: binary(), samples_lengths :: [pos_integer()]) ::
          split_samples :: [binary()]
  defp split_samples(<<>>, []) do
    []
  end

  defp split_samples(samples_binary, [current_length | rest_lengths]) do
    <<current_sample::binary-size(current_length), samples_rest::binary>> = samples_binary
    [current_sample | split_samples(samples_rest, rest_lengths)]
  end

  @spec get_prefixed_files(Path.t(), String.t()) :: [Path.t()]
  defp get_prefixed_files(directory, prefix) do
    File.ls!(directory)
    |> Enum.filter(&String.starts_with?(&1, prefix))
    |> Enum.map(&Path.join(directory, &1))
  end
end
