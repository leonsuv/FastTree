#define _DARWIN_C_SOURCE
#include <sys/types.h>
#include <sys/attr.h>
#include <sys/mount.h>
#include <sys/vnode.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/syscall.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>
#include <limits.h>
#include <time.h>
#include <pthread/qos.h>

/* Hybrid bulk scanner with a compact, retained full filesystem index. */
typedef struct Node { uint32_t parent,name_off; uint64_t logical,allocated; uint32_t files,dirs; uint16_t name_len; uint8_t owner,kind; int64_t modified; } Node;
_Static_assert(sizeof(Node)==48,"index node layout must stay versioned");
typedef struct { char magic[8]; uint32_t version,node_count; uint64_t names_bytes; uint32_t root_path_bytes, reserved; } IndexHeader;
typedef struct TopBucket { char *name; uint32_t node_id; } TopBucket;
typedef struct { int fd; TopBucket *top; char *path; uint32_t node_id; } Task;
typedef struct { unsigned char *bytes; size_t length,capacity; uint16_t id; } NameArena;
typedef struct { uint64_t fileid; uint32_t node_id; } DedupEntry;
static pthread_mutex_t qlock=PTHREAD_MUTEX_INITIALIZER, hlock=PTHREAD_MUTEX_INITIALIZER, toplock=PTHREAD_MUTEX_INITIALIZER;
static pthread_mutex_t node_lock=PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t qready=PTHREAD_COND_INITIALIZER;
static Task *queue; static size_t qcap=0,qhead=0,qtail=0,qcount=0;
static uint64_t *seen; static size_t seen_cap=0,seen_count=0;
static TopBucket **top_buckets; static size_t top_count=0,top_cap=0;
static Node *node_chunks[1u<<20];
static NameArena *worker_names; static size_t worker_count=0;
static atomic_uint_fast32_t node_count;
static atomic_uint_fast64_t files,dirs,logical,allocated,hardlinks,skipped;
static atomic_long pending;
static atomic_int incomplete;
static atomic_uint diagnostics;
static dev_t rootdev;
static size_t bufsize=256*1024;
static int stopping=0;
static int benchmark=0;
static int show_progress=0;
static atomic_int progress_done;
static const char *exclusions[256];static size_t exclusion_count=0;
static atomic_uint_fast64_t bulk_calls;
static atomic_uint_fast64_t bulk_ns, open_ns, close_ns, dedupe_ns, index_ns, node_create_ns;
static atomic_uint_fast64_t index_creations;
static double elapsed(struct timespec a,struct timespec b){return (double)(b.tv_sec-a.tv_sec)+(double)(b.tv_nsec-a.tv_nsec)/1e9;}
static uint64_t elapsed_ns(struct timespec a,struct timespec b){return (uint64_t)(b.tv_sec-a.tv_sec)*UINT64_C(1000000000)+(uint64_t)(b.tv_nsec-a.tv_nsec);}
static void failure(const char *reason,const char *path,int code){atomic_store(&incomplete,1);if(atomic_fetch_add(&diagnostics,1)<12)fprintf(stderr,"FTERROR %s path=%s errno=%d\n",reason,path?path:"",code);}

