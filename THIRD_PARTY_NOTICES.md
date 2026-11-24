# Third-party notices

Notch Assistant is released under the MIT License (see [LICENSE](LICENSE)). One
file contains code adapted from another project, which keeps its own licence,
one holds icon outlines from another, and the app bundle carries one framework.

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

## Agent marks

`apps/mac/Sources/Assistant/Notch/AgentMark.swift` holds the outlines of the
Claude and Codex marks, converted from the SVG files in
[LobeHub Icons](https://github.com/lobehub/lobe-icons), which is released under
the MIT License.

The marks themselves are trademarks of Anthropic and OpenAI. They are used here
only to say which agent a count in the notch belongs to. Notch Assistant is not
affiliated with or endorsed by either company.

## Sparkle

The app bundle includes [Sparkle](https://github.com/sparkle-project/Sparkle),
which fetches, checks and installs new versions. It is released under the MIT
License, with parts under other permissive licences. Its full `LICENSE` file
is copied into the bundle as `Contents/Resources/Sparkle-LICENSE.txt`.

Copyright (c) 2006-2013 Andy Matuschak.
Copyright (c) 2009-2013 Elgato Systems GmbH.
Copyright (c) 2011-2014 Kornel Lesiński.
Copyright (c) 2015-2017 Mayur Pawashe.
Copyright (c) 2014 C.W. Betts.
Copyright (c) 2014 Petroules Corporation.
Copyright (c) 2014 Big Nerd Ranch.
