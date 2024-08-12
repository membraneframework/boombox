defmodule Boombox.Transcoders.DataReceiver do
  @moduledoc false

  # An Element that
  #  - is linked to the input od Transcoder
  #  - notifies parent (Transcoder) about received stream format
  #  - buffers incoming data, until output pad is linked

  use Membrane.Filter

  alias Membrane.TimestampQueue

  def_input_pad :input,
    accepted_format: any_of(Membrane.AAC, Membrane.Opus)

  def_output_pad :output,
    accepted_format: any_of(Membrane.AAC, Membrane.Opus),
    availability: :on_request

  defguardp is_output_linked(state) when state.output_pad_ref != nil

  @impl true
  def handle_init(_ctx, _opts), do: {[], %{queue: TimestampQueue.new(), output_pad_ref: nil}}

  @impl true
  def handle_playing(ctx, state), do: maybe_flush_queue(ctx, state)

  @impl true
  def handle_pad_added(output_pad_ref, ctx, state) do
    output_pads_number = Map.keys(ctx.pads) |> Enum.count(&(&1 != :input))

    if output_pads_number > 1 do
      raise "#{inspect(__MODULE__)} can have only one output pad, but it has #{output_pads_number}"
    end

    state = %{state | output_pad_ref: output_pad_ref}
    maybe_flush_queue(ctx, state)
  end

  @impl true
  def handle_stream_format(:input, stream_format, _ctx, state) do
    {actions, state} =
      if is_output_linked(state) do
        {[stream_format: {state.output_pad_ref, stream_format}], state}
      else
        queue = TimestampQueue.push_stream_format(state.queue, :input, stream_format)
        {[], %{state | queue: queue}}
      end

    actions = actions ++ [notify_parent: {:input_stream_format, stream_format}]
    {actions, state}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) when is_output_linked(state) do
    {[buffer: {state.output_pad_ref, buffer}], state}
  end

  @impl true
  def handle_buffer(:input, buffer, _ctx, state) do
    {_suggested_actions, queue} = TimestampQueue.push_buffer(state.queue, :input, buffer)
    {[], %{state | queue: queue}}
  end

  @impl true
  def handle_event(_pad, event, _ctx, state) when is_output_linked(state) do
    {[forward: event], state}
  end

  @impl true
  def handle_event(:input, event, _ctx, state) do
    queue = TimestampQueue.push_event(state.queue, :input, event)
    {[], %{state | queue: queue}}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, state) when is_output_linked(state) do
    {[end_of_stream: state.output_pad_ref], state}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, state) do
    queue = TimestampQueue.push_end_of_stream(state.queue, :input)
    {[], %{state | queue: queue}}
  end

  defp maybe_flush_queue(ctx, state) when ctx.playback == :playing and is_output_linked(state) do
    {_suggested_actions, items, queue} = TimestampQueue.flush_and_close(state.queue)

    actions =
      Enum.map(items, fn
        {:input, {item_type, item}} -> {item_type, {state.output_pad_ref, item}}
        {:input, :end_of_stream} -> {:end_of_stream, state.output_pad_ref}
      end)

    {actions, %{state | queue: queue}}
  end
end
