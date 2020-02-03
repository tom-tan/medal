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
    send(thisTid, (cast(immutable)init));
    while (running) {
        import std.algorithm: canFind;
        receive((in Action ra) {
            s = s.reduce(ra); // apply は store 内でするべき？
            auto uas = er.dispatch(ra);
            foreach(ua; uas.parallel)
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
                new ReduceAction("", "mod", [Assignment(Variable("", "b"), Int(1))]))
        ]),
        "pong": new Task([
            new CommandHolder("echo pong.",
                new ReduceAction("", "mod", [Assignment(Variable("", "a"), Int(2))]))
        ]),
        "smash": new Task([
            new CommandHolder("echo 'smash!'", 
                new ReduceAction("", "mod", [Assignment(Variable("", "exit"), Int(0))]))
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
    const code = run(s, er, init);
    assert(code == 0);
}
