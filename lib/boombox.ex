defmodule Boombox do
  @moduledoc """
  Boombox is a tool for audio and video streaming.

  See `t:input/0` and `t:output/0` for supported protocols.
  """

  require Membrane.Time

  @type webrtc_opts :: Membrane.WebRTC.SignalingChannel.t() | URI.t()
  @type in_stream_opts :: [audio: :binary | boolean(), video: :image | boolean()]
  @type out_stream_opts :: [
          audio: :binary | boolean(),
          video: :image | boolean(),
          audio_format: Membrane.RawAudio.SampleFormat.t(),
          audio_rate: Membrane.RawAudio.sample_rate_t(),
          audio_channels: Membrane.RawAudio.channels_t()
        ]

  @type file_extension :: :mp4

  @type input ::
          URI.t()
          | Path.t()
          | {:file, file_extension(), Path.t()}
          | {:http, file_extension(), URI.t()}
          | {:webrtc, webrtc_opts()}
          | {:rtmp, URI.t() | pid()}
          | {:stream, in_stream_opts()}

  @type output ::
          URI.t()
          | Path.t()
          | {:file, file_extension(), Path.t()}
          | {:webrtc, webrtc_opts()}
          | {:hls, Path.t()}
          | {:stream, out_stream_opts()}

  @typep procs :: %{pipeline: pid(), supervisor: pid()}
  @typep opts_map :: %{input: input(), output: output()}

  @spec run(Enumerable.t(), input: input(), output: output()) :: :ok | Enumerable.t()
  def run(stream \\ nil, opts) do
    opts = Keyword.validate!(opts, [:input, :output]) |> Map.new()

    case opts do
      %{input: {:stream, _in_stream_opts}, output: {:stream, _out_stream_opts}} ->
        raise ArgumentError, ":stream on both input and output is not supported"

      %{input: {:stream, _stream_opts}} ->
        unless Enumerable.impl_for(stream) do
          raise ArgumentError,
                "Expected Enumerable.t() to be passed as the first argument, got #{inspect(stream)}"
        end

        consume_stream(stream, opts)

      %{output: {:stream, _stream_opts}} ->
        produce_stream(opts)

      opts ->
        opts
        |> start_pipeline()
        |> await_pipeline()
    end
  end

  @spec consume_stream(Enumerable.t(), opts_map()) :: term()
  defp consume_stream(stream, opts) do
    procs = start_pipeline(opts)

    source =
      receive do
        {:boombox_ex_stream_source, source} -> source
      end

    Enum.reduce_while(
      stream,
      %{demand: 0},
      fn
        %Boombox.Packet{} = packet, %{demand: 0} = state ->
          receive do
            {:boombox_demand, demand} ->
              send(source, packet)
              {:cont, %{state | demand: demand - 1}}

            {:DOWN, _monitor, :process, supervisor, _reason}
            when supervisor == procs.supervisor ->
              {:halt, :terminated}
          end

        %Boombox.Packet{} = packet, %{demand: demand} = state ->
          send(source, packet)
          {:cont, %{state | demand: demand - 1}}

        value, _state ->
          raise ArgumentError, "Expected Boombox.Packet.t(), got: #{inspect(value)}"
      end
    )
    |> case do
      :terminated ->
        :ok

      _state ->
        send(source, :boombox_eos)
        await_pipeline(procs)
    end
  end

  @spec produce_stream(opts_map()) :: Enumerable.t()
  defp produce_stream(opts) do
    Stream.resource(
      fn ->
        procs = start_pipeline(opts)

        receive do
          {:boombox_ex_stream_sink, sink} -> %{sink: sink, procs: procs}
        end
      end,
      fn %{sink: sink, procs: procs} = state ->
        send(sink, :boombox_demand)

        receive do
          %Boombox.Packet{} = packet ->
            verify_packet!(packet)
            {[packet], state}

          {:DOWN, _monitor, :process, supervisor, _reason}
          when supervisor == procs.supervisor ->
            {:halt, :eos}
        end
      end,
      fn
        %{procs: procs} -> terminate_pipeline(procs)
        :eos -> :ok
      end
    )
  end

  @spec start_pipeline(opts_map()) :: procs()
  defp start_pipeline(opts) do
    {:ok, supervisor, pipeline} =
      Membrane.Pipeline.start_link(Boombox.Pipeline, Map.put(opts, :parent, self()))

    Process.monitor(supervisor)
    %{supervisor: supervisor, pipeline: pipeline}
  end

  @spec terminate_pipeline(procs) :: :ok
  defp terminate_pipeline(procs) do
    Membrane.Pipeline.terminate(procs.pipeline)
    await_pipeline(procs)
  end

  @spec await_pipeline(procs) :: :ok
  defp await_pipeline(%{supervisor: supervisor}) do
    receive do
      {:DOWN, _monitor, :process, ^supervisor, _reason} -> :ok
    end
  end

  @spec verify_packet!(term()) :: :ok
  defp verify_packet!(packet) do
    %Boombox.Packet{kind: kind, pts: pts, format: format} = packet

    unless kind in [:audio, :video] do
      raise "Boombox.Packet field :kind must be set to :audio or :video, got #{inspect(kind)}"
    end

    unless Membrane.Time.is_time(pts) do
      raise "Boombox.Packet field :pts must be of type `Membrane.Time.t`, got #{inspect(pts)}"
    end

    unless is_map(format) do
      raise "Boombox.Packet field :format must be a map, got #{inspect(format)}"
    end

    :ok
  end

  @spec run_cli([String.t()]) :: :ok
  def run_cli(args \\ System.argv()) do
    args =
      Enum.map(args, fn
        "-" <> value -> String.to_atom(value)
        value -> value
      end)

    run(input: parse_cli_io(:i, args), output: parse_cli_io(:o, args))
  end

  defp parse_cli_io(type, args) do
    args
    |> Enum.drop_while(&(&1 != type))
    |> Enum.drop(1)
    |> Enum.take_while(&(&1 not in [:i, :o]))
    |> case do
      [value] -> value
      [_h | _t] = values -> List.to_tuple(values)
    end
  end
end
