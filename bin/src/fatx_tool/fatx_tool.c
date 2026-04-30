/*
 * fatx_tool - Xbox FATX save extraction/injection tool
 *
 * Usage:
 *   fatx_tool extract --image xbox_hdd.raw --title-id 4D53006E --output ./saves/
 *   fatx_tool inject  --image xbox_hdd.raw --title-id 4D53006E --input ./saves/
 *   fatx_tool list    --image xbox_hdd.raw
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <stdbool.h>
#include <sys/stat.h>

#ifdef _WIN32
#include <direct.h>
#define mkdir(path, mode) _mkdir(path)
#define PATH_SEP "\\"
#else
#include <unistd.h>
#define PATH_SEP "/"
#endif

#include "libfatx/fatx.h"

#define E_DRIVE_OFFSET 0xabe80000
#define E_DRIVE_SIZE   0x1312d6000

static void print_usage(const char *prog) {
    printf("Usage: %s <command> [options]\n", prog);
    printf("\nCommands:\n");
    printf("  extract   Extract save data from HDD image\n");
    printf("  inject    Inject save data into HDD image\n");
    printf("  list      List all UDATA folders in HDD image\n");
    printf("\nOptions:\n");
    printf("  --image <path>     Path to raw Xbox HDD image\n");
    printf("  --title-id <id>    Xbox Title ID (e.g., 4D53006E)\n");
    printf("  --output <dir>     Output directory for extract\n");
    printf("  --input <dir>      Input directory for inject\n");
    printf("\nExamples:\n");
    printf("  %s extract --image xbox_hdd.raw --title-id 4D53006E --output ./saves/\n", prog);
    printf("  %s inject --image xbox_hdd.raw --title-id 4D53006E --input ./saves/\n", prog);
    printf("  %s list --image xbox_hdd.raw\n", prog);
}

static int ensure_dir(const char *path) {
    struct stat st;
    if (stat(path, &st) != 0) {
        if (mkdir(path, 0755) != 0) {
            fprintf(stderr, "Failed to create directory: %s\n", path);
            return -1;
        }
    }
    return 0;
}

static int extract_file(struct fatx_fs *fs, const char *src_path, const char *dst_path) {
    struct fatx_attr attr;
    int status = fatx_get_attr(fs, src_path, &attr);
    if (status != FATX_STATUS_SUCCESS) {
        fprintf(stderr, "Failed to get attr for %s\n", src_path);
        return -1;
    }

    FILE *out = fopen(dst_path, "wb");
    if (!out) {
        fprintf(stderr, "Failed to create file: %s\n", dst_path);
        return -1;
    }

    uint8_t *buf = malloc(attr.file_size);
    if (!buf) {
        fclose(out);
        return -1;
    }

    int bytes_read = fatx_read(fs, src_path, 0, attr.file_size, buf);
    if (bytes_read != attr.file_size) {
        fprintf(stderr, "Failed to read file %s (got %d, expected %zu)\n", src_path, bytes_read, attr.file_size);
        free(buf);
        fclose(out);
        return -1;
    }

    fwrite(buf, 1, attr.file_size, out);
    free(buf);
    fclose(out);
    return 0;
}

static int extract_recursive(struct fatx_fs *fs, const char *fatx_path, const char *local_path) {
    struct fatx_dir dir;
    struct fatx_dirent dirent, *result;
    struct fatx_attr attr;
    int status;

    status = fatx_open_dir(fs, fatx_path, &dir);
    if (status != FATX_STATUS_SUCCESS) {
        fprintf(stderr, "Failed to open dir: %s\n", fatx_path);
        return -1;
    }

    if (ensure_dir(local_path) != 0) {
        fatx_close_dir(fs, &dir);
        return -1;
    }

    while (1) {
        status = fatx_read_dir(fs, &dir, &dirent, &attr, &result);
        if (status == FATX_STATUS_END_OF_DIR) {
            break;
        } else if (status == FATX_STATUS_FILE_DELETED) {
            fatx_next_dir_entry(fs, &dir);
            continue;
        } else if (status != FATX_STATUS_SUCCESS) {
            break;
        }

        char fatx_child[512];
        char local_child[512];
        snprintf(fatx_child, sizeof(fatx_child), "%s/%s", fatx_path, dirent.filename);
        snprintf(local_child, sizeof(local_child), "%s%s%s", local_path, PATH_SEP, dirent.filename);

        if (attr.attributes & FATX_ATTR_DIRECTORY) {
            extract_recursive(fs, fatx_child, local_child);
        } else {
            extract_file(fs, fatx_child, local_child);
        }

        fatx_next_dir_entry(fs, &dir);
    }

    fatx_close_dir(fs, &dir);
    return 0;
}

static int inject_file(struct fatx_fs *fs, const char *src_path, const char *dst_path) {
    FILE *in = fopen(src_path, "rb");
    if (!in) {
        fprintf(stderr, "Failed to open file: %s\n", src_path);
        return -1;
    }

    fseek(in, 0, SEEK_END);
    long size = ftell(in);
    fseek(in, 0, SEEK_SET);

    uint8_t *buf = malloc(size);
    if (!buf) {
        fclose(in);
        return -1;
    }

    fread(buf, 1, size, in);
    fclose(in);

    /* Create parent directory if needed */
    char *parent = fatx_dirname(dst_path);
    struct fatx_attr attr;
    if (fatx_get_attr(fs, parent, &attr) != FATX_STATUS_SUCCESS) {
        fatx_mkdir(fs, parent);
    }
    free(parent);

    /* Create file if it doesn't exist */
    if (fatx_get_attr(fs, dst_path, &attr) != FATX_STATUS_SUCCESS) {
        fatx_mknod(fs, dst_path);
    }

    int bytes_written = fatx_write(fs, dst_path, 0, size, buf);
    free(buf);

    if (bytes_written != size) {
        fprintf(stderr, "Failed to write file %s (wrote %d, expected %ld)\n", dst_path, bytes_written, size);
        return -1;
    }

    return 0;
}

