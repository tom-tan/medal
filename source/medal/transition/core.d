/**
 * Authors: Tomoya Tanjo
 * Copyright: © 2020 Tomoya Tanjo
 * License: Apache-2.0
 */
module medal.transition.core;

import medal.config : Config;
import medal.logger : Logger, LogType, NullLogger, nullLoggers, UserLogEntry;

import std.concurrency : Tid;
import std.json : JSONValue;

///
@safe struct Place
{
    ///
    this(string n) inout @nogc nothrow pure
    {
        name = n;
    }

    size_t toHash() const @nogc nothrow pure
    {
        return name.hashOf;
    }

    bool opEquals(ref const Place other) const @nogc nothrow pure
    {
        return name == other.name;
    }

    ///
    string toString() const @nogc nothrow pure
    {
        return name;
    }

    string name;
    // Type type
}

///
@safe struct Token
{
    ///
    this(string val) @nogc nothrow pure
    {
        value = val;
    }

    ///
    string toString() const @nogc nothrow pure
    {
        return value;
    }

    bool opCast(T: bool)() const @nogc nothrow pure
    {
        return value.length > 0;
    }

    // Type type
    string value;
}

// std.concurrency cannot send/receive immutable AA
// https://issues.dlang.org/show_bug.cgi?id=13930 (solved by Issue 21296)
//alias BindingElement = immutable Token[Place];
///
@safe immutable class BindingElement_
{
    ///
    this() @nogc nothrow pure
    {
        tokenElements = (Token[Place]).init;
    }

    ///
    this(immutable Token[Place] tokenElems) @nogc nothrow pure
    {
        tokenElements = tokenElems;
    }

    ///
    bool opEquals(in Token[Place] otherTokenElements) const @nogc nothrow pure
    {
        return cast(const(Token[Place]))tokenElements == otherTokenElements;
    }

    ///
    bool empty() const @nogc nothrow pure
    {
        import std.range : empty;
        return tokenElements.empty;
    }

    ///
    string toString() const pure
    {
        import std.conv : to;
        return tokenElements.to!string;
    }

    Token[Place] tokenElements;
}

/// ditto
alias BindingElement = immutable BindingElement_;

///
enum SpecialPattern: string
{
    Any = "_", ///
    Stdout = "~(tr.stdout)",
    Stderr = "~(tr.stderr)", ///
    Return = "~(tr.return)", ///
    File   = "~(newfile)", ///
}

///
enum PatternType
{
    Constant,
    Place,
    Any,
    Stdout,
    Stderr,
    File,
    Return,
}


///
@safe struct InputPattern
{
    ///
    this(string pat) @nogc nothrow pure
    {
        if (pat == SpecialPattern.Any)
        {
            type = PatternType.Any;
        }
        else
        {
            type = PatternType.Constant;
        }
        pattern = pat;
    }

    ///
    Token match(in Token token) const @nogc nothrow pure
    {
        final switch(type) with(PatternType)
        {
        case Any:
            return token;
        case Constant:
            return pattern == token.value ? token : Token.init;
        case Place, Stdout, Stderr, File, Return:
            assert(false);
        }
    }

    ///
    string toString() const @nogc nothrow pure
    {
        return pattern;
    }

    invariant
    {
        assert(type == PatternType.Any || type == PatternType.Constant);
    }

    string pattern;
    PatternType type;
}


alias OutputPattern = string;

///
alias ArcExpressionFunction_ = OutputPattern[Place];
/// ditto
alias ArcExpressionFunction = immutable ArcExpressionFunction_;

///
auto apply(ArcExpressionFunction aef, JSONValue be) @safe
{
    import std.algorithm : map;
    import std.array : assocArray, byPair;
    import std.exception : assumeUnique;

    auto tokenElems = aef.byPair.map!((kv) {
        import std.array : replace;
        import std.conv : asOriginalType;
        import std.format : format;
        import std.typecons : tuple;

        auto place = kv.key;
        auto pat = kv.value.replace(SpecialPattern.File.asOriginalType, format!"~(out.%s)"(place));
        return tuple(place, Token(pat.substitute(be)));
    }).assocArray;
    return new BindingElement(() @trusted { return tokenElems.assumeUnique; }() );
}

///
@safe unittest
{
    import std.array : empty;

    ArcExpressionFunction aef;
    auto be = aef.apply(JSONValue.init);
    assert(be.tokenElements.empty);
}

