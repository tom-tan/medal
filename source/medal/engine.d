module medal.engine;
import medal.flux;

///
struct MedalExit
{
    ///
    int code;
}
import std.stdio;

/// 動作イメージ
auto run(Store s, EventRules er, ReduceAction init)
{
    import std.algorithm: each;
    import std.concurrency: receive, send, thisTid;
    import std.parallelism: parallel;
    import std.variant: Variant;

    auto running = true;
    auto code = 0;
    Variant v;
    writeln(init.sizeof);
    v = cast(shared)init;
    send(thisTid, (cast(immutable)init));
    writeln("yyy");
    while (running) {
        import std.algorithm: canFind;
        writeln("zzz");
        receive((immutable Action ra) {
            writeln("Receive ", ra);
            s = s.reduce(ra); // apply は store 内でするべき？
            writeln("start event dispatch");
            auto uas = er.dispatch(ra);
            writeln("end event dispatch");
            foreach(ua; uas.parallel)
            {
                writeln("start store dispatch");
                auto a = s.dispatch(ua);
                writeln("end store dispatch");
                if (a.type == "system")
                {
                    writeln("send quit message");
                    send(thisTid, shared MedalExit(0));
                }
                else
                {
                    writeln("send ", a);
                    writeln("Val: ", a.type, ", ", a.payload);
                    send(thisTid, cast(immutable)a);
                }
            }
        },
        (MedalExit me) {
            running = false;
            code = me.code;
            send(thisTid, me);
        },
        (Variant v) {
            writeln("Unknown message: ", v);
            running = false;
            code = 1;
        });
    }
    return code;
}

unittest
{
    auto init = 
        new ReduceAction("", "mod", [Assignment(Variable("", "a"), Int(0))]);
    auto s = new Store;
    s.state = [
        Variable("", "a"): ValueType.init,
        Variable("", "b"): ValueType.init,
    ];

    s.rootSaga = [
        "ping": new Task([
            new CommandHolder("echo ping.", 
            [new ReduceAction("", "mod", [Assignment(Variable("", "b"), Int(1))])])
        ]),
        "pong": new Task([
            new CommandHolder("echo pong.",
            [new ReduceAction("", "mod", [Assignment(Variable("", "a"), Int(2))])])
        ]),
        "smash": new Task([
            new CommandHolder("ehco 'smash!'", 
            [new ReduceAction("", "system", [])])
        ]),
    ];

    auto er = new EventRules;
    er.rules = [
        new RuleType("", "ping", [
            Assignment(Variable("", "a"), Int(0))
        ]),
        new RuleType("", "smash", [
            Assignment(Variable("", "a"), Int(2))
        ]),
        new RuleType("", "pong", [
            Assignment(Variable("", "b"), Int(1))
        ])
    ];
    writeln("aaa");
    const code = run(s, er, init);
    writeln("end run");
    assert(code == 0);
}
