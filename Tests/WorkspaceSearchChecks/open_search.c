#include <sys/types.h>
#include <sys/stat.h>
#include <sys/acl.h>
#include <sys/xattr.h>
#include <dirent.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static int failures=0;
static void check(int ok,const char* label){printf("%s %s errno=%d\n",ok?"PASS":"FAIL",label,errno);if(!ok)failures++;}
int main(void){
 char root[]="/private/tmp/mini-sandbox-search-probe-XXXXXX";if(!mkdtemp(root))return 2;
 int common=O_CLOEXEC|O_NOFOLLOW|O_NONBLOCK|O_DIRECTORY;
 int r=open(root,O_RDONLY|common);if(r<0)return 2;
 mkdirat(r,"ancestor",0700);int setup=openat(r,"ancestor",O_RDONLY|common);
 mkdirat(setup,"selected",0700);int sel=openat(setup,"selected",O_RDONLY|common);
 int file=openat(sel,"data",O_CREAT|O_EXCL|O_WRONLY|O_NOFOLLOW|O_CLOEXEC,0600);write(file,"ok",2);close(file);
 symlinkat("selected",setup,"link");fchmod(setup,0100);
 errno=0;int rd=openat(r,"ancestor",O_RDONLY|common);check(rd<0&&errno==EACCES,"read denied on execute-only ancestor");if(rd>=0)close(rd);
 errno=0;int s=openat(r,"ancestor",O_SEARCH|common);check(s>=0,"search-only ancestor opens");
 struct stat before={0},after={0},named={0};
 check(fstat(s,&before)==0&&S_ISDIR(before.st_mode)&&before.st_uid==getuid()&&(before.st_mode&0777)==0100,"fstat search descriptor preserves directory uid mode");
 check((fcntl(s,F_GETFD)&FD_CLOEXEC)!=0,"close-on-exec retained");
 check(fstatat(r,"ancestor",&named,AT_SYMLINK_NOFOLLOW)==0&&before.st_dev==named.st_dev&&before.st_ino==named.st_ino,"named nofollow identity matches search descriptor");
 errno=0;acl_t a=acl_get_fd_np(s,ACL_TYPE_EXTENDED);check(a!=NULL||errno==ENOENT,"ACL metadata available without directory read");if(a)acl_free(a);
 errno=0;int selected=openat(s,"selected",O_RDONLY|common);check(selected>=0,"selected directory retains ordinary read open");
 int input=openat(selected,"data",O_RDONLY|O_NOFOLLOW|O_CLOEXEC);char b[3]={0};check(input>=0&&read(input,b,2)==2&&!strcmp(b,"ok"),"actual selected file read");if(input>=0)close(input);
 errno=0;int bad=openat(s,"link",O_SEARCH|common);check(bad<0&&(errno==ELOOP||errno==ENOTDIR),"search descriptor rejects symlink");if(bad>=0)close(bad);
 int up=openat(s,"..",O_SEARCH|common);fstat(up,&after);fstat(r,&named);check(up>=0&&after.st_dev==named.st_dev&&after.st_ino==named.st_ino,"upward ancestry identity walk");if(up>=0)close(up);
 errno=0;int listing=dup(s);DIR* d=fdopendir(listing);struct dirent *entry=d?readdir(d):NULL;int e=errno;check(entry==NULL&&(e==EBADF||e==EACCES),"search descriptor cannot enumerate");if(d)closedir(d);else close(listing);
 errno=0;int syncResult=fsync(s);printf("OBSERVE fsync(search) result=%d errno=%d\n",syncResult,errno);
 errno=0;int event=openat(r,"ancestor",O_EVTONLY|common);printf("OBSERVE event-only descriptor result=%d errno=%d (not chosen for traversal)\n",event,errno);if(event>=0)close(event);
 fchmod(setup,0000);errno=0;int denied=openat(r,"ancestor",O_SEARCH|common);check(denied<0&&errno==EACCES,"search permission denial honored");if(denied>=0)close(denied);
 fchmod(setup,0700);if(selected>=0)close(selected);if(s>=0)close(s);
 unlinkat(sel,"data",0);close(sel);unlinkat(setup,"link",0);unlinkat(setup,"selected",AT_REMOVEDIR);close(setup);unlinkat(r,"ancestor",AT_REMOVEDIR);close(r);rmdir(root);
 printf("RESULT failures=%d\n",failures);return failures?1:0;
}