///
@safe unittest
{
    import std.conv : to;
    import std.exception : assertNotThrown;

    immutable aef = [
        "foo": "constant-value",
    ].to!ArcExpressionFunction_;

    auto be = aef.apply(JSONValue((string[string]).init));

    assert(be == [
        "foo": "constant-value"
    ].to!(Token[Place])
     .assertNotThrown);
}

///
@safe unittest
{
    import std.conv : asOriginalType, to;
    import std.exception : assertNotThrown;

    immutable aef = [
        "foo": SpecialPattern.Stdout.asOriginalType,
    ].to!ArcExpressionFunction_;

    JSONValue result;
    result["tr"] = JSONValue([
        "stdout": "stdout.txt",
    ]);

    auto be = aef.apply(result);

    assert(be == [
        "foo": "stdout.txt"
    ].to!(Token[Place])
     .assertNotThrown);
}

///
@safe unittest
{
    import std.conv : asOriginalType, to;
    import std.exception : assertNotThrown;

    immutable aef = [
        "foo": SpecialPattern.Return.asOriginalType,
        "bar": "other-constant-value",
    ].to!ArcExpressionFunction_;

    JSONValue result;
    result["tr"] = JSONValue([
        "stdout": JSONValue("stdout.txt"),
        "return": JSONValue(0),
    ]);

    auto be = aef.apply(result);

    assert(be == [
        "foo": "0",
        "bar": "other-constant-value",
    ].to!(Token[Place])
     .assertNotThrown);
}

///
@safe unittest
{
    import std.conv : to;
    import std.exception : assertNotThrown;

    immutable aef = [
        "buzz": "~(in.foo)",
    ].to!ArcExpressionFunction_;

    JSONValue result;
    result["in"] = JSONValue([
        "foo": 3,
    ]);

    auto ret = aef.apply(result);

    assert(ret == [
        "buzz": "3",
    ].to!(Token[Place])
     .assertNotThrown);
}

///
alias Guard_ = InputPattern[Place];
/// ditto
alias Guard = immutable Guard_;

///
immutable abstract class Transition_
{
    ///
    protected abstract void fire(in BindingElement be, Tid networkTid, Config con, Logger[LogType] loggers);

    ///
    BindingElement fireable(Store)(in Store s) nothrow pure @trusted
    {
        import std.algorithm : find;
        import std.array : byPair;
        import std.exception : assumeUnique;
        import std.range : empty, front;

        Token[Place] tokenElems;
        foreach(place, ipattern; guard.byPair)
        {
            if (auto tokens = place in s.state)
            {
                auto rng = (*tokens)[].find!(t => ipattern.match(t));
                if (!rng.empty)
                {
                    tokenElems[place] = rng.front;
                }
                else
                {
                    return null;
                }
            }
            else
            {
                return null;
            }
        }
        return new BindingElement(tokenElems.assumeUnique); // unsafe
    }

    final BindingElement fireable(in BindingElement be) @nogc nothrow pure @safe
    {
        import std.array : byPair;

        foreach(place, ipat; guard.byPair)
        {
            if (auto token = place in be.tokenElements)
            {
                if (!ipat.match(*token))
                {
                    return null;
                }
            }
            else
            {
                return null;
            }
        }
        return be;
    }

    ///
    this(in string n, in Guard g, in ArcExpressionFunction aef,
         UserLogEntry pre = UserLogEntry.init, UserLogEntry success = UserLogEntry.init, UserLogEntry failure = UserLogEntry.init) @nogc nothrow pure @safe
    {
        name = n;
        guard = g;
        arcExpFun = aef;
        preLogEntry = pre;
        successLogEntry = success;
        failureLogEntry = failure;
    }

    string name;
    Guard guard;
    ArcExpressionFunction arcExpFun;

    UserLogEntry preLogEntry;
    UserLogEntry successLogEntry;
    UserLogEntry failureLogEntry;
}

/// ditto
alias Transition = immutable Transition_;

///
Tid spawnFire(in Transition tr, in BindingElement be, Tid tid,
              Config con = Config.init,
              Logger[LogType] loggers = nullLoggers)