static Node *node_slot(uint32_t id){const size_t chunk=(size_t)id>>12;if(chunk>=(1u<<20)){atomic_store(&incomplete,1);return NULL;}if(!node_chunks[chunk]){pthread_mutex_lock(&node_lock);if(!node_chunks[chunk])node_chunks[chunk]=calloc(4096,sizeof(Node));pthread_mutex_unlock(&node_lock);if(!node_chunks[chunk]){atomic_store(&incomplete,1);return NULL;}}return &node_chunks[chunk][id&4095u];}
static uint32_t node_new(NameArena *arena,uint32_t parent,const char *name,size_t length,uint8_t kind,uint64_t logical_bytes,uint64_t allocated_bytes,uint64_t fileid,int64_t modified){
  struct timespec a,b;if(benchmark)clock_gettime(CLOCK_MONOTONIC,&a);if(length>UINT16_MAX||arena->length>UINT32_MAX-length){atomic_store(&incomplete,1);return UINT32_MAX;}
  if(arena->length+length>arena->capacity){size_t cap=arena->capacity?arena->capacity:4096;while(cap<arena->length+length)cap*=2;unsigned char *p=realloc(arena->bytes,cap);if(!p){atomic_store(&incomplete,1);return UINT32_MAX;}arena->bytes=p;arena->capacity=cap;}
  uint32_t off=(uint32_t)arena->length;if(length)memcpy(arena->bytes+arena->length,name,length);arena->length+=length;uint32_t id=atomic_fetch_add(&node_count,1);Node *node=node_slot(id);if(!node)return UINT32_MAX;node->parent=parent;node->name_off=off;node->name_len=(uint16_t)length;node->owner=(uint8_t)arena->id;node->kind=kind;node->logical=logical_bytes;node->allocated=allocated_bytes;node->modified=modified;node->files=(kind==0&&fileid)?1:0;node->dirs=(kind==1)?1:0;if(benchmark){clock_gettime(CLOCK_MONOTONIC,&b);atomic_fetch_add(&node_create_ns,elapsed_ns(a,b));}return id;
}
static TopBucket *top_for(const char *name,size_t length,uint32_t node_id){
  struct timespec a,b;if(benchmark)clock_gettime(CLOCK_MONOTONIC,&a);pthread_mutex_lock(&toplock);for(size_t i=0;i<top_count;i++)if(strlen(top_buckets[i]->name)==length&&!memcmp(top_buckets[i]->name,name,length)){pthread_mutex_unlock(&toplock);if(benchmark){clock_gettime(CLOCK_MONOTONIC,&b);atomic_fetch_add(&index_ns,elapsed_ns(a,b));}return top_buckets[i];}
  if(top_count==top_cap){size_t cap=top_cap?top_cap*2:32;TopBucket **next=realloc(top_buckets,cap*sizeof(*next));if(!next){atomic_store(&incomplete,1);pthread_mutex_unlock(&toplock);if(benchmark){clock_gettime(CLOCK_MONOTONIC,&b);atomic_fetch_add(&index_ns,elapsed_ns(a,b));}return NULL;}top_buckets=next;top_cap=cap;}
  TopBucket *bucket=calloc(1,sizeof(*bucket));if(!bucket){atomic_store(&incomplete,1);pthread_mutex_unlock(&toplock);if(benchmark){clock_gettime(CLOCK_MONOTONIC,&b);atomic_fetch_add(&index_ns,elapsed_ns(a,b));}return NULL;}bucket->name=strndup(name,length);if(!bucket->name){free(bucket);atomic_store(&incomplete,1);pthread_mutex_unlock(&toplock);if(benchmark){clock_gettime(CLOCK_MONOTONIC,&b);atomic_fetch_add(&index_ns,elapsed_ns(a,b));}return NULL;}bucket->node_id=node_id;top_buckets[top_count++]=bucket;atomic_fetch_add(&index_creations,1);pthread_mutex_unlock(&toplock);if(benchmark){clock_gettime(CLOCK_MONOTONIC,&b);atomic_fetch_add(&index_ns,elapsed_ns(a,b));}return bucket;
}
static char *child_path(const char *parent,const char *name,size_t n){size_t p=strlen(parent);int slash=p>0&&parent[p-1]!='/';char *s=malloc(p+(size_t)slash+n+1);if(!s)return NULL;memcpy(s,parent,p);size_t o=p;if(slash)s[o++]='/';memcpy(s+o,name,n);s[o+n]='\0';return s;}
static int is_excluded(const char *parent,const char *name,size_t n){size_t p=strlen(parent);int slash=p>0&&parent[p-1]!='/';for(size_t i=0;i<exclusion_count;i++){const char *e=exclusions[i];size_t len=strlen(e);if(len!=p+(size_t)slash+n)continue;if(memcmp(e,parent,p))continue;if(slash&&e[p]!='/')continue;if(!memcmp(e+p+slash,name,n))return 1;}return 0;}
static void *progress_worker(void *unused){(void)unused;while(!atomic_load(&progress_done)){fprintf(stderr,"FTPROGRESS {\"files\":%llu,\"dirs\":%llu,\"logical_bytes\":%llu,\"allocated_bytes\":%llu,\"skipped\":%llu}\n",(unsigned long long)atomic_load(&files),(unsigned long long)atomic_load(&dirs),(unsigned long long)atomic_load(&logical),(unsigned long long)atomic_load(&allocated),(unsigned long long)atomic_load(&skipped));fflush(stderr);usleep(200000);}return NULL;}
static void json_string(FILE *f,const char *s){fputc('"',f);for(const unsigned char *p=(const unsigned char*)s;*p;p++){if(*p=='"'||*p=='\\'){fputc('\\',f);fputc(*p,f);}else if(*p=='\n')fputs("\\n",f);else if(*p=='\r')fputs("\\r",f);else if(*p=='\t')fputs("\\t",f);else if(*p<0x20)fprintf(f,"\\u%04x",*p);else fputc(*p,f);}fputc('"',f);}
static void json_name(FILE *f,const unsigned char *s,size_t n){fputc('"',f);for(size_t i=0;i<n;i++){unsigned char c=s[i];if(c=='"'||c=='\\'){fputc('\\',f);fputc(c,f);}else if(c=='\n')fputs("\\n",f);else if(c=='\r')fputs("\\r",f);else if(c=='\t')fputs("\\t",f);else if(c<0x20)fprintf(f,"\\u%04x",c);else fputc(c,f);}fputc('"',f);}
static int write_index(const char *destination,const char *root_path){
  size_t pathlen=strlen(root_path);if(pathlen>UINT32_MAX)return -1;uint64_t bases[64],names_bytes=0;for(size_t i=0;i<worker_count;i++){bases[i]=names_bytes;names_bytes+=worker_names[i].length;}if(names_bytes>UINT32_MAX)return -1;
  size_t temp_len=strlen(destination)+32;char *temp=malloc(temp_len);if(!temp)return -1;snprintf(temp,temp_len,"%s.tmp.%ld",destination,(long)getpid());FILE *f=fopen(temp,"wb");if(!f){free(temp);return -1;}
  uint32_t count=atomic_load(&node_count);IndexHeader h={{'F','T','I','D','X','0','0','2'},2,count,names_bytes,(uint32_t)pathlen,0};int bad=fwrite(&h,sizeof(h),1,f)!=1;
  for(uint32_t id=0;id<count&&!bad;id++){Node copy=*node_slot(id);copy.name_off+=(uint32_t)bases[copy.owner];copy.owner=0;bad=fwrite(&copy,sizeof(copy),1,f)!=1;}
  for(size_t i=0;i<worker_count&&!bad;i++)bad=fwrite(worker_names[i].bytes,1,worker_names[i].length,f)!=worker_names[i].length;
  if(!bad)bad=fwrite(root_path,1,pathlen,f)!=pathlen;if(fflush(f)!=0)bad=1;if(fsync(fileno(f))!=0)bad=1;if(fclose(f)!=0)bad=1;if(!bad&&rename(temp,destination)!=0)bad=1;if(bad)unlink(temp);free(temp);return bad?-1:0;
}

