module medal.flux;

import medal.types;

@safe:

///
enum MedalExit = Variable("medal", "exit");
///
enum ExitType = VariableType(MedalType!Int.init);

alias Type = string;

alias Variable = immutable Variable_;

///
immutable struct Variable_
{
    ///
    this(string ns, string n) immutable @nogc pure nothrow
    {
        namespace = ns;
        name = n;
    }

    ///
    size_t toHash() const @nogc pure nothrow
    {
        return name.hashOf(namespace.hashOf);
    }

    bool opEquals(ref const typeof(this) rhs) const @nogc pure nothrow
    {
        return namespace == rhs.namespace && name == rhs.name;
    }

    string toString() const
    {
        import std.format: format;
        return format!"`%s:%s`"(namespace, name);
    }

    ///
    string namespace;
    ///
    string name;
}

alias Payload = ValueType[Variable];

alias ReduceAction = immutable ReduceAction_;

///
immutable class ReduceAction_
{
    ///
    this(string ns, immutable Payload p) immutable @nogc pure nothrow
    {
        namespace = ns;
        payload = p;
    }

    ///
    string toString() const
    {
        import std.format: format;
        return format!"Event(%s, %s)"(namespace, payload);
    }

    ///
    string namespace;
    ///
    Payload payload;
}

///
alias UserAction = immutable UserAction_;

///
immutable class UserAction_
{
    ///
    this(string ns, ActionType t, immutable Payload p) immutable @nogc pure nothrow
    {
        type = t;
        namespace = ns;
        payload = p;
    }

    ///
    string toString() const
    {
        import std.format: format;
        return format!"Action(%s, %s, %s)"(namespace, type, payload);
    }

    ///
    ActionType type;
    ///
    string namespace;
    ///
    Payload payload;
}

alias EventRule = immutable EventRule_;

alias ActionType = string; // ActionType needs namespace

///
immutable struct EventRule_
{
    import std.typecons: Nullable, nullable;
    ///
    string namespace;
    ///
    ActionType type;
    ///
    Pattern[Variable] rule;

    /// TODO: should consider the whole current state
    Nullable!UserAction dispatch(in Event e) const pure nothrow
    {
        import std.array: byPair;
        import std.exception: assumeUnique;
        
        Payload p;
        foreach(kv; rule.byPair)
        {
            auto v = kv.key;
            if (auto val = v in e.payload)
            {
                import sumtype: match;
                auto pat = kv.value;
                auto m = pat.type.match!(_ => _.fromEventPattern(pat.pattern, *val));
                if (m.isNull) return typeof(return).init;
                p[v] = m.get;
            }
            else
            {
                return typeof(return).init;
            }
        }
        auto payload = () @trusted { return p.assumeUnique; }();
        return new UserAction(namespace, type, payload).nullable;
    }
}

alias Event = ReduceAction;

alias Task = immutable Task_;
///
immutable struct Task_
{
    ///
    this(string ns, string com, immutable Pattern[Variable] pat) immutable
    {
        namespace = ns;
        command_ = com;
        patterns = pat;
    }

    ///
    auto command(UserAction action) const
    {
        return command_;
    }

    ///
    auto command() const @nogc pure nothrow
    {
        return command_;
    }

    ///
    string toString() const
    {
        import std.format: format;
        return format!"Task(%s, %s, %s)"(namespace, command, patterns);
    }

    ///
    bool needs(SpecialPatterns pat) const @nogc pure nothrow
    {
        import std.algorithm: canFind;
        return patterns.byValue.canFind!(p => p.pattern == pat);
    }

    ///
    string namespace;
    ///
    string command_;
    ///
    Pattern[Variable] patterns;
}

///
class Store
{
    ///
    this(immutable VariableType[Variable] ts, immutable Task[][ActionType] saga) @nogc pure nothrow
    {
        types = ts;
        rootSaga = saga;
    }

    ///
    auto saga(UserAction a) const pure nothrow
    {
        return rootSaga[a.type];
    }

    ///
    auto reduce(ReduceAction a) pure nothrow
    {
        import std.array: byPair;
        import std.algorithm: each;
        a.payload.byPair.each!(kv =>
            state[kv.key] = kv.value
        );
        return this;
    }

private:
    ValueType[Variable] state;
    immutable VariableType[Variable] types;
    immutable Task[][ActionType] rootSaga;
}

struct Pattern
{
    string toString() const
    {
        import std.format: format;
        return format!"%s"(pattern);
    }

    VariableType type;
    string pattern;
}

auto fork(in Task[] tasks, UserAction action) @trusted
{
    import std.array: assocArray, join;
    import std.algorithm: map;
    import std.exception: assumeUnique;
    import std.experimental.logger: infof;

    immutable namespace = tasks[0].namespace; // assume all namespaces are the same
    infof("start tasks: %s, action: %s", tasks, action);
    scope(success) infof("end tasks");
    auto ras = tasks.map!(t => fork(t, action)).join.assocArray; // @suppress(dscanner.suspicious.unmodified)
    auto payload = ras.assumeUnique;
    return new ReduceAction(namespace, payload);
}

///
auto fork(in Task task, UserAction action) @trusted
{
    import std.algorithm: map;
    import std.array: array, byPair;
    import std.range: empty;

    CommandResult result;
    immutable needStdout = task.needs(SpecialPatterns.Stdout);
    immutable needStderr = task.needs(SpecialPatterns.Stderr);

    if (!task.command.empty)
    {
        import std.experimental.logger: infof;
        import std.process: spawnShell, wait;
        import std.stdio: File, stdin, stdout, stderr;
        auto sout = needStdout ? File("stdout", "w") : stdout; // TODO: should be random
        auto serr = needStderr ? File("stderr", "w") : stderr; // TODO: should be random

        infof("start command `%s`", task.command);
        scope(success) infof("end command `%s`", task.command(action));
        auto pid = spawnShell(task.command(action), stdin, sout, serr);
        result.code = wait(pid);
        if (needStdout)
        {
            result.stdout = sout.name;
        }
        if (needStderr)
        {
            result.stderr = serr.name;
        }
    }
    scope(exit)
    {
        import std.file: remove;
        if (needStdout)
        {
            result.stdout.get.remove;
        }
        if (needStderr)
        {
            result.stderr.get.remove;
        }
    }

    return task.patterns.byPair.map!((kv) {
        import std.exception: enforce;
        import std.typecons: tuple;
        import sumtype: match;

        auto var = kv.key;
        auto pat = kv.value;
        auto val = pat.type.match!(
            _ => _.fromOutputPattern(pat.pattern, result),
        );
        enforce(!val.isNull, "Invalid output value"); // TODO
        return tuple(var, val.get);
    }).array;
}
