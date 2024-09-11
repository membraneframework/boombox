defmodule Support.Utils do
  import Membrane.ChildrenSpec
  import Membrane.Testing.Assertions

  require Membrane.Pad, as: Pad
  require Logger

  alias Membrane.Testing

  def get_port() do
    name = :boombox_test_port_agent
    Agent.start_link(fn -> 5000 end, name: name)

    Agent.get_and_update(name, fn port ->
      port =
        port
        |> Stream.from_index()
        |> Enum.find(
          # Check if the port is free
          &case :gen_tcp.listen(&1, []) do
            {:ok, socket} -> :ok == :gen_tcp.close(socket)
            _error -> false
          end
        )

      {port, port + 1}
    end)
  end

  def send_rtmp(path, url) do
    p =
      Testing.Pipeline.start_link_supervised!(
        spec:
          child(%Membrane.File.Source{location: path, seekable?: true})
          |> child(:demuxer, %Membrane.MP4.Demuxer.ISOM{optimize_for_non_fast_start?: true})
      )

    assert_pipeline_notified(p, :demuxer, {:new_tracks, tracks})

    [{audio_id, %Membrane.AAC{}}, {video_id, %Membrane.H264{}}] =
      Enum.sort_by(tracks, fn {_id, %format{}} -> format end)

    Testing.Pipeline.execute_actions(p,
      spec: [
        get_child(:demuxer)
        |> via_out(Pad.ref(:output, video_id))
        |> child(Membrane.Realtimer)
        |> child(:video_parser, %Membrane.H264.Parser{
          output_stream_structure: :avc1
        })
        |> via_in(Pad.ref(:video, 0))
        |> get_child(:rtmp_sink),
        get_child(:demuxer)
        |> via_out(Pad.ref(:output, audio_id))
        |> child(Membrane.Realtimer)
        |> child(:audio_parser, %Membrane.AAC.Parser{
          out_encapsulation: :none,
          output_config: :esds
        })
        |> via_in(Pad.ref(:audio, 0))
        |> get_child(:rtmp_sink),
        child(:rtmp_sink, %Membrane.RTMP.Sink{rtmp_url: url})
      ]
    )

    p
  end
end
