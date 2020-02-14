module medal.engine;

import std.experimental.logger;
import std.concurrency: Tid;
import std.datetime: Duration, seconds;

import medal.flux;

///
auto run(Store s, EventRule[] rules, ReduceAction init, Duration timeout = -1.seconds)
{
    import std.concurrency: send, thisTid, receive, receiveTimeout;
    import std.variant: Variant;
    import core.atomic: atomicLoad, atomicStore;
    import medal.types: Int;

    shared running = true;
    shared code = 0;
    send(thisTid, init);
    while (atomicLoad(running)) {
        const recv = receiveTimeout(timeout,
            (Event e) {
                trace("Recv ", e);
                s = s.reduce(e);
                if (e.namespace == "medal")
                {
                    auto skip = handleMedalEvent(e, thisTid);
                    if (skip) return;
                }
                auto uas = rules.dispatch(e);
                foreach(ua; uas)
                {
                    import std.concurrency: spawn;
                    trace("create ", ua);
                    auto saga = s.saga(ua);
                    spawn((Tid tid, Task[] saga, UserAction ua) {
                        auto a = fork(saga, ua);
                        trace("Send ", a);
                        send(tid, a);
                    }, thisTid, saga, ua);
                }
            },
            (Int i) {
                tracef("Engine exited with %s", i.i);
                atomicStore(running, false);
                atomicStore(code, i.i);
            },
            (Variant v) {
                errorf("Unknown message: %s", v);
                atomicStore(running, false);
                atomicStore(code, 1);
            },
        );
        if (!recv)
        {
            errorf("Timeout recv");
            atomicStore(running, false);
            atomicStore(code, 1);
        }
    }
    return code;
}

///
auto dispatch(EventRule[] rules, Event e) @safe pure nothrow
{
    import std.algorithm: map, filter;
    return rules.map!(r => r.dispatch(e)).filter!(ua => !ua.isNull).map!"a.get";
}

/**
 * Returns: true if the rest of the messages should be skipped or false otherwise
 */
auto handleMedalEvent(Event e, Tid tid) @trusted
in(e.namespace == "medal")
{
    if (auto val = MedalExit in e.payload)
    {
        import std.concurrency: send, thisTid;
        import sumtype: tryMatch;
        import medal.types: Int;
        auto i = (*val).tryMatch!((Int i) => i);
        send(tid, i);
        return true;
    }
    return false;
}

unittest
{
    import dyaml: Loader;
    import medal.parser: parse;
    auto root = Loader.fromFile("examples/simple.yml").load;
    auto params = parse(root);
    const code = run(params.store, params.rules, params.initEvent, 5.seconds);
    assert(code == 0);
}
