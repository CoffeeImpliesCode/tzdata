/* Fork addition: linkable accessors for the tzcode version strings.
   This file is a fork addition; see NOTICE.md.

   Upstream generates version.h from the 'version' file with the strings as
   per-translation-unit 'static char const' arrays (see the Makefile rule for
   version.h), so they are not reachable through the linker.  zic keeps its own
   copy for --version output; these two functions expose the same strings to
   bindings without touching upstream sources.  */

#include "version.h"

char const *
tzdata_version(void)
{
  return TZVERSION;
}

char const *
tzdata_package(void)
{
  return PKGVERSION;
}