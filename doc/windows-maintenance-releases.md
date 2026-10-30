# Publishing a qualified Windows maintenance prefix

This fork can publish a complete Nim maintenance prefix built from an authentic
upstream release plus reviewed backports. A maintenance artifact keeps the
compiler's truthful version. It does not relabel a development compiler as an
older release, replace an installed helper, or move the fork's normal mainline.

## Accept the factory output first

Use the existing Windows prefix qualification workflow and the compiler owner's
`koch boot` and `koch zip` factory. The qualification receipt must be complete
and name the exact published source commit, upstream base, archive filename and
SHA-256. The extracted prefix must pass its compiler/stdlib checks under GCC
and MSVC, and every wrapper path, link and Unicode environment control.

Retain the original official compiler's positive and negative controls separately.
A successful wrapper-only test is not acceptance of a complete prefix.
Do not rebuild an accepted ZIP for publication: publish the exact tested bytes.

## Bind a unique maintenance release

The release tag and asset filename include the full qualified source commit:

- Tag: `nim-<version>-vccexe-<40-character-source-commit>`.
- Asset: `nim-<version>-vccexe-<40-character-source-commit>-windows-x64.zip`.
- Release title: `Nim <version> Windows maintenance prefix`.

The release notes state the authentic upstream tag/commit, the reviewed
backports, the complete-prefix qualification run and the retained archive hash.
For a 2.2.10 backport, the compiler must report 2.2.10; do not imply that the
fork's separate 2.3.1 development line was packaged.

Perform publication from the owning maintenance checkout, with its source
published and clean and its normal commit/push gates satisfied. Verify that the
qualified commit is the intended tag target. Create a signed annotated tag;
refuse an existing tag or release with that name. Never force, retag, replace an
existing asset or use an upload overwrite option.

A publication uses the normal Git/GitHub release tools, not a second build or a
new package installer. After verifying the exact source and accepted files:

```sh
# SOURCE_SHA, RELEASE_TAG and ZIP name come from the accepted qualification.
# SHA256SUMS contains the accepted digest and the ZIP's exact basename.
git tag -s "$RELEASE_TAG" "$SOURCE_SHA" -F release-tag-message.txt
git verify-tag "$RELEASE_TAG"
git push origin "refs/tags/$RELEASE_TAG"
gh release create "$RELEASE_TAG" --verify-tag --target "$SOURCE_SHA" \
  --draft --latest=false --title "Nim 2.2.10 Windows maintenance prefix" \
  --notes-file release-notes.txt "$ZIP" SHA256SUMS
```

Review the draft's exact target, filenames and source/qualification notes.
Download its assets into a fresh verification directory using the normal
GitHub CLI, verify the ZIP against both `SHA256SUMS` and the independently
retained accepted digest, and inspect the published tag target. Only then
publish the draft. Read back the public release and asset URL and repeat the
checksum check. A successful upload alone is not publication verification.

The checksum remains the identity even at a stable release URL. If served
bytes change, the consumer must reject them rather than accept new content.

## Update canonical provisioning together

Only after publication verification, update the existing Windows archive record
in Reprobuild's `repro_dsl_stdlib/packages/nim.nim` and the matching
`BootstrapNimTarballUrl` / `BootstrapNimTarballSha256` constants in
`repro_tool_profiles`. Update the archive lock identity with its digest.
Keep the truthful version, package API, executable/extra-executable paths,
archive layout and other platforms unchanged.

Use one canonical realization, not a duplicate same-version provider or import
order as a selection mechanism. Run the existing acquisition, version-range,
bootstrap hard-failure and installed-prefix controls, then the normal owner
publication and SDK qualification/release process. Consumers take a qualified
SDK release through their existing declared inputs and normal locks. No
consumer helper copy, PATH override or floating archive URL is needed.
