/*
 * facade-stub.h — empty runtime header for the datetime facade.
 *
 * The package's API is implemented in `facade.am` (pure Amalgame
 * with two `@c { … }` blocks for clock syscalls); this file
 * exists only because the manifest's `[stdlib].header` field is
 * currently required by PackageRegistry.LoadFrom in amc. The
 * user binary's #include of this header is a no-op.
 */
