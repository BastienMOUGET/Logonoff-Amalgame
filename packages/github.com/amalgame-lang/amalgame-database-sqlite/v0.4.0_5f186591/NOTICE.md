# NOTICE — amalgame-database-sqlite

## Authorship

Copyright 2026 Bastien Mouget. The Amalgame binding code in this
repository is original work — see `runtime/Amalgame_Database_SQLite.h`
and the `amalgame.toml` manifest.

This package is part of the Amalgame ecosystem
([github.com/amalgame-lang/Amalgame](https://github.com/amalgame-lang/Amalgame)).
External contributions are paused at the ecosystem level; see the
main repo's `CONTRIBUTING.md` for the policy.

AI tools (Anthropic Claude) were used during development. Per
the project's authorship policy, AI is treated as a tool, not a
co-author at law. New commits omit `Co-Authored-By: Claude …`
trailers; the binding code's copyright is held solely by Bastien
Mouget.

## Licence

The Amalgame binding code in this repository is licensed under
the **Apache License 2.0**. The full text is in `LICENSE`.

## Third-party content

This repository vendors the **SQLite amalgamation**
(`runtime/Amalgame_Database/sqlite/sqlite3.c` and `sqlite3.h`)
from [sqlite.org](https://sqlite.org/). The amalgamation is
distributed under SQLite's own **public-domain dedication** —
no copyright restrictions apply to the SQLite code itself.

Quoting [sqlite.org/copyright.html](https://sqlite.org/copyright.html):

> All of the code and documentation in SQLite has been
> dedicated to the public domain by the authors. All code
> authors, and representatives of the companies they work for,
> have signed affidavits dedicating their contributions to the
> public domain and originals of those signed affidavits are
> stored in a firesafe at the main offices of Hwaci. Anyone is
> free to copy, modify, publish, use, compile, sell, or
> distribute the original SQLite code, either in source code
> form or as a compiled binary, for any purpose, commercial or
> non-commercial, and by any means.

The public-domain dedication is **compatible** with the
Apache-2.0 licensing of the surrounding binding code — users
of this package may redistribute the combined work under the
Apache-2.0 terms as written in `LICENSE`.

### Why vendor instead of dynamic-link?

SQLite ships as a single self-contained `sqlite3.c` (the
"amalgamation"), which is the upstream's own recommended way
to embed SQLite. Vendoring avoids requiring users to install a
system-level `libsqlite3-dev` package — particularly painful
on Windows, where there's no equivalent of `apt install` and
binary distributions are scattered. The cost is repo size
(9MB of generated C); we keep it manageable via
`linguist-vendored=true` in `.gitattributes` so GitHub's
language stats reflect the Amalgame binding, not 99% C.

## Trademarks

"SQLite" is a registered trademark of Hwaci. This repository
uses the name solely to identify the database engine being
bound. No trademark claim is asserted.