static int inject_recursive(struct fatx_fs *fs, const char *local_path, const char *fatx_path) {
    struct stat st;
    struct dirent *entry;

#ifdef _WIN32
    WIN32_FIND_DATA findData;
    HANDLE hFind;
    char search_path[512];
    snprintf(search_path, sizeof(search_path), "%s\\*", local_path);

    hFind = FindFirstFile(search_path, &findData);
    if (hFind == INVALID_HANDLE_VALUE) {
        return -1;
    }

    do {
        if (strcmp(findData.cFileName, ".") == 0 || strcmp(findData.cFileName, "..") == 0) {
            continue;
        }

        char local_child[512];
        char fatx_child[512];
        snprintf(local_child, sizeof(local_child), "%s%s%s", local_path, PATH_SEP, findData.cFileName);
        snprintf(fatx_child, sizeof(fatx_child), "%s/%s", fatx_path, findData.cFileName);

        if (findData.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
            fatx_mkdir(fs, fatx_child);
            inject_recursive(fs, local_child, fatx_child);
        } else {
            inject_file(fs, local_child, fatx_child);
        }
    } while (FindNextFile(hFind, &findData));

    FindClose(hFind);
#else
    DIR *dir = opendir(local_path);
    if (!dir) {
        return -1;
    }

    while ((entry = readdir(dir)) != NULL) {
        if (strcmp(entry->d_name, ".") == 0 || strcmp(entry->d_name, "..") == 0) {
            continue;
        }

        char local_child[512];
        char fatx_child[512];
        snprintf(local_child, sizeof(local_child), "%s%s%s", local_path, PATH_SEP, entry->d_name);
        snprintf(fatx_child, sizeof(fatx_child), "%s/%s", fatx_path, entry->d_name);

        if (stat(local_child, &st) == 0 && S_ISDIR(st.st_mode)) {
            fatx_mkdir(fs, fatx_child);
            inject_recursive(fs, local_child, fatx_child);
        } else {
            inject_file(fs, local_child, fatx_child);
        }
    }

    closedir(dir);
#endif

    return 0;
}

static int cmd_extract(const char *image_path, const char *title_id, const char *output_dir) {
    struct fatx_fs fs;
    int status;

    memset(&fs, 0, sizeof(fs));
    fatx_log_init(&fs, NULL, FATX_LOG_LEVEL_NONE);

    status = fatx_open_device(&fs, image_path, E_DRIVE_OFFSET, E_DRIVE_SIZE, 512, FATX_READ_FROM_SUPERBLOCK);
    if (status != FATX_STATUS_SUCCESS) {
        fprintf(stderr, "Failed to open HDD image: %s\n", image_path);
        return 1;
    }

    char fatx_path[256];
    snprintf(fatx_path, sizeof(fatx_path), "/UDATA/%s", title_id);

    printf("Extracting %s to %s...\n", fatx_path, output_dir);
    extract_recursive(&fs, fatx_path, output_dir);

    fatx_close_device(&fs);
    printf("Done.\n");
    return 0;
}

