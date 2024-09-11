bbb_mp4_url =
  "https://raw.githubusercontent.com/membraneframework/static/gh-pages/samples/big-buck-bunny/bun10s.mp4"

bbb_mp4 = "test/fixtures/bun10s.mp4"
bbb_mp4_a = "test/fixtures/bun10s_a.mp4"
bbb_mp4_v = "test/fixtures/bun10s_v.mp4"

sources =
  [
    mp4: [
      {"bun10s", bbb_mp4},
      {"bun10s_a", bbb_mp4_a, ref: "bun10s", kinds: [:audio]},
      {"bun10s_v", bbb_mp4_v, ref: "bun10s", kinds: [:video]},
      {"bun10s_http", bbb_mp4_url, ref: "bun10s"}
    ],
    rtmp: [
      {"bun10s", quote(do: "rtmp://localhost:#{rtmp_port}"),
       setup: quote(do: rtmp_port = Utils.get_port()),
       feed:
         quote do
           # Wait for Boombox to be ready
           Process.sleep(200)
           Support.Utils.send_rtmp(unquote(bbb_mp4), "rtmp://localhost:#{rtmp_port}")
         end}
    ]
  ]
  |> Enum.flat_map(fn {type, sources} ->
    Enum.map(sources, &([type] ++ Tuple.to_list(&1) ++ [[]]))
  end)
  |> Enum.map(fn [type, name, input, opts | _default] ->
    opts = Keyword.validate!(opts, ref: name, kinds: [:audio, :video], setup: nil, feed: nil)
    Map.new([type: type, name: name, input: input] ++ opts)
  end)

outputs =
  [
    mp4: [
      output: quote(do: out_dir <> "/vid.mp4"),
      input: true,
      dest: &"#{&1}.mp4",
      sync: true,
      transcode: "aac"
    ],
    webrtc: [
      setup: quote(do: signaling = Membrane.WebRTC.SignalingChannel.new()),
      output: quote(do: {:webrtc, signaling}),
      input: true,
      dest: false,
      transcode: "opus"
    ],
    hls: [
      output: quote(do: out_dir <> "/index.m3u8"),
      input: false,
      dest: &"#{&1}_hls/index.m3u8",
      transcode: "aac"
    ]
  ]
  |> Enum.map(fn {type, opts} ->
    Map.merge(%{type: type, sync: false, setup: nil}, Map.new(opts))
  end)

length_range = 1..3

defmodule Support.GenerateParametricTests do
  def generate(sources, outputs, length_range) do
    transformations = Enum.filter(outputs, & &1.input)
    destinations = Enum.filter(outputs, & &1.dest)

    steps_list = generate_steps_list(sources, transformations, destinations, length_range)

    for steps <- steps_list do
      generate_test(steps)
    end

    code =
      quote do
        defmodule BoomboxGeneratedTest do
          use ExUnit.Case, async: true

          import Support.Async

          alias Support.{Compare, Utils}

          require Logger

          unquote_splicing(Enum.map(steps_list, &generate_test/1) |> remove_redundant_blocks())
        end
      end

    File.write!("test/boombox_generated_test.exs", Macro.to_string(code))
  end

  defp generate_steps_list(sources, transformations, destinations, length_range) do
    Enum.flat_map(length_range, fn steps_cnt ->
      available_steps =
        [sources] ++ Bunch.Enum.repeated(transformations, steps_cnt - 1) ++ [destinations]

      add_steps([], available_steps)
    end)
  end

  defp add_steps(steps, []) do
    [steps]
  end

  defp add_steps(steps, [new_steps | further_steps]) do
    total_steps = length(steps) + length(further_steps)

    for step <- new_steps,
        repeat_cnt = Enum.count(steps, &(&1 == step)),
        repeat_cnt < 2 or (repeat_cnt < 3 and total_steps < 3) do
      steps = steps ++ [step]
      add_steps(steps, further_steps)
    end
    |> Enum.flat_map(& &1)
  end

  defp generate_test(steps) do
    source = hd(steps)
    transformations = tl(steps)
    destination = List.last(steps)
    destination_i = length(steps) - 1

    prepare_src = [
      source.setup,
      quote do
        input = unquote(source.input)
      end
    ]

    runs =
      transformations
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {s, i} ->
        [
          quote do
            out_dir = tmp_dir <> unquote("step_#{i}")
            File.mkdir!(out_dir)
          end,
          s.setup,
          quote do
            output = unquote(s.output)

            unquote(var("t#{i}")) =
              Task.async(fn ->
                Boombox.run(input: input, output: output)
              end)
          end,
          if i == 1 do
            source.feed
          end,
          if s.sync do
            quote do
              Task.await(unquote(var("t#{i}")), 30_000)
            end
          end,
          unless i == destination_i do
            quote do
              input = unquote(s.output)
            end
          end
        ]
      end)

    to_await =
      transformations
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {t, i} -> if t.sync, do: [], else: [var("t#{i}")] end)

    await =
      unless to_await == [], do: quote(do: Task.await_many(unquote(to_await), 30_000))

    transcodings =
      transformations |> Enum.filter(& &1.transcode) |> Enum.map_join(&"_#{&1.transcode}")

    ref_path = destination.dest.("test/fixtures/ref_#{source.ref}#{transcodings}")

    test_body =
      quote do
        unquote_splicing(remove_redundant_blocks(prepare_src ++ runs ++ [await]))

        Compare.compare(
          unquote(destination.output),
          unquote(ref_path),
          unquote(kinds: source.kinds, format: destination.type)
        )
      end

    test_name =
      steps
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map_join(", ", fn [from, to] -> "#{from.type} -> #{to.type}" end)

    test_name = "#{source.name} " <> test_name

    test_tag = Enum.map_join(steps, "_", & &1.type)
    skip_tag = unless File.exists?(ref_path), do: :skip

    tags =
      [:tmp_dir, test_tag, "#{source.name}_#{test_tag}", skip_tag]
      |> Enum.filter(& &1)
      |> Enum.map(&:"#{&1}")
      |> Enum.map(&quote(do: @tag(unquote(&1))))

    quote do
      unquote_splicing(tags)

      async_test unquote(test_name), %{tmp_dir: tmp_dir} do
        unquote(test_body)
      end
    end
  end

  defp remove_redundant_blocks(quotes) when is_list(quotes) do
    Enum.flat_map(quotes, fn
      {:__block__, [], code} -> code
      nil -> []
      code -> [code]
    end)
  end

  defp var(name) do
    Macro.var(:"#{name}", Elixir)
  end
end

Support.GenerateParametricTests.generate(sources, outputs, length_range)