static uint64_t mix(uint64_t x){x^=x>>30;x*=UINT64_C(0xbf58476d1ce4e5b9);x^=x>>27;x*=UINT64_C(0x94d049bb133111eb);return x^(x>>31);}
static void finish_task(void){pthread_mutex_lock(&qlock);long left=atomic_fetch_sub(&pending,1)-1;if(left==0){stopping=1;pthread_cond_broadcast(&qready);}pthread_mutex_unlock(&qlock);}
static int set_add(uint64_t fileid){
  if(!fileid){failure("zero file ID",NULL,0);return 0;}
  pthread_mutex_lock(&hlock);
  if(!seen_cap){seen_cap=65536;seen=calloc(seen_cap,sizeof(*seen));if(!seen){atomic_store(&incomplete,1);pthread_mutex_unlock(&hlock);return 0;}}
  if((seen_count+1)*10>seen_cap*7){size_t n=seen_cap*2;uint64_t *v=calloc(n,sizeof(*v));if(!v){atomic_store(&incomplete,1);pthread_mutex_unlock(&hlock);return 0;}for(size_t i=0;i<seen_cap;i++)if(seen[i]){size_t p=(size_t)mix(seen[i])&(n-1);while(v[p])p=(p+1)&(n-1);v[p]=seen[i];}free(seen);seen=v;seen_cap=n;}
  size_t p=(size_t)mix(fileid)&(seen_cap-1);
  while(seen[p]&&seen[p]!=fileid)p=(p+1)&(seen_cap-1);
  int duplicate=seen[p]!=0;if(duplicate)atomic_fetch_add(&hardlinks,1);else{seen[p]=fileid;seen_count++;}
  pthread_mutex_unlock(&hlock);return duplicate;
}
static void push(int fd,TopBucket *top,char *path,uint32_t node_id){pthread_mutex_lock(&qlock);while(qcount==qcap){size_t old=qcap,n=qcap?qcap*2:256;Task *v=calloc(n,sizeof(*v));if(!v){atomic_fetch_add(&skipped,1);atomic_store(&incomplete,1);if(fd>=0)close(fd);free(path);long left=atomic_fetch_sub(&pending,1)-1;if(left==0){stopping=1;pthread_cond_broadcast(&qready);}pthread_mutex_unlock(&qlock);return;}for(size_t i=0;i<qcount;i++)v[i]=queue[(qhead+i)%old];free(queue);queue=v;qhead=0;qtail=qcount;qcap=n;}
  queue[qtail]=(Task){fd,top,path,node_id};qtail=(qtail+1)%qcap;qcount++;pthread_cond_signal(&qready);pthread_mutex_unlock(&qlock);}
