// C declarations shared by the app and xixuhelper.
// libarchive ships with iOS but its headers are not part of the SDK, so the
// handful of calls Xixu uses are declared here.

#import <Foundation/Foundation.h>
#include <stdint.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/clonefile.h>
#include <copyfile.h>
#include <spawn.h>

#pragma mark - libproc

int proc_pidpath(int pid, void *buffer, uint32_t buffersize);
int proc_listallpids(void *buffer, int buffersize);
int proc_name(int pid, void *buffer, uint32_t buffersize);

#pragma mark - Persona spawning

int posix_spawnattr_set_persona_np(const posix_spawnattr_t *attr, uid_t persona, uint32_t flags);
int posix_spawnattr_set_persona_uid_np(const posix_spawnattr_t *attr, uid_t uid);
int posix_spawnattr_set_persona_gid_np(const posix_spawnattr_t *attr, gid_t gid);

#pragma mark - libarchive

struct archive;
struct archive_entry;

#define LA_OK      0
#define LA_EOF     1
#define LA_RETRY (-10)
#define LA_WARN  (-20)
#define LA_FAILED (-25)
#define LA_FATAL (-30)

#define LA_EXTRACT_PERM                 0x0002
#define LA_EXTRACT_TIME                 0x0004
#define LA_EXTRACT_SECURE_SYMLINKS      0x0100
#define LA_EXTRACT_SECURE_NODOTDOT      0x0200
#define LA_EXTRACT_SECURE_NOABSOLUTEPATHS 0x10000

struct archive *archive_read_new(void);
int archive_read_support_filter_all(struct archive *);
int archive_read_support_format_all(struct archive *);
int archive_read_support_format_raw(struct archive *);
int archive_read_open_filename(struct archive *, const char *filename, size_t block_size);
int archive_read_next_header(struct archive *, struct archive_entry **);
int archive_read_data_skip(struct archive *);
int archive_read_data_block(struct archive *, const void **buff, size_t *size, int64_t *offset);
int archive_read_free(struct archive *);
int archive_format(struct archive *);

struct archive *archive_write_disk_new(void);
int archive_write_disk_set_options(struct archive *, int flags);
int archive_write_disk_set_standard_lookup(struct archive *);

struct archive *archive_write_new(void);
int archive_write_set_format_zip(struct archive *);
int archive_write_open_filename(struct archive *, const char *file);
int archive_write_header(struct archive *, struct archive_entry *);
ssize_t archive_write_data(struct archive *, const void *, size_t);
ssize_t archive_write_data_block(struct archive *, const void *, size_t, int64_t);
int archive_write_finish_entry(struct archive *);
int archive_write_close(struct archive *);
int archive_write_free(struct archive *);

const char *archive_error_string(struct archive *);
int64_t archive_filter_bytes(struct archive *, int);

struct archive_entry *archive_entry_new(void);
void archive_entry_free(struct archive_entry *);
const char *archive_entry_pathname(struct archive_entry *);
void archive_entry_copy_pathname(struct archive_entry *, const char *);
const char *archive_entry_hardlink(struct archive_entry *);
void archive_entry_copy_hardlink(struct archive_entry *, const char *);
void archive_entry_copy_symlink(struct archive_entry *, const char *);
void archive_entry_copy_stat(struct archive_entry *, const struct stat *);
int64_t archive_entry_size(struct archive_entry *);
void archive_entry_set_size(struct archive_entry *, int64_t);
mode_t archive_entry_filetype(struct archive_entry *);
time_t archive_entry_mtime(struct archive_entry *);

#pragma mark - LaunchServices exception guards (app only, Guard.m)

NSArray<NSObject *> * _Nonnull XXInstalledApplications(void);
id _Nullable XXSafeValueForKey(NSObject * _Nonnull object, NSString * _Nonnull key);
BOOL XXOpenApplication(NSString * _Nonnull bundleID);
