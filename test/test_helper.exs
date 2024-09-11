Logger.configure(level: :info)
Code.eval_file("#{__DIR__}/generate_parametric_tests.exs")
ExUnit.start(capture_log: true, exclude: [:bun10s_a_mp4_hls, :bun10s_v_mp4_hls])
