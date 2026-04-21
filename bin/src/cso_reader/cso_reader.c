#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <zlib.h>

#define CSO_SECTOR_SIZE 2048
#define CSO_HEADER_SIZE 24
#define CSO_MAGIC "CISO"

/* CSO file format structures */
typedef struct {
    char magic[4];
    uint32_t header_size;
    uint64_t uncompressed_size;
    uint32_t block_size;
    uint8_t version;
    uint8_t alignment;
    uint8_t reserved[2];
} __attribute__((packed)) cso_header_t;

/* ISO9660 directory entry */
typedef struct {
    uint8_t length;
    uint8_t ext_attr_length;
    uint32_t extent_lsb;
    uint32_t extent_msb;
    uint32_t size_lsb;
    uint32_t size_msb;
    uint8_t date[7];
    uint8_t flags;
    uint8_t file_unit_size;
    uint8_t interleave_gap;
    uint16_t vol_seq_lsb;
    uint16_t vol_seq_msb;
    uint8_t name_len;
    char name[1];
} __attribute__((packed)) iso_dir_entry_t;

/* SFO file format structures */
typedef struct {
    uint32_t magic;       /* 0x46535000 = "PSF\0" */
    uint32_t version;
    uint32_t key_table_start;
    uint32_t data_table_start;
    uint32_t index_entries;
} __attribute__((packed)) sfo_header_t;

typedef struct {
    uint16_t key_offset;
    uint16_t data_fmt;
    uint32_t data_len;
    uint32_t data_max_len;
    uint32_t data_offset;
} __attribute__((packed)) sfo_index_entry_t;

static int read_cso_block(FILE *fp, const cso_header_t *hdr, uint32_t *index_table, 
                          uint32_t block_idx, uint8_t *output) {
    uint32_t block_offset = index_table[block_idx];
    uint32_t next_block_offset = index_table[block_idx + 1];
    int is_uncompressed = (block_offset & 0x80000000) != 0;
    uint32_t file_offset = (block_offset & 0x7FFFFFFF) << hdr->alignment;
    uint32_t next_offset = (next_block_offset & 0x7FFFFFFF) << hdr->alignment;
    uint32_t compressed_size = next_offset - file_offset;
    
    if (is_uncompressed) {
        if (fseek(fp, file_offset, SEEK_SET) != 0) return -1;
        if (fread(output, 1, hdr->block_size, fp) != hdr->block_size) return -1;
        return 0;
    }
    
    uint8_t *compressed = (uint8_t*)malloc(compressed_size);
    if (!compressed) return -1;
    
    if (fseek(fp, file_offset, SEEK_SET) != 0) {
        free(compressed);
        return -1;
    }
    
    if (fread(compressed, 1, compressed_size, fp) != compressed_size) {
        free(compressed);
        return -1;
    }
    
    /* Use raw deflate (no zlib header) */
    z_stream strm = {0};
    strm.zalloc = Z_NULL;
    strm.zfree = Z_NULL;
    strm.opaque = Z_NULL;
    strm.avail_in = compressed_size;
    strm.next_in = compressed;
    strm.avail_out = hdr->block_size;
    strm.next_out = output;
    
    /* -15 = raw deflate, 15-bit window */
    if (inflateInit2(&strm, -15) != Z_OK) {
        free(compressed);
        return -1;
    }
    
    int ret = inflate(&strm, Z_FINISH);
    inflateEnd(&strm);
    free(compressed);
    
    if (ret != Z_STREAM_END && ret != Z_OK) {
        return -1;
    }
    
    return 0;
}

static int find_file_in_iso(FILE *fp, const cso_header_t *hdr, uint32_t *index_table,
                            uint32_t dir_lba, uint32_t dir_size,
                            const char *filename, uint32_t *out_lba, uint32_t *out_size) {
    uint8_t *sector = (uint8_t*)malloc(hdr->block_size);
    if (!sector) return -1;
    
    uint32_t sectors_needed = (dir_size + hdr->block_size - 1) / hdr->block_size;
    
    for (uint32_t i = 0; i < sectors_needed; i++) {
        if (read_cso_block(fp, hdr, index_table, dir_lba + i, sector) != 0) {
            free(sector);
            return -1;
        }
        
        uint32_t offset = 0;
        while (offset < hdr->block_size) {
            iso_dir_entry_t *entry = (iso_dir_entry_t*)(sector + offset);
            if (entry->length == 0) break;
            
            char name[256] = {0};
            memcpy(name, entry->name, entry->name_len);
            
            /* Remove version suffix (;1) */
            char *semicolon = strchr(name, ';');
            if (semicolon) *semicolon = '\0';
            
            if (strcasecmp(name, filename) == 0) {
                *out_lba = entry->extent_lsb;
                *out_size = entry->size_lsb;
                free(sector);
                return 0;
            }
            
            offset += entry->length;
        }
    }
    
    free(sector);
    return -1;
}

