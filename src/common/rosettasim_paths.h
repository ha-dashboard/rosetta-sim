/*
 * rosettasim_paths.h — Shared file path constants for IPC between host and sim
 *
 * All ROSETTASIM_DEV_* paths are relative to the device data root:
 *   - Inside sim: NSHomeDirectory()
 *   - From host:  ~/Library/Developer/CoreSimulator/Devices/{UDID}/data
 *
 * ROSETTASIM_HOST_* paths use /tmp/ (shared namespace, include UDID for uniqueness).
 */

#ifndef ROSETTASIM_PATHS_H
#define ROSETTASIM_PATHS_H

/* Device-relative paths (append to NSHomeDirectory() or device data root) */
#define ROSETTASIM_DEV_TOUCH_FILE       "tmp/rosettasim_touch.json"
#define ROSETTASIM_DEV_TOUCH_BB_FILE    "tmp/rosettasim_touch_bb.json"
#define ROSETTASIM_DEV_TOUCH_LOG        "tmp/rosettasim_touch.log"
#define ROSETTASIM_DEV_TOUCH_INJECT_LOG "tmp/rosettasim_touch_inject.log"
#define ROSETTASIM_DEV_INSTALLED_APPS   "Library/rosettasim_installed_apps.plist"

/* Host-side paths (C format strings — pass UDID as char* arg) */
#define ROSETTASIM_HOST_CMD_FMT         "/tmp/rosettasim_cmd_%s.json"
#define ROSETTASIM_HOST_RESULT_FMT      "/tmp/rosettasim_install_result_%s.txt"

/* NSString format variants (pass UDID as NSString %@ arg) — for ObjC code */
#define ROSETTASIM_HOST_CMD_NSFMT       "/tmp/rosettasim_cmd_%@.json"
#define ROSETTASIM_HOST_RESULT_NSFMT    "/tmp/rosettasim_install_result_%@.txt"

#endif /* ROSETTASIM_PATHS_H */
