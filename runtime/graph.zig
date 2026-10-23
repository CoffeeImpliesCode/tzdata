//! Build the runtime dispatch graph for the translated tzdata header.
//! The dispatch resolves native symbols at run time instead of linking libtz.

const std = @import("std");

/// C sync symbol prefix; it must match `runtime/library.zig`.
const sync_prefix = "tzdata_rt";

/// C-library externs left direct across supported libc headers.
/// Includes unprefixed NetBSD names that tzcode's `tz_` symbols do not provide.
const libc_noise =
    \\__clock_getcpuclockid2,__clock_getres50,__clock_gettime50,__clock_settime50,
    \\__configthreadlocale,__create_locale,__ctime32,__ctime32_s,__ctime50,
    \\__ctime64,__ctime64_s,__ctime_r50,__difftime32,__difftime50,__difftime64,
    \\__daylight,__free_locale,__get_current_locale,__gmtime32,
    \\__gmtime32_s,__gmtime50,__gmtime64,__gmtime64_s,__gmtime_r50,
    \\__localtime32,__localtime32_s,__localtime50,__localtime64,
    \\__localtime64_s,__localtime_r50,__localtime_rz50,__locatime50,
    \\__mkgmtime,__mkgmtime32,__mkgmtime64,
    \\__mktime32,__mktime50,__mktime64,__mktime_z50,__nanosleep50,
    \\__posix2time50,__posix2time_z50,__sysconf,__time32,__time50,__time64,
    \\__time2posix50,__time2posix_z50,__timegm50,__timeoff50,__timelocal50,
    \\__timelocal_z50,__timer_gettime50,__timer_settime50,__timespec32_get,
    \\__timespec64_get,__tzalloc50,__tzfree50,__tzgetgmtoff50,__tzgetname50,
    \\__tzset50,__tzsetwall50,__timezone13,___lc_codepage_func,__wctime32,
    \\__wctime32_s,__wctime64,__wctime64_s,
    \\__tzname,__timezone,
    \\_create_locale,_ctime32,_ctime32_s,_ctime64,_ctime64_s,_ctime_r,
    \\_difftime32,_difftime64,_free_locale,_get_current_locale,_get_daylight,
    \\_get_dstbias,_get_timezone,_get_tzname,_gmtime32,_gmtime32_s,_gmtime64,
    \\_gmtime64_s,_gmtime_r,_localtime32,_localtime32_s,_localtime64,
    \\_localtime64_s,_localtime_r,_mkgmtime,_mkgmtime32,_mkgmtime64,_mktime32,
    \\_mktime64,_mktime_z,_posix2time,_strdate,_strdate_s,_strftime_l,
    \\_strtime,_strtime_s,_time32,_time2posix,_time64,_timegm,_timelocal,
    \\_timeoff,_timespec32_get,_timespec64_get,_tzalloc,_tzfree,_tzgetgmtoff,
    \\_tzgetname,_tzset,_tzsetwall,_wasctime,_wasctime_s,_wctime,_wctime32,
    \\_wctime32_s,_wctime64,_wctime64_s,_wctime_s,_wcreate_locale,_wcsftime_l,
    \\_wsetlocale,_wstrdate,_wstrdate_s,_wstrtime,_wstrtime_s,
    \\asctime,asctime_r,asctime_s,clock,clock_getcpuclockid,clock_getcpuclockid2,
    \\clock_getres,clock_gettime,clock_gettime_nsec_np,clock_nanosleep,
    \\clock_settime,ctime,ctime_r,ctime_rz,ctime_s,daylight,difftime,dysize,
    \\duplocale,freelocale,getdate,getdate_err,getdate_r,gmtime,gmtime_r,
    \\gmtime_s,localtime,localtime_r,localtime_rz,localtime_s,localeconv,
    \\mktime,mktime_z,mktime32,mktime64,mingw_gettimeofday,nanosleep,newlocale,
    \\offtime,offtime_r,posix2time,setlocale,stime,strftime,strftime_l,
    \\strftime_lz,strftime_z,strptime,strptime_l,timer_create,timer_delete,
    \\timer_getoverrun,timer_gettime,timer_oshandle_np,timer_settime,time,
    \\time2posix,time2posix_z,timegm,timeoff,timespec_get,timespec_getres,
    \\timelocal,timelocal_z,tzalloc,tzfree,tzgetgmtoff,tzgetname,tzname,tzset,
    \\tzsetwall,timezone,uselocale,wcsftime,
    \\__dstbias,__mingw_get_crt_info,__prefetch,__wasi_args_get,__wasi_args_sizes_get,
    \\__wasi_clock_res_get,__wasi_clock_time_get,__wasi_environ_get,__wasi_environ_sizes_get,
    \\__wasi_fd_advise,__wasi_fd_allocate,__wasi_fd_close,__wasi_fd_datasync,__wasi_fd_fdstat_get,
    \\__wasi_fd_fdstat_set_flags,__wasi_fd_fdstat_set_rights,__wasi_fd_filestat_get,
    \\__wasi_fd_filestat_set_size,__wasi_fd_filestat_set_times,__wasi_fd_pread,
    \\__wasi_fd_prestat_dir_name,__wasi_fd_prestat_get,__wasi_fd_pwrite,__wasi_fd_read,
    \\__wasi_fd_readdir,__wasi_fd_renumber,__wasi_fd_seek,__wasi_fd_sync,__wasi_fd_tell,
    \\__wasi_fd_write,__wasi_path_create_directory,__wasi_path_filestat_get,
    \\__wasi_path_filestat_set_times,__wasi_path_link,__wasi_path_open,__wasi_path_readlink,
    \\__wasi_path_remove_directory,__wasi_path_rename,__wasi_path_symlink,__wasi_path_unlink_file,
    \\__wasi_poll_oneoff,__wasi_proc_exit,__wasi_random_get,__wasi_sched_yield,__wasi_sock_accept,
    \\__wasi_sock_recv,__wasi_sock_send,__wasi_sock_shutdown,_ftime32,_ftime32_s,_ftime64,_ftime64_s,
    \\_getsystime,_setsystime,clock_getres32,clock_getres64,clock_gettime32,clock_gettime64,
    \\clock_nanosleep32,clock_nanosleep64,clock_settime32,clock_settime64,ftime,nanosleep32,
    \\nanosleep64,
