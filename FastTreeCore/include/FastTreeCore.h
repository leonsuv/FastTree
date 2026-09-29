#ifndef FASTTREE_CORE_H
#define FASTTREE_CORE_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct FTIndex FTIndex;
typedef struct {
  uint32_t parent, name_offset;
  uint64_t logical_bytes, allocated_bytes;
  uint32_t files, directories;
  uint16_t name_length;
  uint8_t reserved, kind;
  int64_t modified_seconds;
} FTNodeRecord;

FTIndex *ft_index_open(const char *path);
void ft_index_close(FTIndex *index);
uint32_t ft_index_count(const FTIndex *index);
const FTNodeRecord *ft_index_node(const FTIndex *index, uint32_t id);
const char *ft_index_name(const FTIndex *index, uint32_t id, uint16_t *length);
const char *ft_index_root_path(const FTIndex *index, uint32_t *length);
uint32_t ft_index_child_count(const FTIndex *index, uint32_t parent);
uint32_t ft_index_child_at(const FTIndex *index, uint32_t parent, uint32_t offset);
uint32_t ft_index_search(const FTIndex *index, const char *query, uint32_t *results, uint32_t capacity);
uint32_t ft_index_largest_files(const FTIndex *index, uint32_t *results, uint32_t capacity);
uint32_t ft_index_old_large(const FTIndex *index, uint64_t minimum_bytes, int64_t before_seconds, uint32_t *results, uint32_t capacity);

#ifdef __cplusplus
}
#endif
#endif