static int pop(Task *task){pthread_mutex_lock(&qlock);while(!qcount&&!stopping)pthread_cond_wait(&qready,&qlock);if(!qcount){pthread_mutex_unlock(&qlock);return 0;}*task=queue[qhead];qhead=(qhead+1)%qcap;qcount--;pthread_mutex_unlock(&qlock);return 1;}

typedef struct __attribute__((packed)) { uint32_t len; attribute_set_t returned; attrreference_t name; fsobj_type_t type; struct timespec modified; uint64_t fileid; off_t alloc; off_t data; } Record;
static void *worker(void *context){NameArena *arena=(NameArena*)context;
#if defined(QOS_CLASS_USER_INITIATED)
  (void)pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED,0);
#endif
  for(;;){Task task;if(!pop(&task))break;int fd=task.fd;
    if(fd<0){struct timespec o0,o1;if(benchmark)clock_gettime(CLOCK_MONOTONIC,&o0);fd=open(task.path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(benchmark){clock_gettime(CLOCK_MONOTONIC,&o1);atomic_fetch_add(&open_ns,elapsed_ns(o0,o1));}if(fd<0){int e=errno;atomic_fetch_add(&skipped,1);if(e!=EACCES&&e!=EPERM&&e!=ENOENT)failure("open directory",task.path,e);free(task.path);finish_task();continue;}}
    unsigned char *buffer=malloc(bufsize+_Alignof(max_align_t));if(!buffer){atomic_fetch_add(&skipped,1);atomic_store(&incomplete,1);close(fd);finish_task();continue;}
    uintptr_t aligned=((uintptr_t)buffer+_Alignof(max_align_t)-1)&~((uintptr_t)_Alignof(max_align_t)-1);unsigned char *bulkbuf=(unsigned char*)aligned;
    const char *rd=getenv("FASTTREE_RDAHEAD");if(rd)(void)fcntl(fd,F_RDAHEAD,atoi(rd)!=0);
    struct attrlist al={0};al.bitmapcount=ATTR_BIT_MAP_COUNT;al.commonattr=ATTR_CMN_RETURNED_ATTRS|ATTR_CMN_NAME|ATTR_CMN_OBJTYPE|ATTR_CMN_MODTIME|ATTR_CMN_FILEID;al.fileattr=ATTR_FILE_ALLOCSIZE|ATTR_FILE_DATALENGTH;
    for(;;){struct timespec b0,b1;if(benchmark)clock_gettime(CLOCK_MONOTONIC,&b0);int n=getattrlistbulk(fd,&al,bulkbuf,(int)bufsize,0);if(benchmark){clock_gettime(CLOCK_MONOTONIC,&b1);atomic_fetch_add(&bulk_calls,1);atomic_fetch_add(&bulk_ns,elapsed_ns(b0,b1));}if(n<0){int e=errno;atomic_fetch_add(&skipped,1);if(e!=EACCES&&e!=EPERM)failure("getattrlistbulk",task.path,e);break;}if(n==0)break;
      unsigned char *p=bulkbuf;
      for(int i=0;i<n;i++){
        Record *r=(Record*)p;if(r->len<offsetof(Record,alloc)||r->len>(uint32_t)(bulkbuf+bufsize-p)){atomic_fetch_add(&skipped,1);failure("invalid record length",task.path,0);break;}
        const char *nm=(const char*)&r->name+ r->name.attr_dataoffset;
        if((const unsigned char*)nm<p||(const unsigned char*)nm>=p+r->len){atomic_fetch_add(&skipped,1);failure("invalid name offset",task.path,0);p+=r->len;continue;}
        size_t maxname=r->len-(size_t)((const unsigned char*)nm-p);size_t nl=strnlen(nm,maxname);
        if(!nl||nl==maxname){atomic_fetch_add(&skipped,1);failure("invalid name length",task.path,0);p+=r->len;continue;}
        if(exclusion_count&&is_excluded(task.path,nm,nl)){atomic_fetch_add(&skipped,1);p+=r->len;continue;}
        if(r->type==VDIR){
          uint32_t node_id=node_new(arena,task.node_id,nm,nl,1,0,0,0,r->modified.tv_sec);
          if(node_id==UINT32_MAX){p+=r->len;continue;}
          TopBucket *top=task.top?task.top:top_for(nm,nl,node_id);
          atomic_fetch_add(&dirs,1);
          struct stat st;
          if(fstatat(fd,nm,&st,AT_SYMLINK_NOFOLLOW)!=0){int e=errno;atomic_fetch_add(&skipped,1);if(e!=EACCES&&e!=EPERM&&e!=ENOENT)failure("fstatat",task.path,e);}
          else if(st.st_dev!=rootdev||!S_ISDIR(st.st_mode))atomic_fetch_add(&skipped,1);
          else{char *path=child_path(task.path,nm,nl);if(!path){atomic_fetch_add(&skipped,1);failure("path allocation",task.path,0);}else{atomic_fetch_add(&pending,1);push(-1,top,path,node_id);}}
        }
        else if(r->type==VREG){struct timespec d0,d1;if(benchmark)clock_gettime(CLOCK_MONOTONIC,&d0);int duplicate=set_add(r->fileid);if(benchmark){clock_gettime(CLOCK_MONOTONIC,&d1);atomic_fetch_add(&dedupe_ns,elapsed_ns(d0,d1));}
          uint64_t a=0,l=0;if(!duplicate&&r->len>=offsetof(Record,data)+sizeof(r->data)){if((r->returned.fileattr&ATTR_FILE_ALLOCSIZE)&&r->alloc>0)a=(uint64_t)r->alloc;if((r->returned.fileattr&ATTR_FILE_DATALENGTH)&&r->data>0)l=(uint64_t)r->data;}uint32_t node_id=node_new(arena,task.node_id,nm,nl,duplicate?2:0,l,a,duplicate?0:r->fileid,r->modified.tv_sec);if(node_id==UINT32_MAX){p+=r->len;continue;}if(!task.top)top_for(nm,nl,node_id);if(!duplicate){atomic_fetch_add(&files,1);atomic_fetch_add(&allocated,a);atomic_fetch_add(&logical,l);}
        }else atomic_fetch_add(&skipped,1);
        p+=r->len;
      }
    }
    free(buffer);struct timespec c0,c1;if(benchmark)clock_gettime(CLOCK_MONOTONIC,&c0);close(fd);if(benchmark){clock_gettime(CLOCK_MONOTONIC,&c1);atomic_fetch_add(&close_ns,elapsed_ns(c0,c1));}free(task.path);
    finish_task();
  }return NULL;
}
static char *make_report(int compact,double scan,double construction,double aggregate,double dedupe,double bulk,double open_s,double close_s,double serialization,double output,double total,size_t *length){char *text=NULL;FILE *f=open_memstream(&text,length);if(!f)return NULL;
  uint32_t count=atomic_load(&node_count);Node *root=node_slot(0);
  fprintf(f,"{\"files\":%llu,\"dirs\":%llu,\"logical_bytes\":%llu,\"allocated_bytes\":%llu,\"hardlinks\":%llu,\"skipped\":%llu,\"incomplete\":%s,\"nodes_retained\":%u,\"top_level\":[",(unsigned long long)atomic_load(&files),(unsigned long long)atomic_load(&dirs),(unsigned long long)atomic_load(&logical),(unsigned long long)atomic_load(&allocated),(unsigned long long)atomic_load(&hardlinks),(unsigned long long)atomic_load(&skipped),atomic_load(&incomplete)?"true":"false",count);
  if(!compact){for(size_t i=0;i<top_count;i++){TopBucket *t=top_buckets[i];Node *n=node_slot(t->node_id);if(i)fputc(',',f);fputs("{\"name\":",f);json_string(f,t->name);fprintf(f,",\"files\":%u,\"dirs\":%u,\"logical_bytes\":%llu,\"allocated_bytes\":%llu}",n->files,n->dirs,(unsigned long long)n->logical,(unsigned long long)n->allocated);}}
  fprintf(f,"],\"top_level_count\":%zu",top_count);
  if(!compact){fputs(",\"nodes\":[",f);for(uint32_t i=0;i<count;i++){Node *n=node_slot(i);if(i)fputc(',',f);fprintf(f,"{\"id\":%u,\"parent\":%u,\"name\":",i,n->parent);NameArena *a=&worker_names[n->owner];json_name(f,a->bytes+n->name_off,n->name_len);fprintf(f,",\"kind\":%u,\"logical_bytes\":%llu,\"allocated_bytes\":%llu,\"files\":%u,\"dirs\":%u}",n->kind,(unsigned long long)n->logical,(unsigned long long)n->allocated,n->files,n->dirs);}fputc(']',f);}
  fprintf(f,",\"stage_seconds\":{\"enumeration\":%.9f,\"tree_construction_cumulative\":%.9f,\"aggregation\":%.9f,\"hardlink_dedupe_cumulative\":%.9f,\"getattrlistbulk_cumulative\":%.9f,\"openat_cumulative\":%.9f,\"close_cumulative\":%.9f,\"serialization\":%.9f,\"output\":%.9f,\"total\":%.9f},\"root_files\":%u,\"root_dirs\":%u}\n",scan,construction,aggregate,dedupe,bulk,open_s,close_s,serialization,output,total,root->files,root->dirs);
  if(fclose(f)!=0){free(text);return NULL;}return text;}
