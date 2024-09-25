defmodule Boombox.Transcoders.Helpers.ForwardingFilter do
  @moduledoc false
  use Membrane.Filter

  alias Membrane.TimestampQueue

  def_input_pad :input,
    accepted_format: _any,
    availability: :on_request

  def_output_pad :output,
    accepted_format: _any,
    availability: :on_request

  defguardp is_input_linked(state) when state.input_pad_ref != nil
  defguardp is_output_linked(state) when state.output_pad_ref != nil

  @impl true
  def handle_init(_ctx, _opts) do
    state = %{queue: TimestampQueue.new(), output_pad_ref: nil, input_pad_ref: nil}
    {[], state}
  end

  @impl true
  def handle_playing(ctx, state), do: maybe_flush_queue(ctx, state)

  @impl true
  def handle_pad_added(Pad.ref(direction, _id) = pad_ref, ctx, state) do
    same_direction_pads_number =
      ctx.pads
      |> Enum.count(fn {_pad_ref, pad_data} -> pad_data.direction == direction end)

    if same_direction_pads_number > 1 do
      raise """
      #{inspect(__MODULE__)} can have only one #{inspect(direction)} pad, but it has \
      #{same_direction_pads_number}
      """
    end

    state =
      case direction do
        :input -> %{state | input_pad_ref: pad_ref}
        :output -> %{state | output_pad_ref: pad_ref}
      end

    maybe_flush_queue(ctx, state)
  end

  @impl true
  def handle_stream_format(_input_pad_ref, stream_format, _ctx, state)
      when is_output_linked(state) do
    {[stream_format: {state.output_pad_ref, stream_format}]}
  end

  @impl true
  def handle_stream_format(input_pad_ref, stream_format, _ctx, state) do
    queue = TimestampQueue.push_stream_format(state.queue, input_pad_ref, stream_format)
    {[], %{state | queue: queue}}
  end

  @impl true
  def handle_buffer(_input_pad_ref, buffer, _ctx, state) when is_output_linked(state) do
    {[buffer: {state.output_pad_ref, buffer}], state}
  end

  @impl true
  def handle_buffer(input_pad_ref, buffer, _ctx, state) do
    {_suggested_actions, queue} = TimestampQueue.push_buffer(state.queue, input_pad_ref, buffer)
    {[], %{state | queue: queue}}
  end

  @impl true
  def handle_event(Pad.ref(:input, _id), event, _ctx, state) when is_output_linked(state) do
    {[forward: event], state}
  end

  @impl true
  def handle_event(Pad.ref(:output, _id), event, _ctx, state) when is_input_linked(state) do
    {[forward: event], state}
  end

  @impl true
  def handle_event(pad_ref, event, _ctx, state) do
    queue = TimestampQueue.push_event(state.queue, pad_ref, event)
    {[], %{state | queue: queue}}
  end

  @impl true
  def handle_end_of_stream(_input_pad_ref, _ctx, state) when is_output_linked(state) do
    {[end_of_stream: state.output_pad_ref], state}
  end

  @impl true
  def handle_end_of_stream(input_pad_ref, _ctx, state) do
    queue = TimestampQueue.push_end_of_stream(state.queue, input_pad_ref)
    {[], %{state | queue: queue}}
  end

  defp maybe_flush_queue(ctx, state)
       when ctx.playback == :playing and is_input_linked(state) and is_output_linked(state) do
    # IO.inspect("FLUSHING QUEUE")
    {_suggested_actions, items, queue} = TimestampQueue.flush_and_close(state.queue)

    actions =
      Enum.map(items, fn
        {Pad.ref(:input, _id), {item_type, item}} -> {item_type, {state.output_pad_ref, item}}
        {Pad.ref(:input, _id), :end_of_stream} -> {:end_of_stream, state.output_pad_ref}
        {Pad.ref(:output, _id), {:event, item}} -> {:event, {state.input_pad_ref, item}}
      end)

    {actions, %{state | queue: queue}}
  end

  defp maybe_flush_queue(_ctx, state), do: {[], state}
end
