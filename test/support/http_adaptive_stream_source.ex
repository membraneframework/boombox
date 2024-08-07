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
      |> IO.inspect(label: "dupa")
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
  def handle_pad_added(Pad.ref(:output, id) = pad, _ctx, state) do
    {[stream_format: {pad, state.track_data[id].stream_format}], state}
  end

  @impl true
  def handle_demand(Pad.ref(:output, id) = pad, demand_size, :buffers, _ctx, state) do
    %{current_segment_samples: current_segment_samples, segment_filenames: segment_filenames} =
      state.track_data[id]

    {actions, current_segment_samples, segment_filenames} =
      get_buffers_from_samples(pad, current_segment_samples, segment_filenames, demand_size)

    state =
      state
      |> put_in([:track_data, id, :segment_filenames], segment_filenames)
      |> put_in([:track_data, id, :current_segment_samples], current_segment_samples)

    {actions, state}
  end

  @spec get_buffers_from_samples(Membrane.Pad.ref(), [binary()], [Path.t()], non_neg_integer(), [
          Buffer.t()
        ]) ::
          {[Buffer.t()], [binary()], [Path.t()]}
  defp get_buffers_from_samples(
         pad,
         current_segment_samples,
         segment_filenames,
         buffers_left_to_produce,
         buffers \\ []
       )

  defp get_buffers_from_samples(pad, [], [], _buffers_left_to_produce, buffers) do
    {[buffer: {pad, Enum.reverse(buffers)}, end_of_stream: pad], [], []}
  end

  defp get_buffers_from_samples(
         pad,
         current_segment_samples,
         segment_filenames,
         0,
         buffers
       ) do
    {[buffer: {pad, Enum.reverse(buffers)}], current_segment_samples, segment_filenames}
  end

  defp get_buffers_from_samples(
         pad,
         [] = _depleted_current_segment,
         [new_segment_filename | rest_segment_filenames],
         buffers_left_to_produce,
         buffers
       ) do
    new_segment_samples = get_segment_samples(new_segment_filename)

    get_buffers_from_samples(
      pad,
      new_segment_samples,
      rest_segment_filenames,
      buffers_left_to_produce,
      buffers
    )
  end

  defp get_buffers_from_samples(
         pad,
         [first_sample | rest_samples],
         segment_filenames,
         buffers_left_to_produce,
         buffers
       ) do
    get_buffers_from_samples(
      pad,
      rest_samples,
      segment_filenames,
      buffers_left_to_produce - 1,
      [%Buffer{payload: first_sample} | buffers]
    )
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
