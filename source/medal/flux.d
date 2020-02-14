module medal.flux;

import medal.types;
import sumtype;

@safe:

///
enum MedalExit = Variable("medal", "exit");
///
enum ExitType = VariableType(MedalType!Int.init);

alias Type = string;

alias Variable = immutable Variable_;

///
struct Variable_
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

    ///
    Nullable!UserAction dispatch(in Event e)
    {
        import std.array: byPair;
        import std.exception: assumeUnique;
        
        Payload p;
        foreach(kv; rule.byPair)
        {
            auto v = kv.key;
            if (auto val = v in e.payload)
            {
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
    string toString() const
    {
        import std.format: format;
        return format!"Task(%s, %s, %s)"(namespace, command, patterns);
    }

    ///
    string namespace;
    ///
    string command;
    ///
    Pattern[Variable] patterns;
}

///
class Store
{
    ///
    this(immutable VariableType[Variable] ts, immutable Task[][ActionType] saga)
    {
        types = ts;
        rootSaga = saga;
    }

    ///
    auto dispatch(UserAction a)
    {
        auto c = rootSaga[a.type];
        return fork(c, a);
    }

    ///
    auto reduce(ReduceAction a)
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
    import std.exception: assumeUnique;
    import std.process: spawnShell, wait;
    import std.array: array, byPair, assocArray, join;
    import std.typecons: tuple;

    import std.algorithm: map;
    import std.experimental.logger: infof;
    immutable namespace = tasks[0].namespace; // assume all namespaces are the same
    infof("start tasks: %s, action: %s", tasks, action);
    scope(success) infof("end tasks");
    auto ras = tasks.map!((t) { // @suppress(dscanner.suspicious.unmodified)
        import std.exception: enforce;
        import std.stdio: stdout, stderr;
        import std.range: empty;
        CommandResult result;
        if (!t.command.empty)
        {
            infof("start command `%s`", t.command);
            scope(success) infof("end command `%s`", t.command);
            auto pid = spawnShell(t.command);
            result.code = wait(pid);
            result.stdout = stdout;
            result.stderr = stderr;
        }
        return t.patterns.byPair.map!((kv) {
            auto var = kv.key;
            auto pat = kv.value;
            auto val = pat.type.match!(
                _ => _.fromOutputPattern(pat.pattern, result),
            );
            enforce(!val.isNull, "Invalid output value"); // TODO
            return tuple(var, val.get);
        });
    }).join.assocArray;
    auto payload = ras.assumeUnique;
    return new ReduceAction(namespace, payload);
}
