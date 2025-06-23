max_cases =
  if System.get_env("CIRCLECI") == "true",
    do: 1,
    else: System.schedulers_online() * 2

ExUnit.start(capture_log: true, max_cases: max_cases)
