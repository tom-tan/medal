/**
 * Authors: Tomoya Tanjo
 * Copyright: © 2020 Tomoya Tanjo
 * License: Apache-2.0
 */
module medal.transition.core;

import medal.config : Config;
import medal.logger : Logger, sharedLog;

import std.concurrency : Tid;

version(unittest)
shared static this()
{
    import medal.logger : LogLevel;
    sharedLog.logLevel = LogLevel.off;
}


///
@safe struct Place
{
    ///
    this(string n, string ns = "") inout @nogc nothrow pure
    {
        namespace = ns;
        name = n;
    }

    size_t toHash() const @nogc nothrow pure
    {
        return name.hashOf(namespace.hashOf);
    }

    bool opEquals(ref const Place other) const @nogc nothrow pure
    {
        return namespace == other.namespace && name == other.name;
    }

    ///
    string toString() const nothrow pure
    {
        import std.range : empty;
        return namespace.empty ? name : namespace~"::"~name;
    }

    string namespace;
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
}

///
struct CommandResult
{
    ///
    string stdout;
    ///
    string stderr;
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
            ptype = PatternType.Any;
        }
        else
        {
            ptype = PatternType.Constant;
        }
        pattern = pat;
    }

    ///
    const(Token) match(in Token token) const @nogc nothrow pure
    {
        final switch(ptype) with(PatternType)
        {
        case Any:
            return token;
        case Constant:
            return pattern == token.value ? token : null;
        case Stdout, Stderr, Return, Place:
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
        assert(ptype == PatternType.Any || ptype == PatternType.Constant);
    }

    string pattern;
    PatternType ptype;
}

///
@safe struct OutputPattern
{
    ///
    this(string pat) @nogc nothrow pure
    {
        import std.algorithm : startsWith;

        if (pat.startsWith("$"))
        {
            ptype = PatternType.Place;
            pattern = pat[1..$];
        }
        else if (pat == SpecialPattern.Stdout)
        {
            ptype = PatternType.Stdout;
            pattern = pat;
        }
        else if (pat == SpecialPattern.Stderr)
        {
            ptype = PatternType.Stderr;
            pattern = pat;
        }
        else if (pat == SpecialPattern.Return)
        {
            ptype = PatternType.Return;
            pattern = pat;
        }
        else
        {
            ptype = PatternType.Constant;
            pattern = pat;
        }
    }

    ///
    const(Token) match(in BindingElement be, in CommandResult result) const nothrow pure
    {
        import std.algorithm : find;
        import std.array : byPair;
        import std.conv : to;

        final switch(ptype) with(PatternType)
        {
        case Place:
            return be.tokenElements.byPair.find!(pt => pt[0].name == pattern).front.value;
        case Stdout:
            return new Token(result.stdout);
        case Stderr:
            return new Token(result.stderr);
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
        return ptype == PatternType.Place ? "$"~pattern : pattern;
    }

    invariant
    {
        assert(ptype != PatternType.Any);
    }

    string pattern;
    PatternType ptype;
}


///
alias ArcExpressionFunction = immutable OutputPattern[Place];

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
        return tuple(place, cast()pat.match(be, result));
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
@safe nothrow pure unittest
{
    immutable aef = [
        Place("foo"): OutputPattern("constant-value"),
    ];
    auto be = aef.apply(BindingElement.init, CommandResult.init);
    assert(be == [Place("foo"): new Token("constant-value")]);
}

///
@safe nothrow pure unittest
{
    immutable aef = [
        Place("foo"): OutputPattern(SpecialPattern.Stdout),
    ];
    CommandResult result = { stdout: "stdout.txt" };
    auto be = aef.apply(BindingElement.init, result);
    assert(be == [Place("foo"): new Token("stdout.txt")]);
}

///
@safe nothrow pure unittest
{
    immutable aef = [
        Place("foo"): OutputPattern(SpecialPattern.Return),
        Place("bar"): OutputPattern("other-constant-value"),
    ];
    CommandResult result = { stdout: "standard output", code: 0 };
    auto be = aef.apply(BindingElement.init, result);
    assert(be == [
        Place("foo"): new Token("0"),
        Place("bar"): new Token("other-constant-value"),
    ]);
}

///
@safe nothrow pure unittest
{
    immutable aef = [
        Place("buzz"): OutputPattern("$foo"),
    ];
    auto be = new BindingElement([Place("foo"): new Token("3")]);
    auto ret = aef.apply(be, CommandResult.init);
    assert(ret == [
        Place("buzz"): new Token("3"),
    ]);
}

///
alias Guard = immutable InputPattern[Place];

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
Tid spawnFire(in Transition tr, in BindingElement be, Tid tid, Config con = Config.init, Logger logger = sharedLog)
{
    import core.exception : AssertError;
    import std.concurrency : send, spawn;

    return spawn((in Transition tr, in BindingElement be, Tid tid, Config con, shared Logger logger) {
        try
        {
            tr.fire(be, tid, con, cast()logger);
        }
        catch(Exception e)
        {
            send(tid, cast(shared)e);
        }
        catch(AssertError e)
        {
            send(tid, cast(shared)e);
        }
    }, tr, be, tid, con, cast(shared)logger);
}
