# Semantic versioning policy

The package follows Semantic Versioning. Public declarations in the five library
products and generated source shape are stable throughout 1.x. Deprecations stay
available for at least one minor release. Fixes that make malformed input fail
earlier are not considered compatibility breaks.

Internal declarations, executable diagnostics, benchmark numbers, and files
under `Tests` or `Tools` are not API. Wire compatibility follows the pinned
Cap'n Proto 1.x baseline in `Documentation/Compatibility.md`; deviations are
listed there before release.
