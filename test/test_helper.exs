# `:macos_integration` tests compile and run priv/macos/Launcher.swift for
# real, mutating this machine's actual default `.torrent`/`magnet:` handler as
# a side effect. That must never happen from a routine `mix test`, so they are
# excluded here and opted back in explicitly with `mix test --only
# macos_integration` — wired into the macOS release build in
# .github/workflows/build-macos.yml, where the runner is ephemeral.
ExUnit.start(exclude: [:macos_integration])
