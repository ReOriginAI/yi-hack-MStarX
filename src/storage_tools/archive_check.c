/* Strict USTAR validation before invoking BusyBox tar. No extension records,
 * links, paths, duplicates, missing payloads or concatenated archives. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>

static int octal(const unsigned char *p, size_t n, unsigned long *out)
{
    size_t i; unsigned long value=0; int ended=0;
    for (i=0; i<n; i++) {
        if (p[i]==' ' || p[i]==0) { if (value) ended=1; continue; }
        if (ended || p[i]<'0' || p[i]>'7' || value > (32UL<<20)) return 0;
        value=value*8+(p[i]-'0');
    }
    *out=value; return 1;
}

static int zero(const unsigned char *p, size_t n)
{
    size_t i; for (i=0; i<n; i++) if (p[i]) return 0; return 1;
}

static int allowed(const char *name, const char *prefix, int firmware)
{
    char path[512]; const char *p; struct stat st;
    if (firmware) return !strcmp(name,"sys_y23") || !strcmp(name,"home_y23");
    if (!strcmp(name,"TZ") || !strcmp(name,"hostname") || !strcmp(name,"passwd")) return 1;
    for (p=name; *p && *p!='.'; p++)
        if (!((*p>='a' && *p<='z') || (*p>='A' && *p<='Z') ||
              (*p>='0' && *p<='9') || *p=='_' || *p=='-')) return 0;
    if (p==name || strcmp(p,".conf")) return 0;
    if (snprintf(path,sizeof(path),"%s/etc/%s",prefix,name)>=(int)sizeof(path)) return 0;
    return lstat(path,&st)==0 && S_ISREG(st.st_mode);
}

int main(int argc, char **argv)
{
    FILE *f; struct stat st; unsigned char h[512]; char names[32][101];
    unsigned long size,sum,want,padded,total=0; unsigned i,count=0;
    int firmware,system=0,camera=0,sys=0,home=0;
    if (argc!=4 || (strcmp(argv[1],"config") && strcmp(argv[1],"firmware"))) return 2;
    firmware=!strcmp(argv[1],"firmware");
    f=fopen(argv[2],"rb"); if (!f) return 1;
    if (fstat(fileno(f),&st) || st.st_size<1024 || st.st_size%512 ||
        st.st_size > (firmware ? (20L<<20) : (1L<<20))) goto bad;
    while (fread(h,1,512,f)==512) {
        if (zero(h,512)) {
            /* Two EOF blocks required; any trailing bytes must be zero. */
            if (fread(h,1,512,f)!=512 || !zero(h,512)) goto bad;
            while ((i=fread(h,1,512,f))>0) if (!zero(h,i)) goto bad;
            if (ferror(f) || (firmware ? !(sys && home && count==2) : !(system && camera))) goto bad;
            fclose(f); return 0;
        }
        if (count>=32 || (h[156]!=0 && h[156]!='0') ||
            !memchr(h,0,100) || !zero(h+157,100) || !zero(h+345,155) ||
            memcmp(h+257,"ustar",5) || !octal(h+148,8,&want) || !octal(h+124,12,&size)) goto bad;
        sum=0; for (i=0; i<512; i++) sum+=(i>=148 && i<156) ? ' ' : h[i];
        if (sum!=want || !allowed((char*)h,argv[3],firmware) || (firmware && size==0) ||
            size>(firmware ? (16UL<<20) : (64UL<<10))) goto bad;
        for (i=0; i<count; i++) if (!strcmp(names[i],(char*)h)) goto bad;
        strcpy(names[count++],(char*)h);
        system |= !strcmp((char*)h,"system.conf"); camera |= !strcmp((char*)h,"camera.conf");
        sys |= !strcmp((char*)h,"sys_y23"); home |= !strcmp((char*)h,"home_y23");
        total+=size; if (total>(firmware ? (18UL<<20) : (256UL<<10))) goto bad;
        padded=(size+511)&~511UL;
        /* Seek only after proving the whole payload and padding exist. */
        if (ftell(f)+(long)padded+1024>st.st_size || fseek(f,padded,SEEK_CUR)) goto bad;
    }
bad:
    fprintf(stderr,"archive_check: invalid or unsupported archive\n"); fclose(f); return 1;
}
