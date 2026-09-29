#include "FastTreeCore.h"
#include <ctype.h>
#include <fcntl.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

typedef struct { char magic[8]; uint32_t version, count; uint64_t names_bytes; uint32_t root_path_bytes, reserved; } Header;
_Static_assert(sizeof(FTNodeRecord)==48,"index version 2 node layout changed");
struct FTIndex {
  void *mapped;
  size_t mapped_bytes;
  const Header *header;
  const FTNodeRecord *nodes;
  const char *names;
  const char *root_path;
  uint32_t *offsets;
  uint32_t *children;
};

FTIndex *ft_index_open(const char *path) {
  int fd=open(path,O_RDONLY);if(fd<0)return NULL;struct stat st;if(fstat(fd,&st)!=0||st.st_size<(off_t)sizeof(Header)){close(fd);return NULL;}
  size_t size=(size_t)st.st_size;void *mapped=mmap(NULL,size,PROT_READ,MAP_PRIVATE,fd,0);close(fd);if(mapped==MAP_FAILED)return NULL;
  const Header *h=mapped;size_t count=h->count;if(memcmp(h->magic,"FTIDX002",8)||h->version!=2||!count||count>(SIZE_MAX-sizeof(Header))/sizeof(FTNodeRecord)||sizeof(Header)+count*sizeof(FTNodeRecord)>size){munmap(mapped,size);return NULL;}
  size_t tail=size-sizeof(Header)-count*sizeof(FTNodeRecord);if(h->names_bytes>tail||h->root_path_bytes>tail-h->names_bytes){munmap(mapped,size);return NULL;}
  FTIndex *ix=calloc(1,sizeof(*ix));if(!ix){munmap(mapped,size);return NULL;}ix->mapped=mapped;ix->mapped_bytes=size;ix->header=h;ix->nodes=(const FTNodeRecord*)((const char*)mapped+sizeof(Header));ix->names=(const char*)(ix->nodes+count);ix->root_path=ix->names+h->names_bytes;
  ix->offsets=calloc(count+1,sizeof(uint32_t));ix->children=malloc((count-1)*sizeof(uint32_t));if(!ix->offsets||(!ix->children&&count>1)){ft_index_close(ix);return NULL;}
  for(uint32_t id=0;id<count;id++){const FTNodeRecord *n=&ix->nodes[id];if((uint64_t)n->name_offset+n->name_length>h->names_bytes||(id&&n->parent>=id)){ft_index_close(ix);return NULL;}if(id)ix->offsets[n->parent+1]++;}
  for(size_t i=1;i<=count;i++)ix->offsets[i]+=ix->offsets[i-1];uint32_t *cursor=malloc(count*sizeof(uint32_t));if(!cursor){ft_index_close(ix);return NULL;}memcpy(cursor,ix->offsets,count*sizeof(uint32_t));for(uint32_t id=1;id<count;id++)ix->children[cursor[ix->nodes[id].parent]++]=id;free(cursor);return ix;
}
void ft_index_close(FTIndex *ix){if(!ix)return;free(ix->offsets);free(ix->children);if(ix->mapped)munmap(ix->mapped,ix->mapped_bytes);free(ix);}
uint32_t ft_index_count(const FTIndex *ix){return ix?ix->header->count:0;}
const FTNodeRecord *ft_index_node(const FTIndex *ix,uint32_t id){return ix&&id<ix->header->count?&ix->nodes[id]:NULL;}
const char *ft_index_name(const FTIndex *ix,uint32_t id,uint16_t *length){const FTNodeRecord *n=ft_index_node(ix,id);if(!n)return NULL;if(length)*length=n->name_length;return ix->names+n->name_offset;}
const char *ft_index_root_path(const FTIndex *ix,uint32_t *length){if(!ix)return NULL;if(length)*length=ix->header->root_path_bytes;return ix->root_path;}
uint32_t ft_index_child_count(const FTIndex *ix,uint32_t parent){return ix&&parent<ix->header->count?ix->offsets[parent+1]-ix->offsets[parent]:0;}
uint32_t ft_index_child_at(const FTIndex *ix,uint32_t parent,uint32_t offset){if(!ix||parent>=ix->header->count||offset>=ft_index_child_count(ix,parent))return UINT32_MAX;return ix->children[ix->offsets[parent]+offset];}
static int contains_casefold(const char *s,size_t n,const char *q,size_t qn){if(!qn)return 1;for(size_t i=0;i+qn<=n;i++){size_t j=0;for(;j<qn;j++)if(tolower((unsigned char)s[i+j])!=tolower((unsigned char)q[j]))break;if(j==qn)return 1;}return 0;}
uint32_t ft_index_search(const FTIndex *ix,const char *query,uint32_t *out,uint32_t capacity){if(!ix||!query||!out)return 0;size_t qn=strlen(query);if(!qn)return 0;uint32_t found=0;for(uint32_t id=1;id<ix->header->count&&found<capacity;id++){const FTNodeRecord *n=&ix->nodes[id];if(contains_casefold(ix->names+n->name_offset,n->name_length,query,qn))out[found++]=id;}return found;}
uint32_t ft_index_largest_files(const FTIndex *ix,uint32_t *out,uint32_t capacity){if(!ix||!out||!capacity)return 0;uint32_t found=0;for(uint32_t id=1;id<ix->header->count;id++){const FTNodeRecord *n=&ix->nodes[id];if(n->kind!=0)continue;uint32_t pos=found<capacity?found:capacity-1;if(found==capacity&&n->allocated_bytes<=ix->nodes[out[pos]].allocated_bytes)continue;while(pos&&n->allocated_bytes>ix->nodes[out[pos-1]].allocated_bytes){if(pos<capacity)out[pos]=out[pos-1];pos--;}out[pos]=id;if(found<capacity)found++;}return found;}
uint32_t ft_index_old_large(const FTIndex *ix,uint64_t minimum,int64_t before,uint32_t *out,uint32_t capacity){if(!ix||!out||!capacity)return 0;uint32_t found=0;for(uint32_t id=1;id<ix->header->count;id++){const FTNodeRecord *n=&ix->nodes[id];if(n->kind!=0||n->allocated_bytes<minimum||n->modified_seconds<=0||n->modified_seconds>=before)continue;uint32_t pos=found<capacity?found:capacity-1;if(found==capacity&&n->allocated_bytes<=ix->nodes[out[pos]].allocated_bytes)continue;while(pos&&n->allocated_bytes>ix->nodes[out[pos-1]].allocated_bytes){if(pos<capacity)out[pos]=out[pos-1];pos--;}out[pos]=id;if(found<capacity)found++;}return found;}
