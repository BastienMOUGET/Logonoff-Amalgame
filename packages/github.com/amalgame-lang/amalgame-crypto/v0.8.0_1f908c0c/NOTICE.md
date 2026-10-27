# NOTICE — amalgame-crypto

## Authorship

Copyright 2026 Bastien Mouget. The Amalgame facade code in this
repository is original work — see `facade.am` and the
`amalgame.toml` manifest.

This package is part of the Amalgame ecosystem
([github.com/amalgame-lang/Amalgame](https://github.com/amalgame-lang/Amalgame)).
It was extracted from amc's bundled `src/stdlib/crypto.am`
during the framework split (post-v0.7.5).

## License

Licensed under the Apache License, Version 2.0 — see `LICENSE`.

## Third-party content

None. The facade is 100% pure-Amalgame; no vendored C or
external libraries are shipped with this package.

The SHA-256 implementation follows FIPS 180-4 (US NIST,
public-domain specification). The HMAC construction follows
RFC 2104 (public IETF standard).
