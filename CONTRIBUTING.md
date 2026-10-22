# Contributing

Thanks for your interest! This is a small hobby project built around one
specific setup (Kindle 5 non-touch, Arduino UNO R4 WiFi, Shelly Plus RGBW PM,
Spotify), so issues and pull requests are welcome, but please keep in mind:

- **Test on real hardware when you can.** The Kindle runs BusyBox 1.7.2 (no
  `od`, no `command -v`, `grep` without `-E`) and the UNO R4 has 32 KB of RAM
  with the sketch close to the limit. The README explains the constraints.
- **Kindle scripts** are plain POSIX `sh`. Every file listed in
  `kindle/ota-files` must end with the line `# ota:end`, and new files must be
  added to that list. `sh -n` must pass.
- **Preview before you push.** `python3 tools/preview.py` renders the Kindle
  screen and `python3 tools/webapp_dev.py` serves the webapp with fake data.
- **Sketch changes:** watch the `Memory:` line printed on serial every 5
  minutes (or `GET /log`) and mention free stack/heap in the PR.
- **Never commit secrets** — `arduino_secrets.h`, `home_config.h`,
  `kindle/config.sh` and `kindle/qr/` are git-ignored for a reason.

CI checks shell and Python syntax, the OTA marker, and that the sketch
compiles with the example configuration.

By contributing you agree that your contributions are licensed under the MIT
License.
