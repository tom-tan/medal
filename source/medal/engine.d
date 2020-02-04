module medal.engine;

import std.experimental.logger;

import medal.flux;

///
struct MedalExit
{
    ///
    int code;
}

/// 動作イメージ
auto run(Store s, EventRules er, ReduceAction init)
{
    import std.concurrency: receive, send, thisTid;
    import std.parallelism: parallel;
    import std.variant: Variant;

    auto running = true;
    auto code = 0;
    send(thisTid, cast(immutable)init);
    while (running) {
        receive(
            (in Action ra) {
                // TODO: apply は store 内でするべき？
                // reduce は shared でないといけない？
                synchronized(s) 
                {
                    s = s.reduce(ra);
                }
                auto uas = er.dispatch(ra);
                foreach(ua; uas.parallel) // TODO: uas 全部の dispatch が終わらないと次の receive に入らない！
                {
                    auto a = s.dispatch(ua);
                    if (a.type == "exit")
                    {
                        send(thisTid, immutable MedalExit(0));
                    }
                    else
                    {
                        send(thisTid, cast(immutable)a);
                    }
                }
            },
            (in MedalExit me) {
                running = false;
                code = me.code;
                send(thisTid, me);
            },
            (Variant v) {
                errorf("Unknown message: %s", v);
                running = false;
                code = 1;
            },
        );
    }
    return code;
}

unittest
{
    auto init = 
        new ReduceAction("", "mod", [Variable("", "a"): ValueType(Int(0))]);
    auto s = new Store;
    s.state = [
        Variable("", "a"): ValueType.init,
        Variable("", "b"): ValueType.init,
    ];

    s.rootSaga = [
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
