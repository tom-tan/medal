module medal.engine;

import std.experimental.logger;
import std.datetime: Duration, seconds;

import medal.flux;

///
auto run(Store s, EventRule[] ers, ReduceAction init, Duration timeout = -1.seconds)
{
    import std.concurrency: send, thisTid, receiveTimeout;
    import std.variant: Variant;
    import core.atomic: atomicLoad, atomicStore;

    shared running = true;
    shared code = 0;
    send(thisTid, init);
    while (atomicLoad(running)) {
        const recv = receiveTimeout(timeout,
            (in Event ra) {
                import std.algorithm: map, filter;
                // TODO: apply は store 内でするべき？
                trace("Recv ", ra);
                synchronized(s) 
                {
                    s.reduce(ra);
                }
                if (ra.namespace == "medal") // TODO: should be handled by message
                {
                    if (auto val = MedalExit in ra.payload)
                    {
                        import sumtype: tryMatch;
                        import medal.types: Int;
                        atomicStore(running, false);
                        auto c = (*val).tryMatch!((Int i) => i.i);
                        errorf("Engine exited with %s", c);
                        atomicStore(code, c);
                        return;
                    }
                }
                auto uas = ers.map!(er => er.dispatch(ra)).filter!(ua => !ua.isNull).map!"a.get";
                foreach(ua; uas) // TODO: uas 全部の dispatch が終わらないと次の receive に入らない！
                {
                    trace("create ", ua);
                    auto a = s.dispatch(ua);
                    trace("Send ", a);
                    send(thisTid, a);
                }
            },
            (Variant v) {
                errorf("Unknown message: %s", v);
                atomicStore(running, false);
                atomicStore(code, 1);
            },
        );
        assert(recv);
    }
    return code;
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