static int cmd_inject(const char *image_path, const char *title_id, const char *input_dir) {
    struct fatx_fs fs;
    int status;

    memset(&fs, 0, sizeof(fs));
    fatx_log_init(&fs, NULL, FATX_LOG_LEVEL_NONE);

    status = fatx_open_device(&fs, image_path, E_DRIVE_OFFSET, E_DRIVE_SIZE, 512, FATX_READ_FROM_SUPERBLOCK);
    if (status != FATX_STATUS_SUCCESS) {
        fprintf(stderr, "Failed to open HDD image: %s\n", image_path);
        return 1;
    }

    char fatx_path[256];
    snprintf(fatx_path, sizeof(fatx_path), "/UDATA/%s", title_id);

    /* Ensure UDATA exists */
    struct fatx_attr attr;
    if (fatx_get_attr(&fs, "/UDATA", &attr) != FATX_STATUS_SUCCESS) {
        fatx_mkdir(&fs, "/UDATA");
    }

    printf("Injecting %s into %s...\n", input_dir, fatx_path);
    inject_recursive(&fs, input_dir, fatx_path);

    fatx_close_device(&fs);
    printf("Done.\n");
    return 0;
}

static int cmd_list(const char *image_path) {
    struct fatx_fs fs;
    struct fatx_dir dir;
    struct fatx_dirent dirent, *result;
    struct fatx_attr attr;
    int status;

    memset(&fs, 0, sizeof(fs));
    fatx_log_init(&fs, NULL, FATX_LOG_LEVEL_NONE);

    status = fatx_open_device(&fs, image_path, E_DRIVE_OFFSET, E_DRIVE_SIZE, 512, FATX_READ_FROM_SUPERBLOCK);
    if (status != FATX_STATUS_SUCCESS) {
        fprintf(stderr, "Failed to open HDD image: %s\n", image_path);
        return 1;
    }

    status = fatx_open_dir(&fs, "/UDATA", &dir);
    if (status != FATX_STATUS_SUCCESS) {
        printf("No UDATA directory found.\n");
        fatx_close_device(&fs);
        return 0;
    }

    printf("UDATA folders:\n");
    while (1) {
        status = fatx_read_dir(&fs, &dir, &dirent, &attr, &result);
        if (status == FATX_STATUS_END_OF_DIR) {
            break;
        } else if (status == FATX_STATUS_FILE_DELETED) {
            fatx_next_dir_entry(&fs, &dir);
            continue;
        } else if (status != FATX_STATUS_SUCCESS) {
            break;
        }

        if (attr.attributes & FATX_ATTR_DIRECTORY) {
            printf("  %s\n", dirent.filename);
        }

        fatx_next_dir_entry(&fs, &dir);
    }

    fatx_close_dir(&fs, &dir);
    fatx_close_device(&fs);
    return 0;
}

int main(int argc, char *argv[]) {
    if (argc < 2) {
        print_usage(argv[0]);
        return 1;
    }

    const char *command = argv[1];
    const char *image_path = NULL;
    const char *title_id = NULL;
    const char *output_dir = NULL;
    const char *input_dir = NULL;

    for (int i = 2; i < argc; i++) {
        if (strcmp(argv[i], "--image") == 0 && i + 1 < argc) {
            image_path = argv[++i];
        } else if (strcmp(argv[i], "--title-id") == 0 && i + 1 < argc) {
            title_id = argv[++i];
        } else if (strcmp(argv[i], "--output") == 0 && i + 1 < argc) {
            output_dir = argv[++i];
        } else if (strcmp(argv[i], "--input") == 0 && i + 1 < argc) {
            input_dir = argv[++i];
        }
    }

    if (!image_path) {
        fprintf(stderr, "Error: --image is required\n");
        print_usage(argv[0]);
        return 1;
    }

    if (strcmp(command, "list") == 0) {
        return cmd_list(image_path);
    }

    if (!title_id) {
        fprintf(stderr, "Error: --title-id is required for %s\n", command);
        print_usage(argv[0]);
        return 1;
    }

    if (strcmp(command, "extract") == 0) {
        if (!output_dir) {
            fprintf(stderr, "Error: --output is required for extract\n");
            return 1;
        }
        return cmd_extract(image_path, title_id, output_dir);
    } else if (strcmp(command, "inject") == 0) {
        if (!input_dir) {
            fprintf(stderr, "Error: --input is required for inject\n");
            return 1;
        }
        return cmd_inject(image_path, title_id, input_dir);
    } else {
        fprintf(stderr, "Unknown command: %s\n", command);
        print_usage(argv[0]);
        return 1;
    }
}