in(tr)
in(LogType.System in loggers)
in(LogType.App in loggers)
{
    import core.exception : AssertError;
    import std.concurrency : send, spawnLinked;
    import std.format : format;

    return spawnLinked((in Transition tr, in BindingElement be, Tid tid,
                        Config con, shared(Logger[LogType]) loggers) {
        try
        {
            tr.fire(be, tid, con, cast(Logger[LogType])loggers);
        }
        catch(Exception e)
        {
            (cast()loggers[LogType.System]).critical(criticalMsg(tr, be, con, format!"Unknown exception: %s"(e)));
            send(tid, cast(shared)e);
        }
        catch(AssertError e)
        {
            (cast()loggers[LogType.System]).critical(criticalMsg(tr, be, con, format!"Assersion failure: %s"(e)));
            send(tid, cast(shared)e);
        }
    }, tr, be, tid, con, cast(shared)loggers);
}

JSONValue criticalMsg(in Transition tr, in BindingElement be, in Config con, in string cause) pure @safe
{
    import std.conv : to;

    JSONValue ret;
    ret["event"] = "critical";
    ret["tag"] = con.tag;
    ret["name"] = tr.name;
    ret["in"] = be.tokenElements.to!(string[string]);
    ret["success"] = false;
    ret["cause"] = cause;
    return ret;
}

auto substitute(string str, JSONValue be) @safe
{
    enum escape = '~';

    auto aa = be.toAA;
    string current = str;
    string resulted;
    do
    {
        import std.algorithm : findSplitAfter;

        if (auto split = current.findSplitAfter([escape]))
        {
            import std.range : empty;

            resulted ~= split[0][0..$-1];
            auto rest = split[1];
            if (rest.empty)
            {
                assert(false, "Invalid escape at the end of string");
            }

            switch(rest[0])
            {
            case escape:
                resulted ~= escape;
                current = rest[1..$];
                break;
            case '(':
                if (auto sp = rest[1..$].findSplitAfter(")"))
                {
                    if (auto val = sp[0][0..$-1] in aa)
                    {
                        resulted ~= *val;
                        current = sp[1][0..$];
                    }
                    else
                    {
                        assert(false, "Invalid reference: "~sp[0][0..$-1]);
                    }
                }
                else
                {
                    assert(false, "No corresponding close paren");
                }
                break;
            default:
                import std.format : format;
                assert(false, format!"Invalid escape `%s%s`"(escape, rest[0]));
            }
        }
        else
        {
            resulted ~= current;
            break;
        }
    }
    while (true);
    return resulted;
}

@safe unittest
{
    JSONValue val = [
        "foo": "3",
    ];
    assert("echo ~(foo)".substitute(val) == "echo 3");
}

@safe unittest
{
    JSONValue val = [
        "foo": "3",
    ];
    assert("echo ~~(foo)".substitute(val) == "echo ~(foo)");
}

@safe unittest
{
    JSONValue val = [
        "foo": "3",
    ];
    assert("echo ~~~(foo)".substitute(val) == "echo ~3");
}

@safe unittest
{
    JSONValue val;
    val["foo"] = "3";
    val["out"] = [
        "bar": "output.txt",
    ];
    assert("echo ~(foo) > ~(out.bar)".substitute(val) == "echo 3 > output.txt");
}

string[string] toAA(JSONValue val, string prefix = "") @trusted // JSONValue.opApply
{
    typeof(return) ret;
    foreach(string k, JSONValue v; val)
    {
        import std.format : format;
        import std.json : JSONType;
        import std.range : empty;

        auto key = prefix.empty ? k : format!"%s.%s"(prefix, k);

        if (v.type == JSONType.object)
        {
            import std.algorithm : each;
            import std.array : byPair;

            auto subAA = v.toAA(key);
            subAA.byPair.each!(kv => ret[kv.key] = kv.value);
        }
        else if (v.type == JSONType.string)
        {
            ret[key] = v.get!string;
        }
        else
        {
            import std.conv : to;
            ret[key] = v.to!string;
        }
    }
    return ret;
}

@safe unittest
{
    JSONValue obj;
    obj["tmpdir"] = "/tmp";
    assert(obj.toAA == [
        "tmpdir": "/tmp",
    ]);
}

@safe unittest
{
    JSONValue obj;
    obj["in"] = [
        "foo": 1,
        "bar": 2,
    ];
    assert(obj.toAA == [
        "in.foo": "1",
        "in.bar": "2",
    ]);
}