;

/// Optional provider exports; none are configured.
/// The translated macro set keeps required symbols aligned with provider definitions.
const provider_optional = "";

/// Intentionally omitted provider exports; none are excluded.
const provider_excluded = "";

/// Create the linked build's loader-core module.
/// Runtime dispatch builds import their own core and must not add a second instance.
pub fn createCoreModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("runtime/loader.zig"),
        .target = target,
        .optimize = optimize,
        // The Unix loader calls `dlopen` through libc.
        .link_libc = true,
    });
}

/// Build the runtime-loaded C module for this target and translation.
/// Its dispatch reflects the translated header's selected configuration.
pub fn createModule(
    b: *std.Build,
    translate: *std.Build.Step.TranslateC,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const core = createCoreModule(b, target, optimize);

    const library = b.createModule(.{
        .root_source_file = b.path("runtime/library.zig"),
        .target = target,
        .optimize = optimize,
    });
    library.addImport("rt", core);

    return createDispatchModule(b, translate, target, optimize, core, library);
}

const GeneratedSources = struct {
    native: std.Build.LazyPath,
    dispatch: std.Build.LazyPath,
};

fn createDispatchModule(
    b: *std.Build,
    translate: *std.Build.Step.TranslateC,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    core: *std.Build.Module,
    library: *std.Build.Module,
) *std.Build.Module {
    const sources = generateDispatch(b, translate, target);

    const dispatch = b.createModule(.{
        .root_source_file = sources.dispatch,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    dispatch.addImport("rt", core);
    dispatch.addImport("library", library);

    // Preserve nominal types while routing nested translated references through dispatch.
    const native = b.createModule(.{
        .root_source_file = sources.native,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    native.addImport("c_routed", dispatch);
    dispatch.addImport("c_native", native);
    dispatch.addCSourceFiles(.{
        .files = &.{"runtime/sync.c"},
        .flags = &.{b.fmt("-DRT_SYNC_PREFIX={s}", .{sync_prefix})},
        .language = .c,
    });
    return dispatch;
}

fn generateDispatch(
    b: *std.Build,
    translate: *std.Build.Step.TranslateC,
    target: std.Build.ResolvedTarget,
) GeneratedSources {
    const generator = b.addExecutable(.{
        .name = b.fmt("tzdata-runtime-generate-{s}", .{
            target.result.zigTriple(b.allocator) catch @panic("unspellable target"),
        }),
        .root_module = b.createModule(.{
            .root_source_file = b.path("runtime/generate.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
    });

    const run = b.addRunArtifact(generator);
    run.addArg("--library");
    run.addArg("tzdata");
    run.addArg("--translate");
    run.addFileArg(translate.getOutput());
    if (libc_noise.len != 0) {
        run.addArg("--noise");
        run.addArg(libc_noise);
    }
    if (provider_optional.len != 0) {
        run.addArg("--optional");
        run.addArg(provider_optional);
    }
    if (provider_excluded.len != 0) {
        run.addArg("--exclude");
        run.addArg(provider_excluded);
    }
    run.addArg("--native-output");
    const native_source = run.addOutputFileArg("native.zig");
    run.addArg("--output");
    const dispatch_source = run.addOutputFileArg("dispatch.zig");
    return .{ .native = native_source, .dispatch = dispatch_source };
}
