# amalgame-crypto

Pure-Amalgame crypto facade for [Amalgame](https://github.com/amalgame-lang/Amalgame).
**SHA-256** (FIPS 180-4) and **HMAC-SHA-256** (RFC 2104).

Originally bundled in amc's `src/stdlib/crypto.am`; extracted into
this external package as part of the framework split (post-v0.7.5).

## Install

```bash
amc package add crypto                  # via the curated index
amc package add github.com/amalgame-lang/amalgame-crypto@v0.1.0
```

Requires **amc 0.7.6+** for the facade pre-compile pipeline
(PR #377). On install, amc compiles `facade.am` into
`~/.amalgame/packages/.../build/<platform>/libamalgame-pkg-Crypto.a`,
and subsequent `amc test` / `amc -o` consume that archive at link
time without re-parsing the facade source.

## Surface

```amalgame
import Amalgame.Crypto

class Program {
    public static void Main() {
        // ── SHA-256 ──────────────────────────────────
        let digest: string = Sha256.OfString("hello")
        Console.WriteLine(digest)
        // 2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824

        // ── HMAC-SHA-256 ─────────────────────────────
        let tag: string = Hmac.Sha256OfStrings("secret-key", "message")
        Console.WriteLine(tag)
    }
}
```

See `facade.am` for the full API — `Sha256.Bytes` / `.Hex` /
`.OfString`, `Hmac.Sha256` / `.Sha256Hex` / `.Sha256OfStrings`.

## Tests

```bash
./tests/run_tests.sh /path/to/amc
```

## License

Apache-2.0 — see `LICENSE`. No vendored third-party code.
