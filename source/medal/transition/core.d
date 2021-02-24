/**
 * Authors: Tomoya Tanjo
 * Copyright: © 2020 Tomoya Tanjo
 * License: Apache-2.0
 */
module medal.transition.core;

import medal.config : Config;
import medal.logger : Logger, NullLogger;

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
@safe class Token
{
    ///
    this(string val) @nogc nothrow pure
    {
        value = val;
    }

    override bool opEquals(in Object other) const @nogc nothrow pure
    {
        if (auto t = cast(const Token)other)
        {
            return value == t.value;
        }
        else
        {
            return false;
        }
    }

    ///
    override string toString() const @nogc nothrow pure
    {
        return value;
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
    Stdout = "STDOUT", ///
    Stderr = "STDERR", ///
    Return = "RETURN", ///
    File   = "FILE", ///
}

///
struct CommandResult
{
    ///
    string stdout;
    ///
    string stderr;
    ///
    string[Place] files;
    ///
    int code;
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
    const(Token) match(in Token token) const @nogc nothrow pure
    {
        final switch(type) with(PatternType)
        {
        case Any:
            return token;
        case Constant:
            return pattern == token.value ? token : null;
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

///
@safe struct OutputPattern
{
    ///
    this(string pat) @nogc nothrow pure
    {
        import std.algorithm : endsWith, startsWith;

        if (pat.startsWith("~("))
        {
            assert(pat.endsWith(")"));
            type = PatternType.Place;
            pattern = pat[2..$-1];
        }
        else if (pat == SpecialPattern.Stdout)
        {
            type = PatternType.Stdout;
            pattern = pat;
        }
        else if (pat == SpecialPattern.Stderr)
        {
            type = PatternType.Stderr;
            pattern = pat;
        }
        else if (pat == SpecialPattern.File)
        {
            type = PatternType.File;
            pattern = pat;
        }
        else if (pat == SpecialPattern.Return)
        {
            type = PatternType.Return;
            pattern = pat;
        }
        else
        {
            type = PatternType.Constant;
            pattern = pat;
        }
    }

    ///
    const(Token) match(in Place place, in BindingElement be, in CommandResult result) const nothrow pure
    {
        import std.algorithm : find;
        import std.array : byPair;
        import std.conv : to;
        import std.range : empty;

        final switch(type) with(PatternType)
        {
        case Place:
            return be.tokenElements.byPair.find!(pt => pt[0].name == pattern).front.value;
        case Stdout:
            return new Token(result.stdout);
        case Stderr:
            return new Token(result.stderr);
        case File:
            auto file = place in result.files;
            assert(file);
            assert(!file.empty);
            return new Token(*file);
        case Return:
            return new Token(result.code.to!string);
        case Constant:
            return new Token(pattern);
        case Any:
            assert(false);
        }
    }

    ///
    string toString() const nothrow pure
    {
        return type == PatternType.Place ? "~("~pattern~")" : pattern;
    }

    invariant
    {
        assert(type != PatternType.Any);
    }

    string pattern;
    PatternType type;
}


///
alias ArcExpressionFunction_ = OutputPattern[Place];
/// ditto
alias ArcExpressionFunction = immutable ArcExpressionFunction_;

///
BindingElement apply(ArcExpressionFunction aef, in BindingElement be, CommandResult result) nothrow pure @trusted
{
    import std.algorithm : map;
    import std.array : assocArray, byPair;
    import std.exception : assumeUnique;
    import std.typecons : tuple;

    auto tokenElems = aef.byPair.map!((kv) {
        auto place = kv.key;
        auto pat = kv.value;
        return tuple(place, cast()pat.match(place, be, result));
    }).assocArray; // unsafe: assocArray
    return new BindingElement(tokenElems.assumeUnique); // unsafe: assumeUnique
}

///
@safe nothrow pure unittest
{
    import std.array : empty;

    ArcExpressionFunction aef;
    auto be = aef.apply(BindingElement.init, CommandResult.init);
    assert(be.tokenElements.empty);
}

///
@safe /*nothrow*/ pure unittest // due to to!AEF_
{
    import std.conv : to;
    import std.exception : assertNotThrown;

    immutable aef = [
        "foo": "constant-value",
    ].to!ArcExpressionFunction_;

    auto be = aef.apply(BindingElement.init, CommandResult.init);

    assert(be == [
        "foo": "constant-value"
    ].to!(Token[Place])
     .assertNotThrown);
}

///
@safe /*nothrow*/ pure unittest
{
    import std.conv : to;
    import std.exception : assertNotThrown;

    immutable aef = [
        "foo": SpecialPattern.Stdout,
    ].to!ArcExpressionFunction_;

    CommandResult result = { stdout: "stdout.txt" };

    auto be = aef.apply(BindingElement.init, result);

    assert(be == [
        "foo": "stdout.txt"
    ].to!(Token[Place])
     .assertNotThrown);
}

///
@safe /*nothrow*/ pure unittest
{
    import std.conv : to;
    import std.exception : assertNotThrown;

    immutable aef = [
        "foo": SpecialPattern.Return,
        "bar": "other-constant-value",
    ].to!ArcExpressionFunction_;

    CommandResult result = { stdout: "stdout.txt", code: 0 };

    auto be = aef.apply(BindingElement.init, result);

    assert(be == [
        "foo": "0",
        "bar": "other-constant-value",
    ].to!(Token[Place])
     .assertNotThrown);
}

///
@safe /*nothrow*/ pure unittest
{
    import std.conv : to;
    import std.exception : assertNotThrown;

    immutable aef = [
        "buzz": "~(foo)",
    ].to!ArcExpressionFunction_;

    immutable be_ = [
        "foo": "3"
    ].to!(Token[Place]);

    auto ret = aef.apply(new BindingElement(be_), CommandResult.init);

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
    protected abstract void fire(in BindingElement be, Tid networkTid, Config con, Logger logger);

    ///
    BindingElement fireable(Store)(in Store s) nothrow pure
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
                    tokenElems[place] = cast()rng.front; // unsafe
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
                if (ipat.match(*token) is null)
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
    this(in string n, in Guard g, in ArcExpressionFunction aef) @nogc nothrow pure @safe
    {
        name = n;
        guard = g;
        arcExpFun = aef;
    }

    string name;
    Guard guard;
    ArcExpressionFunction arcExpFun;
}

/// ditto
alias Transition = immutable Transition_;

///
Tid spawnFire(in Transition tr, in BindingElement be, Tid tid, Config con = Config.init, Logger logger = new NullLogger)
{
    import core.exception : AssertError;
    import std.concurrency : send, spawnLinked;
    import std.format : format;

    return spawnLinked((in Transition tr, in BindingElement be, Tid tid, Config con, shared Logger logger) {
        try
        {
            tr.fire(be, tid, con, cast()logger);
        }
        catch(Exception e)
        {
            (cast()logger).critical(criticalMsg(tr, be, con, format!"Unknown exception: %s"(e)));
            send(tid, cast(shared)e);
        }
        catch(AssertError e)
        {
            (cast()logger).critical(criticalMsg(tr, be, con, format!"Assersion failure: %s"(e)));
            send(tid, cast(shared)e);
        }
    }, tr, be, tid, con, cast(shared)logger);
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
