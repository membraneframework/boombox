defmodule Boombox.InternalBin.ElixirEndpoints.SourceTest do
  use ExUnit.Case, async: true

  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  require Membrane.Pad, as: Pad

  alias Boombox.InternalBin.ElixirEndpoints.PullSource
  alias Membrane.Testing

  @frames 5
  @timeout 5_000

  test "with keep_newest_video, only the newest of the waiting frames is converted" do
    {pipeline, source} = start(keep_newest_video: true)

    queue_frames(source)

    assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{pts: pts}, @timeout)
    assert pts == @frames - 1
    refute_sink_buffer(pipeline, :sink, _buffer, 200)

    # The dropped frames each spent a demand the producer has to get back.
    assert_receive {:boombox_demand, ^source, :video, dropped}, @timeout
    assert dropped == @frames - 1

    Testing.Pipeline.terminate(pipeline)
  end

  test "without it, every frame is converted in order" do
    {pipeline, source} = start(keep_newest_video: false)

    queue_frames(source)

    for pts <- 0..(@frames - 1),
        do: assert_sink_buffer(pipeline, :sink, %Membrane.Buffer{pts: ^pts}, @timeout)

    refute_receive {:boombox_demand, ^source, :video, _dropped}, 200

    Testing.Pipeline.terminate(pipeline)
  end

  defp start(opts) do
    spec =
      child(:source, %PullSource{producer: self(), keep_newest_video: opts[:keep_newest_video]})
      |> via_out(Pad.ref(:output, :video))
      |> child(:sink, Testing.Sink)

    pipeline = Testing.Pipeline.start_link_supervised!(spec: spec)
    assert_receive {:boombox_elixir_source, source}, @timeout
    # The sink's first demand, so the frames below are frames it asked for.
    assert_receive {:boombox_demand, ^source, :video, demand}, @timeout
    assert demand >= @frames

    {pipeline, source}
  end

  # Suspended, the source cannot take the first frame before the rest arrive,
  # so all of them are waiting at once, as behind a slow encoder.
  defp queue_frames(source) do
    :sys.suspend(source)

    for pts <- 0..(@frames - 1) do
      packet = %Boombox.Packet{kind: :video, payload: Image.new!(8, 8), pts: pts}
      send(source, {:boombox_packet, self(), packet})
    end

    :sys.resume(source)
  end
end
