# This generates two variants of the Source:
#   * PullSource - The element has `:manual` flow control on output pads and
#     handles demands from subsequent element by demanding packets from the producer
#     process with `{:boombox_demand, self(), demand_amount}` messages.
#   * PushSource - The element has `:push` flow control on output pads and expects
#     the producer process to provide it with packets without demanding them.

[{PullSource, :manual}, {PushSource, :push}]
|> Enum.map(fn {module_name, flow_control} ->
  defmodule Module.concat(Boombox.InternalBin.ElixirEndpoints, module_name) do
    @moduledoc false
    use Membrane.Source

    def_output_pad :output,
      accepted_format: any_of(Membrane.RawVideo, Membrane.RawAudio),
      availability: :on_request,
      max_instances: 2,
      flow_control: flow_control

    def_options producer: [
                  spec: pid(),
                  description: """
                  PID of a process from which to demand and receive packets.
                  """
                ],
                keep_newest_video: [
                  spec: boolean(),
                  default: false,
                  description: """
                  If `true`, a video packet is converted only when no newer one
                  is already waiting, so frames the output cannot keep up with are
                  dropped instead of queued.
                  """
                ]

    defmodule State do
      @moduledoc false
      @type t :: %__MODULE__{
              producer: pid(),
              audio_format:
                %{
                  audio_format: Membrane.RawAudio.SampleFormat.t(),
                  audio_rate: pos_integer(),
                  audio_channels: pos_integer()
                }
                | nil,
              video_dims: %{width: pos_integer(), height: pos_integer()} | nil,
              keep_newest_video: boolean()
            }

      @enforce_keys [:producer]

      defstruct @enforce_keys ++
                  [
                    audio_format: nil,
                    video_dims: nil,
                    keep_newest_video: false
                  ]
    end

    @impl true
    def handle_init(_ctx, opts) do
      {[], %State{producer: opts.producer, keep_newest_video: opts.keep_newest_video}}
    end

    @impl true
    def handle_playing(_ctx, state) do
      send(state.producer, {:boombox_elixir_source, self()})
      {[], state}
    end

    if flow_control == :manual do
      @impl true
      def handle_demand(Pad.ref(:output, id), _size, _unit, ctx, state) do
        send(state.producer, {:boombox_demand, self(), id, ctx.incoming_demand})
        {[], state}
      end
    end

    @impl true
    def handle_info(
          {:boombox_packet, producer, %Boombox.Packet{kind: :video} = packet},
          _ctx,
          %{producer: producer} = state
        ) do
      packet = if state.keep_newest_video, do: newest_video(packet, producer), else: packet
      image = packet.payload |> Image.flatten!() |> Image.to_colorspace!(:srgb)
      video_dims = %{width: Image.width(image), height: Image.height(image)}
      {:ok, payload} = Vix.Vips.Image.write_to_binary(image)
      buffer = %Membrane.Buffer{payload: payload, pts: packet.pts}

      if video_dims == state.video_dims do
        {[buffer: {Pad.ref(:output, :video), buffer}], state}
      else
        stream_format = %Membrane.RawVideo{
          width: video_dims.width,
          height: video_dims.height,
          pixel_format: :RGB,
          aligned: true,
          framerate: nil
        }

        {[
           stream_format: {Pad.ref(:output, :video), stream_format},
           buffer: {Pad.ref(:output, :video), buffer}
         ], %{state | video_dims: video_dims}}
      end
    end

    @impl true
    def handle_info(
          {:boombox_packet, producer, %Boombox.Packet{kind: :audio} = packet},
          _ctx,
          %{producer: producer} = state
        ) do
      %Boombox.Packet{payload: payload, format: format} = packet
      buffer = %Membrane.Buffer{payload: payload, pts: packet.pts}

      cond do
        format == %{} and state.audio_format == nil ->
          raise "No audio stream format provided"

        format == %{} or format == state.audio_format ->
          {[buffer: {Pad.ref(:output, :audio), buffer}], state}

        true ->
          stream_format = %Membrane.RawAudio{
            sample_format: format.audio_format,
            sample_rate: format.audio_rate,
            channels: format.audio_channels
          }

          {[
             stream_format: {Pad.ref(:output, :audio), stream_format},
             buffer: {Pad.ref(:output, :audio), buffer}
           ], %{state | audio_format: format}}
      end
    end

    @impl true
    def handle_info({:boombox_eos, producer}, ctx, %{producer: producer} = state) do
      actions = Enum.map(ctx.pads, fn {ref, _data} -> {:end_of_stream, ref} end)
      {actions, state}
    end

    # The newest video packet already waiting, and the older ones dropped.
    # Each packet the producer sent spent one of its demand, so in pull mode
    # the dropped ones are demanded again; otherwise the producer would wait
    # for demand the output already believes it gave.
    defp newest_video(packet, producer) do
      {newest, dropped} = drain_video(packet, producer, 0)
      demand_again(producer, dropped)
      newest
    end

    if flow_control == :manual do
      defp demand_again(producer, dropped) when dropped > 0,
        do: send(producer, {:boombox_demand, self(), :video, dropped})
    end

    defp demand_again(_producer, _dropped), do: :ok

    defp drain_video(packet, producer, dropped) do
      receive do
        {:boombox_packet, ^producer, %Boombox.Packet{kind: :video} = newer} ->
          drain_video(newer, producer, dropped + 1)
      after
        0 -> {packet, dropped}
      end
    end
  end
end)
