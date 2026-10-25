#pragma once
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <mutex>

// Opt-in, streaming Chrome trace events. JSONL survives interrupted captures;
// the analysis tool also exports a standard Perfetto/Chrome trace JSON file.
namespace gfx::capture {
using Clock=std::chrono::steady_clock;
struct State { FILE *file=nullptr;std::mutex mutex;std::atomic<unsigned> nextThread{1};unsigned rows=0; };
inline void Flush();
inline State &Get(){
    static State *state=[] {
        auto *s=new State;
        if(const char *path=std::getenv("DC_WORLD_PROFILE"))s->file=std::fopen(path,"wb");
        if(s->file)std::atexit(Flush);
        return s;
    }();
    return *state;
}
inline bool Enabled(){return Get().file!=nullptr;}
inline double Now(){return std::chrono::duration<double,std::micro>(Clock::now().time_since_epoch()).count();}
inline unsigned Thread(){static thread_local unsigned id=Get().nextThread.fetch_add(1);return id;}
struct Tile {int64_t x=0,z=0;int level=-1;};
inline thread_local Tile tile;
struct TileScope {Tile previous;TileScope(int64_t x,int64_t z,int level):previous(tile){tile={x,z,level};}~TileScope(){tile=previous;}};
inline void Flush(){auto &s=Get();if(!s.file)return;std::lock_guard lock(s.mutex);std::fflush(s.file);}
inline void Span(const char *name,double start,double duration,const char *category="cpu"){
    auto &s=Get();if(!s.file)return;
    const auto tid=Thread();std::lock_guard lock(s.mutex);
    std::fprintf(s.file,"{\"name\":\"%s\",\"cat\":\"%s\",\"ph\":\"X\",\"pid\":1,\"tid\":%u,\"ts\":%.3f,\"dur\":%.3f,\"args\":{\"lod\":%d,\"x\":%lld,\"z\":%lld}}\n",
        name,category,tid,start,duration,tile.level,(long long)tile.x,(long long)tile.z);
    if(++s.rows%4096==0)std::fflush(s.file);
}
inline void Counter(const char *name,double value){
    auto &s=Get();if(!s.file)return;
    const auto tid=Thread();double now=Now();std::lock_guard lock(s.mutex);
    std::fprintf(s.file,"{\"name\":\"%s\",\"cat\":\"counter\",\"ph\":\"C\",\"pid\":1,\"tid\":%u,\"ts\":%.3f,\"args\":{\"value\":%.6f}}\n",name,tid,now,value);
    if(++s.rows%4096==0)std::fflush(s.file);
}
struct Scope {
    const char *name;double start=0;
    explicit Scope(const char *n):name(n){if(Enabled())start=Now();}
    void End(){if(start){Span(name,start,Now()-start);start=0;}}
    ~Scope(){End();}
};
}
