defmodule Boombox.Bin do
  @moduledoc """
  Boombox is a tool for audio and video streaming.

  See `run/1` for details and [examples.livemd](examples.livemd) for examples.
  """

  use Membrane.Bin
  require Membrane.Transcoder.{Audio, Video}
  alias Membrane.Transcoder

  def_input_pad :audio_input,
    accepted_format: format when Transcoder.Audio.is_audio_format(format),
    availability: :on_request,
    max_instances: 1

  def_input_pad :video_input,
    accepted_format: format when Transcoder.Video.is_video_format(format),
    availability: :on_request,
    max_instances: 1

  def_options output: [
                spec: Boombox.output()
              ]

  @impl true
  def handle_init(_ctx, opts) do
    :ok = validate_option!(:output, opts.output)

    spec =
      child(:boombox, %Boombox.InternalBin{
        input: :membrane_pad,
        output: opts.output
      })

    {[spec: spec], %{}}
  end

  @impl true
  def handle_pad_added(pad_ref, _ctx, state) do
    spec =
      bin_input(pad_ref)
      |> via_in(pad_ref)
      |> get_child(:boombox)

    {[spec: spec], state}
  end

  @impl true
  def handle_child_notification(:processing_finished, :boombox, _ctx, state) do
    {[notify_parent: :processing_finished], state}
  end

  defp validate_option!(direction, option) do
    if is_tuple(option) and elem(option, 0) == :stream do
      raise """
      #{inspect(direction)} option is set to #{inspect(option)}, but #{inspect(__MODULE__)} \
      doesn't support Elixir Stream as an endpoint.
      """
    end

    :ok
  end
end
