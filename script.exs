# :inets.stop()
# :ok = :inets.start()

# {:ok, _server} =
#   :inets.start(:httpd,
#     bind_address: ~c"localhost",
#     port: 1234,
#     document_root: ~c"#{data_dir}",
#     server_name: ~c"assets_server",
#     server_root: ~c"/tmp",
#     erl_script_nocache: true
#   )

out_dir = "."
# Boombox.run(input: {:webrtc, "ws://localhost:8829"}, output: "#{out_dir}/webrtc_to_mp4.mp4")

Boombox.run(input: {:webrtc, "ws://localhost:8829"}, output: {:webrtc, "ws://localhost:8830"})
