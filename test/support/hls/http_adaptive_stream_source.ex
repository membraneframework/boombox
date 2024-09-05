defmodule Membrane.HTTPAdaptiveStream.Source do
  @moduledoc false

  use Membrane.Source

  alias Boombox.MP4
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
    hls_mode =
      case opts.directory |> File.ls!() |> Enum.find(&String.starts_with?(&1, "muxed_header")) do
        nil -> :separate_av
        _muxed_header -> :muxed_av
      end

    tracks_map = get_tracks(opts.directory, hls_mode)

    %{audio_buffers: audio_buffers, video_buffers: video_buffers} =
      get_buffers(opts.directory, hls_mode, tracks_map)

    state =
      %{
        track_data: %{
          audio: assemble_track_data(tracks_map.audio_track, audio_buffers),
          video: assemble_track_data(tracks_map.video_track, video_buffers)
        }
      }

    notification =
      state.track_data
      |> Enum.reject(&match?({_media, nil}, &1))
      |> Enum.map(fn {media, %{stream_format: stream_format}} -> {media, stream_format} end)

    {[notify_parent: {:new_tracks, notification}], state}
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

  @spec get_prefixed_files(Path.t(), String.t()) :: [Path.t()]
  defp get_prefixed_files(directory, prefix) do
    File.ls!(directory)
    |> Enum.filter(&String.starts_with?(&1, prefix))
    |> Enum.map(&Path.join(directory, &1))
  end

  @spec get_tracks(Path.t(), hls_mode :: :muxed_av | :separate_av) ::
          %{audio_track: MP4.Track.t(), video_track: MP4.Track.t()}
  defp get_tracks(directory, :muxed_av) do
    {parsed_header, ""} =
      get_prefixed_files(directory, "muxed_header")
      |> List.first()
      |> File.read!()
      |> MP4.Container.parse!()

    parsed_header[:moov].children
    |> Keyword.get_values(:trak)
    |> Enum.map(&TrackBox.unpack/1)
    |> Enum.reduce(%{audio_track: nil, video_track: nil}, fn track, tracks_map ->
      case track.stream_format do
        %Membrane.AAC{} -> %{tracks_map | audio_track: track}
        %Membrane.H264{} -> %{tracks_map | video_track: track}
        _other -> tracks_map
      end
    end)
  end

  defp get_tracks(directory, :separate_av) do
    %{
      audio_track: get_separate_track(directory, :audio),
      video_track: get_separate_track(directory, :video)
    }
  end

  @spec get_separate_track(Path.t(), :audio | :video) :: MP4.Track.t() | nil
  defp get_separate_track(directory, media) do
    header_prefix =
      case media do
        :audio -> "audio_header"
        :video -> "video_header"
      end

    case get_prefixed_files(directory, header_prefix) |> List.first() do
      nil ->
        nil

      header ->
        {parsed_header, ""} =
          header
          |> File.read!()
          |> MP4.Container.parse!()

        TrackBox.unpack(parsed_header[:moov].children[:trak])
    end
  end

  @spec get_buffers(
          Path.t(),
          hls_mode :: :muxed_av | :separate_av,
          %{audio_track: MP4.Track.t() | nil, video_track: MP4.Track.t() | nil}
        ) :: %{audio_buffers: [Buffer.t()], video_buffers: [Buffer.t()]}
  defp get_buffers(
         directory,
         :muxed_av,
         %{audio_track: %MP4.Track{id: audio_id}, video_track: %MP4.Track{id: video_id}}
       ) do
    segments_filenames = get_prefixed_files(directory, "muxed_segment") |> Enum.sort()

    Enum.map(segments_filenames, fn file ->
      %{^audio_id => segment_audio_buffers, ^video_id => segment_video_buffers} =
        get_buffers_from_muxed_segment(file)

      {segment_audio_buffers, segment_video_buffers}
    end)
    |> Enum.unzip()
    |> then(fn {audio_buffers, video_buffers} ->
      %{audio_buffers: List.flatten(audio_buffers), video_buffers: List.flatten(video_buffers)}
    end)
  end

  defp get_buffers(directory, :separate_av, %{audio_track: audio_track, video_track: video_track}) do
    %{
      audio_buffers: audio_track && get_separate_buffers(directory, :audio),
      video_buffers: video_track && get_separate_buffers(directory, :video)
    }
  end

  @spec get_separate_buffers(Path.t(), :audio | :video) :: [Buffer.t()]
  defp get_separate_buffers(directory, media) do
    segment_prefix =
      case media do
        :audio -> "audio_segment"
        :video -> "video_segment"
      end

    case get_prefixed_files(directory, segment_prefix) |> Enum.sort() do
      [] ->
        nil

      segment_filenames ->
        Enum.flat_map(segment_filenames, fn segment_filename ->
          {container, ""} = segment_filename |> File.read!() |> MP4.Container.parse!()

          sample_lengths =
            container[:moof].children[:traf].children[:trun].fields.samples
            |> Enum.map(& &1.sample_size)

          samples_binary = container[:mdat].content

          get_buffers_from_samples(sample_lengths, samples_binary)
        end)
    end
  end

  @spec get_buffers_from_muxed_segment(Path.t()) :: %{(track_id :: pos_integer()) => [Buffer.t()]}
  defp get_buffers_from_muxed_segment(segment_filename) do
    {container, ""} = segment_filename |> File.read!() |> MP4.Container.parse!()

    Enum.zip(
      Keyword.get_values(container, :moof),
      Keyword.get_values(container, :mdat)
    )
    |> Map.new(fn {moof_box, mdat_box} ->
      traf_box_children = moof_box.children[:traf].children

      sample_sizes =
        traf_box_children[:trun].fields.samples
        |> Enum.map(& &1.sample_size)

      buffers = get_buffers_from_samples(sample_sizes, mdat_box.content)

      {traf_box_children[:tfhd].fields.track_id, buffers}
    end)
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

  @spec assemble_track_data(MP4.Track.t() | nil, [Buffer.t()] | nil) ::
          %{stream_format: Membrane.H264.t() | Membrane.AAC.t(), buffers_left: [Buffer.t()]} | nil
  defp assemble_track_data(track, buffers) do
    case track do
      nil ->
        nil

      %MP4.Track{stream_format: stream_format} ->
        %{stream_format: stream_format, buffers_left: buffers}
    end
  end
end
