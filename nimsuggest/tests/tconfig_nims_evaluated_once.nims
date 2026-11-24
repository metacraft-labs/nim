# Config for tconfig_nims_evaluated_once.nim; see the comment there.
import std/os

# The crash shape, measured on codetracer's config.nims: twenty top-level
# calls, then a top-level `for` over strings. A re-run compiles the whole
# script again before running any of it, and its loop variable's slot is
# stale; the .nim file says how that ends.
proc addPathIfDir(path: string) =
  if path.len > 0 and dirExists(path):
    switch("path", path)

addPathIfDir(getEnv("TCONFIG_NIMS_NO_SUCH_VAR_0"))
addPathIfDir(getEnv("TCONFIG_NIMS_NO_SUCH_VAR_1"))
addPathIfDir(getEnv("TCONFIG_NIMS_NO_SUCH_VAR_2"))
addPathIfDir(getEnv("TCONFIG_NIMS_NO_SUCH_VAR_3"))
addPathIfDir(getEnv("TCONFIG_NIMS_NO_SUCH_VAR_4"))
addPathIfDir(getEnv("TCONFIG_NIMS_NO_SUCH_VAR_5"))
addPathIfDir(getEnv("TCONFIG_NIMS_NO_SUCH_VAR_6"))
addPathIfDir(getEnv("TCONFIG_NIMS_NO_SUCH_VAR_7"))
addPathIfDir(getEnv("TCONFIG_NIMS_NO_SUCH_VAR_8"))
addPathIfDir(getEnv("TCONFIG_NIMS_NO_SUCH_VAR_9"))
addPathIfDir(getEnv("TCONFIG_NIMS_NO_SUCH_VAR_10"))
addPathIfDir(getEnv("TCONFIG_NIMS_NO_SUCH_VAR_11"))
addPathIfDir(getEnv("TCONFIG_NIMS_NO_SUCH_VAR_12"))
addPathIfDir(getEnv("TCONFIG_NIMS_NO_SUCH_VAR_13"))
addPathIfDir(getEnv("TCONFIG_NIMS_NO_SUCH_VAR_14"))
addPathIfDir(getEnv("TCONFIG_NIMS_NO_SUCH_VAR_15"))
addPathIfDir(getEnv("TCONFIG_NIMS_NO_SUCH_VAR_16"))
addPathIfDir(getEnv("TCONFIG_NIMS_NO_SUCH_VAR_17"))
addPathIfDir(getEnv("TCONFIG_NIMS_NO_SUCH_VAR_18"))
addPathIfDir(getEnv("TCONFIG_NIMS_NO_SUCH_VAR_19"))

for lib in ["a", "b"]:
  addPathIfDir(getEnv("TCONFIG_NIMS_NO_SUCH_VAR") / lib)

# A script without that shape is still run twice by such a re-run; this
# fails the second time, so nimsuggest dies on it too.
doAssert getEnv("TCONFIG_NIMS_EVALUATED_ONCE") == "",
  "nimsuggest evaluated tconfig_nims_evaluated_once.nims twice"
putEnv("TCONFIG_NIMS_EVALUATED_ONCE", "1")
