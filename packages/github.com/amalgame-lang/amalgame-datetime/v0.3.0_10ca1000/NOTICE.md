# NOTICE — amalgame-datetime

## Authorship

Copyright 2026 Bastien Mouget. The Amalgame facade code in this
repository is original work — see `facade.am` and the
`amalgame.toml` manifest.

This package is part of the Amalgame ecosystem
([github.com/amalgame-lang/Amalgame](https://github.com/amalgame-lang/Amalgame)).
It was extracted from amc's bundled `src/stdlib/datetime.am`
during the framework split (post-v0.7.5).

## License

Licensed under the Apache License, Version 2.0 — see `LICENSE`.

## Third-party content

None. The facade is 100% pure-Amalgame. The Hinnant calendar
algorithms (`civil_from_days` / `days_from_civil`) are
public-domain (Howard Hinnant, 2013); the clock syscalls
(`clock_gettime` POSIX / `GetSystemTimeAsFileTime` Windows) are
OS primitives reached via two small `@c { … }` blocks.