static void usage(void){fprintf(stderr,"usage: fasttree-scan PATH [--json out.json] [--index index.ftidx] [--threads N] [--buffer-size BYTES] [--exclude PATH] [--progress] [--benchmark]\n");}
int main(int argc,char **argv){if(argc<2){usage();return 2;}const char *path=argv[1],*json=NULL,*index_path=NULL;long threads=4;size_t requested_bufsize=0;for(int i=2;i<argc;i++){if(!strcmp(argv[i],"--json")&&i+1<argc)json=argv[++i];else if(!strcmp(argv[i],"--index")&&i+1<argc)index_path=argv[++i];else if(!strcmp(argv[i],"--exclude")&&i+1<argc){if(exclusion_count>=256){usage();return 2;}exclusions[exclusion_count++]=argv[++i];}else if(!strcmp(argv[i],"--progress"))show_progress=1;else if(!strcmp(argv[i],"--threads")&&i+1<argc)threads=strtol(argv[++i],NULL,10);else if(!strcmp(argv[i],"--buffer-size")&&i+1<argc){char *end=NULL;errno=0;unsigned long long v=strtoull(argv[++i],&end,10);if(errno||!end||*end||v<65536||v>1048576){usage();return 2;}requested_bufsize=(size_t)v;}else if(!strcmp(argv[i],"--benchmark"))benchmark=1;else{usage();return 2;}}
  struct timespec started,enum_finished,scan_finished,output_started,output_finished;clock_gettime(CLOCK_MONOTONIC,&started);
  const char *bs=getenv("FASTTREE_ATTRBUF");if(bs){char *end=NULL;errno=0;unsigned long long v=strtoull(bs,&end,10);if(!errno&&end&&!*end&&v>=65536&&v<=1048576)bufsize=(size_t)v;}if(requested_bufsize)bufsize=requested_bufsize;
  if(threads<1)threads=1;if(threads>64)threads=64;
  long fdlimit=1024;const char *fl=getenv("FASTTREE_NOFILE");if(fl){long v=strtol(fl,NULL,10);if(v>0)fdlimit=v;}struct rlimit lim;if(getrlimit(RLIMIT_NOFILE,&lim)==0){rlim_t want=(rlim_t)fdlimit;if(want>lim.rlim_max)want=lim.rlim_max;if(want>lim.rlim_cur){lim.rlim_cur=want;(void)setrlimit(RLIMIT_NOFILE,&lim);}}
#ifdef IOPOL_TYPE_DISK
  const char *ip=getenv("FASTTREE_IOPOLICY");if(ip&&!strcmp(ip,"important")) (void)setiopolicy_np(IOPOL_TYPE_DISK,IOPOL_SCOPE_PROCESS,IOPOL_IMPORTANT);
#endif
  int root=open(path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);if(root<0){perror("open root");return 1;}struct stat st;if(fstat(root,&st)){perror("fstat");close(root);return 1;}rootdev=st.st_dev;atomic_init(&dirs,0);atomic_init(&pending,1);
  worker_count=(size_t)threads;worker_names=calloc(worker_count,sizeof(*worker_names));if(!worker_names){perror("name arenas");close(root);return 1;}for(size_t i=0;i<worker_count;i++)worker_names[i].id=(uint16_t)i;
  atomic_init(&node_count,1);Node *root_node=node_slot(0);if(!root_node){close(root);return 1;}root_node->kind=1;root_node->name_len=1;worker_names[0].bytes=malloc(4096);if(!worker_names[0].bytes){close(root);return 1;}worker_names[0].capacity=4096;worker_names[0].length=1;worker_names[0].bytes[0]='/';
  pthread_t *pool=calloc((size_t)threads,sizeof(*pool));if(!pool){perror("worker pool");close(root);return 1;}pthread_t progress_thread;int progress_started=show_progress&&pthread_create(&progress_thread,NULL,progress_worker,NULL)==0;long created=0;for(;created<threads;created++){if(pthread_create(&pool[created],NULL,worker,&worker_names[created])!=0)break;}push(root,NULL,strdup(path),0);if(created==0)worker(&worker_names[0]);else{for(long i=0;i<created;i++)pthread_join(pool[i],NULL);}free(pool);atomic_store(&progress_done,1);if(progress_started)pthread_join(progress_thread,NULL);
  clock_gettime(CLOCK_MONOTONIC,&enum_finished);uint32_t count=atomic_load(&node_count);for(uint32_t id=count;id-->1;){Node *n=node_slot(id),*parent=node_slot(n->parent);if(!n||!parent){atomic_store(&incomplete,1);break;}parent->logical+=n->logical;parent->allocated+=n->allocated;parent->files+=n->files;parent->dirs+=n->dirs;}clock_gettime(CLOCK_MONOTONIC,&scan_finished);
  if(root_node->files!=atomic_load(&files)||root_node->dirs!=atomic_load(&dirs)||root_node->logical!=atomic_load(&logical)||root_node->allocated!=atomic_load(&allocated))failure("aggregate mismatch",path,0);
  if(index_path&&!atomic_load(&incomplete)&&write_index(index_path,path)!=0){perror("write index");atomic_store(&incomplete,1);}
  double scan_seconds=elapsed(started,enum_finished);double index_seconds=(double)(atomic_load(&index_ns)+atomic_load(&node_create_ns))/1e9,aggregate_seconds=elapsed(enum_finished,scan_finished),dedupe_seconds=(double)atomic_load(&dedupe_ns)/1e9,bulk_seconds=(double)atomic_load(&bulk_ns)/1e9,open_seconds=(double)atomic_load(&open_ns)/1e9,close_seconds=(double)atomic_load(&close_ns)/1e9;
  size_t report_len=0;struct timespec ser0,ser1;clock_gettime(CLOCK_MONOTONIC,&ser0);char *pre=make_report(benchmark,scan_seconds,index_seconds,aggregate_seconds,dedupe_seconds,bulk_seconds,open_seconds,close_seconds,0,0,0,&report_len);clock_gettime(CLOCK_MONOTONIC,&ser1);if(!pre){perror("serialize");return 1;}double serialization_seconds=elapsed(ser0,ser1);free(pre);
  clock_gettime(CLOCK_MONOTONIC,&output_started);char *report=make_report(benchmark,scan_seconds,index_seconds,aggregate_seconds,dedupe_seconds,bulk_seconds,open_seconds,close_seconds,serialization_seconds,0,elapsed(started,scan_finished)+serialization_seconds,&report_len);if(!report){perror("serialize");return 1;}if(json){FILE *f=fopen(json,"w");if(!f){perror("json");free(report);return 1;}int bad=fwrite(report,1,report_len,f)!=report_len||fclose(f)!=0;if(bad){perror("write json");free(report);return 1;}}clock_gettime(CLOCK_MONOTONIC,&output_finished);double output_seconds=elapsed(output_started,output_finished);double total_seconds=elapsed(started,output_finished);
  if(benchmark){free(report);report=make_report(1,scan_seconds,index_seconds,aggregate_seconds,dedupe_seconds,bulk_seconds,open_seconds,close_seconds,serialization_seconds,output_seconds,total_seconds,&report_len);if(!report){perror("serialize");return 1;}if(json){FILE *f=fopen(json,"w");if(!f){perror("json");free(report);return 1;}if(fwrite(report,1,report_len,f)!=report_len||fclose(f)!=0){perror("write json");free(report);return 1;}}fputs(report,stdout);}
  else {fprintf(stdout,"wall_seconds=%.6f status=%s files=%llu dirs=%llu logical_bytes=%llu allocated_bytes=%llu hardlinks=%llu skipped=%llu\n",total_seconds,atomic_load(&incomplete)?"incomplete":"complete",(unsigned long long)atomic_load(&files),(unsigned long long)atomic_load(&dirs),(unsigned long long)atomic_load(&logical),(unsigned long long)atomic_load(&allocated),(unsigned long long)atomic_load(&hardlinks),(unsigned long long)atomic_load(&skipped));}
  free(report);free(seen);free(queue);for(size_t i=0;i<top_count;i++){free(top_buckets[i]->name);free(top_buckets[i]);}free(top_buckets);for(size_t i=0;i<worker_count;i++)free(worker_names[i].bytes);free(worker_names);for(size_t i=0;i<(1u<<20);i++)free(node_chunks[i]);return atomic_load(&incomplete)?2:0;
}
