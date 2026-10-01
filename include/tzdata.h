/* Aggregate public header for the tzdata Zig package.
   This file is a fork addition; see NOTICE.md and UPSTREAM.md.

   It declares, in one place, every externally visible entry point of the
   tzcode core library as built by this package, so that b.addTranslateC can
   produce complete bindings.  The declarations follow upstream private.h
   (public domain, clarified 1996-06-05 by Arthur David Olson) and are not
   a reimplementation of anything.

   This package always compiles tzcode with '-Dtime_tz=time_t', the upstream
   documented private-time_t mode.  In that mode upstream private.h renames
   every externally visible identifier with a 'tz_' prefix (tz_localtime,
   tz_mktime, tz_tzalloc, ...), so this library can never replace or shadow
   the C library's own localtime/mktime/tzname/timezone/daylight symbols.
   See README.zig.md, section "Symbol isolation".

   The names below are therefore stable for consumers of this package.  */

/* Several names below exist only on some targets, and are guarded by macros
   this build defines from the same values it gives the C compiler:
   TZDATA_HAVE_STRFTIME_L for tz_strftime_l, TZDATA_HAVE_POSIX2008 for
   tz_asctime_r and tz_ctime_r, TZDATA_HAVE_TZNAME for tz_tzname, and
   TZDATA_USG_COMPAT for tz_timezone and tz_daylight.  "Declared here" and
   "emitted by the library" are the same condition, so a binding never sees a
   declaration the library cannot link.  */

#ifndef TZDATA_H
#define TZDATA_H

#include <stddef.h>
#include <time.h>

#ifdef TZDATA_HAVE_STRFTIME_L
# include <locale.h>
#endif

/* TZif on-disk header, exactly as upstream tzfile.h defines it.  tzfile.h is
   public domain (clarified 1996-06-05 by Arthur David Olson); it is included
   rather than copied so the two definitions cannot drift apart.  */
#include "tzfile.h"

/* Upstream spells the opaque reentrant zone handle 'timezone_t'.  */
typedef struct state *timezone_t;

/* NetBSD-inspired reentrant conversions (NETBSD_INSPIRED, always on here).  */
struct tm *tz_localtime_rz(timezone_t, time_t const *restrict, struct tm *restrict);
time_t tz_mktime_z(timezone_t, struct tm *restrict);
timezone_t tz_tzalloc(char const *);
void tz_tzfree(timezone_t);

/* X3J11-inspired conversions (STD_INSPIRED, always on here).  */
struct tm *tz_offtime(time_t const *restrict, long);
struct tm *tz_offtime_r(time_t const *restrict, long, struct tm *restrict);
time_t tz_timelocal(struct tm *restrict);
time_t tz_timeoff(struct tm *restrict, long);
time_t tz_posix2time(time_t);
time_t tz_time2posix(time_t);
time_t tz_posix2time_z(timezone_t, time_t);
time_t tz_time2posix_z(timezone_t, time_t);

/* The POSIX/C surface, in its namespaced form.  */
struct tm *tz_localtime(time_t const *restrict);
struct tm *tz_localtime_r(time_t const *restrict, struct tm *restrict);
struct tm *tz_gmtime(time_t const *restrict);
struct tm *tz_gmtime_r(time_t const *restrict, struct tm *restrict);
time_t tz_mktime(struct tm *restrict);
time_t tz_timegm(struct tm *restrict);
time_t tz_time(time_t *restrict);
void tz_tzset(void);
char *tz_ctime(time_t const *restrict);
char *tz_asctime(struct tm const *restrict);
#ifdef TZDATA_HAVE_POSIX2008
/* Upstream publishes asctime_r and ctime_r only where SUPPORT_POSIX2008 is
   on; elsewhere it renames both to static functions, so no tz_asctime_r or
   tz_ctime_r symbol is emitted (asctime.c:53-62).  */
char *tz_ctime_r(time_t const *restrict, char *restrict);
char *tz_asctime_r(struct tm const *restrict, char *restrict);
#endif
double tz_difftime(time_t, time_t);
size_t tz_strftime(char *restrict, size_t, char const *restrict, struct tm const *restrict);

#ifdef TZDATA_HAVE_STRFTIME_L
size_t tz_strftime_l(char *restrict, size_t, char const *restrict, struct tm const *restrict, locale_t);
#endif

/* Externally visible variables of the namespaced build.  Upstream defines
   these when `2 <= MACRO + TZ_TIME_T` (localtime.c:623-629), and renames
   them to their tz_ spellings in this namespaced build
   (private.h:776-785), so nothing here collides with libc's own variables.  */
#ifdef TZDATA_HAVE_TZNAME
extern char *tz_tzname[2];
#endif
#ifdef TZDATA_USG_COMPAT
extern long tz_timezone;
extern int tz_daylight;
#endif

/* Fork additions: the upstream version strings live in 'version.h' as
   per-translation-unit static arrays, so they need a linkable accessor.  */
char const *tzdata_version(void);
char const *tzdata_package(void);

#endif /* TZDATA_H */