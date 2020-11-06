/**
 * Authors: Tomoya Tanjo
 * Copyright: © 2020 Tomoya Tanjo
 * License: Apache-2.0
 */
module medal.loader;

import dyaml : Node;

import medal.transition.core;

///
Transition loadTransition(Node node)
{
    import std.exception : enforce;

    auto type = (*enforce("type" in node)).as!string;
    switch(type)
    {
    case "shell":
        return loadShellCommandTransition(node);
    case "network":
        return loadInvocationTransition(node);
    default:
        assert(false, "Unknown type: "~type);
    }
}

///
unittest
{
    import dyaml : Loader;
    import medal.message : TransitionSucceeded;
    import medal.transition.shell : ShellCommandTransition;
    import std.concurrency : receiveTimeout, thisTid;
    import std.datetime : seconds;
    import std.variant : Variant;

    enum inpStr = q"EOS
    name: echo
    type: shell
    out:
      - place: ret
        pattern: RETURN
    command: true
EOS";
    auto trRoot = Loader.fromString(inpStr).load;
    auto tr = loadTransition(trRoot);
    assert(cast(ShellCommandTransition)tr);
    spawnFire(tr, new BindingElement, thisTid);
    auto received = receiveTimeout(10.seconds,
        (TransitionSucceeded ts) {
            assert(ts.tokenElements == [Place("ret"): new Token("0")]);
        },
        (Variant _) { assert(false); },
    );
    assert(received);
}

///
Transition loadShellCommandTransition(Node node)
in("type" in node)
in(node["type"].as!string == "shell")
do
{
    import medal.transition.shell : ShellCommandTransition;
    import std.exception : enforce;
    import std.range :empty;

    auto name = "name" in node ? node["name"].get!string : "";
    auto command = (*enforce("command" in node)).as!string;
    enforce(!command.empty);
    auto g = "in" in node ? loadGuard(node["in"]) : Guard.init;

    auto aef = "out" in node ? loadArcExpressionFunction(node["out"])
                             : ArcExpressionFunction.init;
    return new ShellCommandTransition(name, command, g, aef);
}

///
Transition loadInvocationTransition(Node node)
in("type" in node)
in(node["type"].as!string == "network")
do
{
    import medal.transition.network : InvocationTransition;
    import std.algorithm : map;
    import std.array : array;
    import std.concurrency : Generator, yield;
    import std.exception : enforce;
    import std.range : empty;

    auto name = "name" in node ? node["name"].get!string : "";
    auto trNodes = (*enforce("transitions" in node)).sequence.array;
    auto trs = new Generator!Node({
        foreach(Node n; node["transitions"])
        {
            yield(n);
        }
    }).map!loadTransition.array;
    enforce(!trs.empty);

    auto g1 = "in" in node ? loadGuard(node["in"]) : Guard.init;

    auto g2 = "out" in node ? loadGuard(node["out"]) : Guard.init;
    return new InvocationTransition(name, g1, g2, trs);
}

///
Guard loadGuard(Node node)
{
    import std.array : assocArray;
    import std.concurrency : Generator, yield;
    import std.exception : assumeUnique, enforce;
    import std.typecons : tuple, Tuple;

    auto pats = new Generator!(Tuple!(Place, InputPattern))({
        foreach(Node n; node)
        {
            auto pl = (*enforce("place" in n)).as!string;
            auto pat = (*enforce("pattern" in n)).as!string;
            yield(tuple(Place(pl), InputPattern(pat)));
        }
    }).assocArray;
    return pats.assumeUnique;
}

///
unittest
{
    import dyaml : Loader;

    enum inpStr = q"EOS
    - place: pl
      pattern: constant-value
EOS";
    auto root = Loader.fromString(inpStr).load;
    auto g = loadGuard(root);
    assert(g == cast(immutable)[Place("pl"): InputPattern("constant-value")]);
}

///
ArcExpressionFunction loadArcExpressionFunction(Node node)
{
    import std.array : assocArray;
    import std.concurrency : Generator, yield;
    import std.exception : assumeUnique, enforce;
    import std.typecons : tuple, Tuple;

    auto pats = new Generator!(Tuple!(Place, OutputPattern))({
        foreach(Node n; node)
        {
            auto pl = (*enforce("place" in n)).as!string;
            auto pat = (*enforce("pattern" in n)).as!string;
            yield(tuple(Place(pl), OutputPattern(pat)));
        }
    }).assocArray;
    return pats.assumeUnique;
}

///
BindingElement loadBindingElement(Node node)
{
    import std.array : assocArray;
    import std.concurrency : Generator, yield;
    import std.exception : assumeUnique;
    import std.typecons : tuple, Tuple;

    auto tokenElems = new Generator!(Tuple!(Place, Token))({
        foreach(string pl, string tok; node)
        {
            yield(tuple(Place(pl), new Token(tok)));
        }
    }).assocArray;
    return new BindingElement(tokenElems.assumeUnique);
}
