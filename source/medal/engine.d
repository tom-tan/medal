module medal.engine;

import std.experimental.logger;

import medal.flux;

/// 動作イメージ
auto run(Store s, EventRules er, ReduceAction init)
{
    import std.concurrency: send, thisTid, receiveTimeout;
    import std.variant: Variant;
    import core.atomic: atomicLoad, atomicStore;
    import std.datetime: seconds;

    shared running = true;
    shared code = 0;
    send(thisTid, cast(immutable)init);
    while (atomicLoad(running)) {
        const recv = receiveTimeout(10.seconds,
            (in Action ra) {
                // TODO: apply は store 内でするべき？
                trace("Recv ", ra);
                synchronized(s) 
                {
                    s = s.reduce(ra);
                }
                auto uas = er.dispatch(ra);
                foreach(ua; uas) // TODO: uas 全部の dispatch が終わらないと次の receive に入らない！
                {
                    auto a = s.dispatch(ua);
                    if (a.type == "exit")
                    {
                        trace("Send exit message");
                        atomicStore(running, false);
                        atomicStore(code, 0);
                        trace("Sent.");
                    }
                    else
                    {
                        trace("Send ", a);
                        send(thisTid, cast(immutable)a);
                        trace("Sent.");
                    }
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
    auto init = 
        new ReduceAction("", "mod", [Variable("", "a"): ValueType(Int(0))]);
    auto state = [
        Variable("", "a"): ValueType.init,
        Variable("", "b"): ValueType.init,
    ];

    auto rootSaga = [
        "ping": new Task([
            new CommandHolder("echo ping.", 
                new ReduceAction("", "mod", [Variable("", "b"): ValueType(Int(1))]))
        ]),
        "pong": new Task([
            new CommandHolder("echo pong.",
                new ReduceAction("", "mod", [Variable("", "a"): ValueType(Int(2))]))
        ]),
        "smash": new Task([
            new CommandHolder("echo 'smash!'", 
                new ReduceAction("", "mod", [Variable("", "exit"): ValueType(Int(0))]))
        ]),
    ];
    auto s = new Store(state, rootSaga);

    auto er = new EventRules;
    er.rules = [
        new RuleType("", "ping", [
            Variable("", "a"): ValueType(Int(0))
        ]),
        new RuleType("", "smash", [
            Variable("", "a"): ValueType(Int(2))
        ]),
        new RuleType("", "pong", [
            Variable("", "b"): ValueType(Int(1))
        ])
    ];
    const code = run(s, er, init);
    assert(code == 0);
}
