# Contributing

Thanks for wanting to help. Small, focused pull requests are the easiest to say yes to.

## How changes get in

Nobody pushes to `main`, the maintainer included. Every change is a pull request:

1. Fork the repository and make a branch.
2. Make the change. One thing per pull request.
3. Run `make test`.
4. Open a pull request against `main` and fill in the template.

The checks have to pass before a pull request can be merged. If it is your first
one here, the checks wait for the maintainer to start them. For anything large,
open an issue first so nobody builds the wrong thing.

## Building

You need an Apple silicon Mac on macOS 26 or later, and Xcode 27 or the Swift 6.2
toolchain. There is no Xcode project.

```sh
make run     # build, bundle and launch
make test    # the tests
make web     # the landing page on localhost:4321
```

## Where things live

```
apps/mac         the app (SwiftPM)
apps/web         the landing page (plain HTML, CSS and one script, no build step)
plugins/herdr    the herdr plugin (a manifest and one shell script)
```

Logic with no UI goes in `apps/mac/Sources/AssistantCore`, and that is where the
tests look. If you fix a bug there, add the test that would have caught it.

## A few house rules

- The assistant never does the work itself. It listens, talks and hands the work to Claude Code.
- No key ships with the app. The live voice always uses the user's own.
- Nothing leaves the Mac while it is asleep.
- In the app and on the page: no emoji, plain words, and one shape that changes rather than several that appear.
- Commit titles follow Conventional Commits: `feat:`, `fix:`, `docs:`, `chore:`.

## Licence

The project is under the MIT License. By opening a pull request you agree that
your contribution is released under it too.

## Security

Please do not open a public issue for a security problem. See [SECURITY.md](SECURITY.md).
