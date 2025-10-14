defmodule Boombox.InternalBin.Player do
  @moduledoc false

  import Membrane.ChildrenSpec

  alias Boombox.InternalBin.Ready
  alias Membrane.{RawAudio, RawVideo}

  @spec link_output(
          Boombox.InternalBin.track_builders(),
          Membrane.ChildrenSpec.t(),
          boolean(),
          Boombox.InternalBin.State.t()
        ) :: {Ready.t(), Boombox.InternalBin.State.t()}
  def link_output(track_builders, spec_builder, is_input_realtime, state) do
    state = %{state | player_state: %{}}

    {spec, state} =
      track_builders
      |> Enum.map_reduce(state, fn
        {:audio, builder}, state ->
          spec =
            builder
            |> child(:player_audio_transcoder, %Membrane.Transcoder{
              output_stream_format: RawAudio
            })
            |> maybe_plug_realtimer(:audio, is_input_realtime)
            |> child(:player_audio_sink, Membrane.PortAudio.Sink)

          state =
            state
            |> put_in([:player_state, :player_audio_sink], %{eos?: false})

          {spec, state}

        {:video, builder}, state ->
          spec =
            builder
            |> child(:player_video_transcoder, %Membrane.Transcoder{
              output_stream_format: RawVideo
            })
            |> maybe_plug_realtimer(:video, is_input_realtime)
            |> child(:player_video_sink, Membrane.SDL.Player)

          state =
            state
            |> put_in([:player_state, :player_video_sink], %{eos?: false})

          {spec, state}
      end)

    spec = [spec_builder, spec]
    {%Ready{actions: [spec: spec]}, state}
  end

  @sink_names [:player_audio_sink, :player_video_sink]

  @spec handle_element_end_of_stream(
          :player_audio_sink | :player_video_sink,
          Boombox.InternalBin.State.t()
        ) :: {[Membrane.Bin.Action.t()], Boombox.InternalBin.State.t()}
  def handle_element_end_of_stream(sink, state) when sink in @sink_names do
    state = state |> put_in([:player_state, sink, :eos?], true)

    all_eos? =
      state.player_state
      |> Map.take(@sink_names)
      |> Enum.all?(fn {_k, v} -> v.eos? end)

    actions = if all_eos?, do: [notify_parent: :processing_finished], else: []
    {actions, state}
  end

  defp maybe_plug_realtimer(spec, kind, true = _do_it?) do
    spec
    |> via_in(:input, toilet_capacity: 1000)
    |> child({:player, kind, :realtimer}, Membrane.Realtimer)
  end

  defp maybe_plug_realtimer(spec, _kind, false = _do_it?), do: spec
end
