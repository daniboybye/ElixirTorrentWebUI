# `:macos_integration` tests shell out to `swiftc` to compile and run
# priv/macos/Launcher.swift for real, so they need Xcode and are slower than
# the rest of the suite. They are excluded from a routine `mix test` and opted
# back in explicitly with `mix test --only macos_integration` — wired into the
# macOS release build in .github/workflows/build-macos.yml.
#
# They do not change this machine's default `.torrent`/`magnet:` handler:
# macOS asks the user to confirm that in a modal dialog, which a headless test
# cannot answer. See test/macos/launcher_integration_test.exs.
ExUnit.start(exclude: [:macos_integration])