static int parse_sfo_disc_id(const uint8_t *sfo_data, uint32_t sfo_size, char *disc_id, size_t disc_id_size) {
    if (sfo_size < sizeof(sfo_header_t)) return -1;
    
    sfo_header_t *header = (sfo_header_t*)sfo_data;
    if (header->magic != 0x46535000) return -1; /* "PSF\0" */
    
    for (uint32_t i = 0; i < header->index_entries; i++) {
        sfo_index_entry_t *entry = (sfo_index_entry_t*)(sfo_data + sizeof(sfo_header_t) + i * sizeof(sfo_index_entry_t));
        
        const char *key = (const char*)(sfo_data + header->key_table_start + entry->key_offset);
        if (strcmp(key, "DISC_ID") == 0) {
            const char *value = (const char*)(sfo_data + header->data_table_start + entry->data_offset);
            
            /* Copy and normalize (remove hyphens) */
            size_t len = entry->data_len;
            if (len > disc_id_size - 1) len = disc_id_size - 1;
            
            size_t j = 0;
            for (size_t k = 0; k < len && j < disc_id_size - 1; k++) {
                if (value[k] == '-') continue;
                disc_id[j++] = value[k];
            }
            disc_id[j] = '\0';
            return 0;
        }
    }
    
    return -1;
}

int main(int argc, char *argv[]) {
    if (argc < 2) {
        fprintf(stderr, "Usage: %s <cso_file>\n", argv[0]);
        return 1;
    }
    
    FILE *fp = fopen(argv[1], "rb");
    if (!fp) {
        fprintf(stderr, "Failed to open file: %s\n", argv[1]);
        return 1;
    }
    
    /* Read CSO header */
    cso_header_t hdr;
    if (fread(&hdr, 1, sizeof(hdr), fp) != sizeof(hdr)) {
        fprintf(stderr, "Failed to read CSO header\n");
        fclose(fp);
        return 1;
    }
    
    if (memcmp(hdr.magic, CSO_MAGIC, 4) != 0) {
        fprintf(stderr, "Invalid CSO magic\n");
        fclose(fp);
        return 1;
    }
    
    /* Handle buggy CSO files with header_size = 0 */
    if (hdr.header_size == 0) {
        hdr.header_size = CSO_HEADER_SIZE;
    }
    
    uint32_t total_blocks = (uint32_t)(hdr.uncompressed_size / hdr.block_size);
    
    /* Read index table */
    uint32_t *index_table = (uint32_t*)malloc((total_blocks + 1) * sizeof(uint32_t));
    if (!index_table) {
        fprintf(stderr, "Failed to allocate index table\n");
        fclose(fp);
        return 1;
    }
    
    if (fseek(fp, hdr.header_size, SEEK_SET) != 0 ||
        fread(index_table, sizeof(uint32_t), total_blocks + 1, fp) != total_blocks + 1) {
        fprintf(stderr, "Failed to read index table\n");
        free(index_table);
        fclose(fp);
        return 1;
    }
    
    /* Read PVD from sector 16 */
    uint8_t *pvd = (uint8_t*)malloc(hdr.block_size);
    if (!pvd) {
        free(index_table);
        fclose(fp);
        return 1;
    }
    
    if (read_cso_block(fp, &hdr, index_table, 16, pvd) != 0) {
        fprintf(stderr, "Failed to read PVD\n");
        free(pvd);
        free(index_table);
        fclose(fp);
        return 1;
    }
    
    /* Validate PVD */
    if (pvd[0] != 0x01 || memcmp(pvd + 1, "CD001", 5) != 0) {
        fprintf(stderr, "Invalid PVD\n");
        free(pvd);
        free(index_table);
        fclose(fp);
        return 1;
    }
    
    /* Get root directory from PVD */
    uint32_t root_lba = *(uint32_t*)(pvd + 156 + 2);
    uint32_t root_size = *(uint32_t*)(pvd + 156 + 10);
    
    free(pvd);
    
    /* Find PSP_GAME directory */
    uint32_t psp_game_lba, psp_game_size;
    if (find_file_in_iso(fp, &hdr, index_table, root_lba, root_size, "PSP_GAME", &psp_game_lba, &psp_game_size) != 0) {
        fprintf(stderr, "PSP_GAME directory not found\n");
        free(index_table);
        fclose(fp);
        return 1;
    }
    
    /* Find PARAM.SFO file */
    uint32_t sfo_lba, sfo_size;
    if (find_file_in_iso(fp, &hdr, index_table, psp_game_lba, psp_game_size, "PARAM.SFO", &sfo_lba, &sfo_size) != 0) {
        fprintf(stderr, "PARAM.SFO not found\n");
        free(index_table);
        fclose(fp);
        return 1;
    }
    
    /* Read PARAM.SFO data */
    uint32_t sfo_sectors = (sfo_size + hdr.block_size - 1) / hdr.block_size;
    uint8_t *sfo_data = (uint8_t*)malloc(sfo_sectors * hdr.block_size);
    if (!sfo_data) {
        free(index_table);
        fclose(fp);
        return 1;
    }
    
    for (uint32_t i = 0; i < sfo_sectors; i++) {
        if (read_cso_block(fp, &hdr, index_table, sfo_lba + i, sfo_data + i * hdr.block_size) != 0) {
            fprintf(stderr, "Failed to read PARAM.SFO sector %u\n", i);
            free(sfo_data);
            free(index_table);
            fclose(fp);
            return 1;
        }
    }
    
    /* Extract DISC_ID */
    char disc_id[16] = {0};
    if (parse_sfo_disc_id(sfo_data, sfo_size, disc_id, sizeof(disc_id)) != 0) {
        fprintf(stderr, "Failed to parse DISC_ID\n");
        free(sfo_data);
        free(index_table);
        fclose(fp);
        return 1;
    }
    
    printf("%s\n", disc_id);
    
    free(sfo_data);
    free(index_table);
    fclose(fp);
    
    return 0;
}
