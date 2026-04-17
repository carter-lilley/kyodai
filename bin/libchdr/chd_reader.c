#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "libchdr/chd.h"

#define SECTOR_SIZE 2048

static const uint8_t CD_SYNC_PATTERN[12] = {
    0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00
};

typedef struct {
    chd_file *chd;
    uint8_t *hunk_buffer;
    uint32_t hunk_bytes;
    uint32_t unit_bytes;
    uint32_t frames_per_hunk;
    uint32_t total_frames;
    uint32_t data_offset;
    int last_hunk;
} chd_context;

static chd_context* open_chd_file(const char *path) {
    chd_file *chd = NULL;
    chd_error err = chd_open(path, CHD_OPEN_READ, NULL, &chd);
    if (err != CHDERR_NONE) {
        fprintf(stderr, "chd_open failed: %d\\n", err);
        return NULL;
    }

    const chd_header *header = chd_get_header(chd);
    if (header->unitbytes == 0 || header->hunkbytes == 0) {
        fprintf(stderr, "Invalid CHD header\\n");
        chd_close(chd);
        return NULL;
    }

    chd_context *ctx = (chd_context *)calloc(1, sizeof(chd_context));
    if (!ctx) {
        chd_close(chd);
        return NULL;
    }

    ctx->hunk_buffer = (uint8_t *)malloc(header->hunkbytes);
    if (!ctx->hunk_buffer) {
        chd_close(chd);
        free(ctx);
        return NULL;
    }

    ctx->chd = chd;
    ctx->hunk_bytes = header->hunkbytes;
    ctx->unit_bytes = header->unitbytes;
    ctx->last_hunk = -1;
    ctx->frames_per_hunk = ctx->hunk_bytes / ctx->unit_bytes;
    ctx->total_frames = (uint32_t)(header->logicalbytes / ctx->unit_bytes);
    ctx->data_offset = 0;

    // Detect data offset for CD-ROM sectors
    if (ctx->unit_bytes > SECTOR_SIZE) {
        int hi = 16 / ctx->frames_per_hunk;
        err = chd_read(ctx->chd, hi, ctx->hunk_buffer);
        if (err == CHDERR_NONE) {
            int fi = 16 % ctx->frames_per_hunk;
            uint8_t *frame = ctx->hunk_buffer + fi * ctx->unit_bytes;
            if (memcmp(frame, CD_SYNC_PATTERN, 12) == 0) {
                ctx->data_offset = 24; // MODE2_RAW: sync(12) + header(4) + subheader(8)
            }
        }
        ctx->last_hunk = -1;
    }

    return ctx;
}

static int chd_read_sector(chd_context *ctx, uint32_t lba, uint8_t *output) {
    if (lba >= ctx->total_frames) return -1;

    int hunk_index = lba / ctx->frames_per_hunk;
    int frame_in_hunk = lba % ctx->frames_per_hunk;

    if (hunk_index != ctx->last_hunk) {
        chd_error err = chd_read(ctx->chd, hunk_index, ctx->hunk_buffer);
        if (err != CHDERR_NONE) {
            fprintf(stderr, "chd_read hunk %d failed: %d\\n", hunk_index, err);
            return -1;
        }
        ctx->last_hunk = hunk_index;
    }

    uint8_t *sector_data = ctx->hunk_buffer + (frame_in_hunk * ctx->unit_bytes) + ctx->data_offset;
    memcpy(output, sector_data, SECTOR_SIZE);
    return 0;
}

static void close_chd_file(chd_context *ctx) {
    if (!ctx) return;
    if (ctx->chd) chd_close(ctx->chd);
    free(ctx->hunk_buffer);
    free(ctx);
}

int main(int argc, char *argv[]) {
    if (argc < 3) {
        fprintf(stderr, "Usage: %s <chd_file> <sector_lba> [output_file]\\n", argv[0]);
        fprintf(stderr, "       %s <chd_file> dump <start_lba> <count> <output_prefix>\\n", argv[0]);
        return 1;
    }

    const char *path = argv[1];
    chd_context *ctx = open_chd_file(path);
    if (!ctx) {
        fprintf(stderr, "Failed to open CHD: %s\n", path);
        return 1;
    }

    if (strcmp(argv[2], "dump") == 0) {
        if (argc < 6) {
            fprintf(stderr, "Usage: %s <chd_file> dump <start_lba> <count> <output_prefix>\n", argv[0]);
            close_chd_file(ctx);
            return 1;
        }
        
        uint32_t start_lba = atoi(argv[3]);
        uint32_t count = atoi(argv[4]);
        const char *prefix = argv[5];
        
        uint8_t sector[SECTOR_SIZE];
        for (uint32_t i = 0; i < count; i++) {
            uint32_t lba = start_lba + i;
            if (chd_read_sector(ctx, lba, sector) != 0) {
                fprintf(stderr, "Failed to read sector %u\n", lba);
                break;
            }
            
            char filename[256];
            snprintf(filename, sizeof(filename), "%s_%08u.bin", prefix, lba);
            FILE *fp = fopen(filename, "wb");
            if (fp) {
                fwrite(sector, 1, SECTOR_SIZE, fp);
                fclose(fp);
            }
        }
        printf("Dumped %u sectors to %s_*.bin\n", count, prefix);
    } else {
        uint32_t lba = atoi(argv[2]);
        uint8_t sector[SECTOR_SIZE];
        
        if (chd_read_sector(ctx, lba, sector) != 0) {
            fprintf(stderr, "Failed to read sector %u\n", lba);
            close_chd_file(ctx);
            return 1;
        }
        
        if (argc >= 4) {
            FILE *fp = fopen(argv[3], "wb");
            if (!fp) {
                fprintf(stderr, "Failed to open output file: %s\n", argv[3]);
                close_chd_file(ctx);
                return 1;
            }
            fwrite(sector, 1, SECTOR_SIZE, fp);
            fclose(fp);
        } else {
            fwrite(sector, 1, SECTOR_SIZE, stdout);
        }
    }

    close_chd_file(ctx);
            return 1;
        }
        
        uint32_t start_lba = atoi(argv[3]);
        uint32_t count = atoi(argv[4]);
        const char *prefix = argv[5];
        
        uint8_t sector[SECTOR_SIZE];
        for (uint32_t i = 0; i < count; i++) {
            uint32_t lba = start_lba + i;
            if (chd_read_sector(ctx, lba, sector) != 0) {
                fprintf(stderr, "Failed to read sector %u\\n", lba);
                break;
            }
            
            char filename[256];
            snprintf(filename, sizeof(filename), "%s_%08u.bin", prefix, lba);
            FILE *fp = fopen(filename, "wb");
            if (fp) {
                fwrite(sector, 1, SECTOR_SIZE, fp);
                fclose(fp);
            }
        }
        printf("Dumped %u sectors to %s_*.bin\\n", count, prefix);
    } else {
        uint32_t lba = atoi(argv[2]);
        uint8_t sector[SECTOR_SIZE];
        
        if (chd_read_sector(ctx, lba, sector) != 0) {
            fprintf(stderr, "Failed to read sector %u\\n", lba);
            chd_close_file(ctx);
            return 1;
        }
        
        if (argc >= 4) {
            FILE *fp = fopen(argv[3], "wb");
            if (!fp) {
                fprintf(stderr, "Failed to open output file: %s\\n", argv[3]);
                chd_close_file(ctx);
                return 1;
            }
            fwrite(sector, 1, SECTOR_SIZE, fp);
            fclose(fp);
        } else {
            fwrite(sector, 1, SECTOR_SIZE, stdout);
        }
    }

    chd_close_file(ctx);
    return 0;
}
