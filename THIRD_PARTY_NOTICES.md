# Third-party notices

Notch Assistant is released under the MIT License (see [LICENSE](LICENSE)). One
file contains code adapted from another project, which keeps its own licence.

## Sophon-Realtime

`apps/mac/Resources/sophon_bridge.py` includes code adapted from
[Sophon-Realtime](https://github.com/adventists-ai/sophon-realtime):
`JarvisBrain.reply` and `JarvisBrain._talk` follow `Brain.reply` in its
`mac/engine.py`. They were changed so that a reply can be recognised as a
hand-off before any of it is spoken, and so that given text can be spoken
without the model writing it.

Copyright 2026 Adventists.ai. Licensed under the Apache License, Version 2.0.
A copy of that licence is in [LICENSES/Apache-2.0.txt](LICENSES/Apache-2.0.txt).

Notch Assistant does not include or redistribute Sophon-Realtime itself or any
model weights. The voice on this Mac is installed separately, by the user, from
that project, and its own licence and notices apply to it.
